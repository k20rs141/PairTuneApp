import Foundation
import MusicKit
import Supabase

// M4: Solo モード(ローカル再生 + my_room_play_history 記録)を追加。
// M5: Shared モード を両者対等ホスト(last-write-wins)に昇格。
//     init(sharedRoomV4:pairId:) を新設。enterRoom で両者が broadcast + listen。
//     30 秒で shared_room_play_history を記録。
// 仕様: docs/PairTune_Specification_v0.4.md §5.1 / §7
// 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §7 / §8

// MARK: - RoomMode

enum RoomMode { case solo, shared }

enum RoomAlert: String, Identifiable {
    case appleMusicNotSubscribed
    case songNotInCatalog
    case songLoadTimeout
    case reconnectFailed
    case hostOffline
    case playbackFailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMusicNotSubscribed: return "Apple Music の契約が必要です"
        case .songNotInCatalog:        return "この曲は再生できません"
        case .songLoadTimeout:         return "読み込みに失敗しました"
        case .reconnectFailed:         return "接続できません"
        case .hostOffline:             return "相手がオフラインです"
        case .playbackFailed:          return "再生に失敗しました"
        }
    }

    var message: String {
        switch self {
        case .appleMusicNotSubscribed: return "設定アプリから Apple Music をご契約ください。"
        case .songNotInCatalog:        return "地域カタログにない曲の可能性があります。別の曲を選んでください。"
        case .songLoadTimeout:         return "ネットワーク状況をご確認ください。"
        case .reconnectFailed:         return "通信状況をご確認のうえリトライしてください。"
        case .hostOffline:             return "相手が離席中です。接続を待っています。"
        case .playbackFailed:          return "もう一度お試しください。"
        }
    }

    /// 設定アプリへ誘導するか
    var opensSettings: Bool { self == .appleMusicNotSubscribed }
}

@Observable
@MainActor
final class RoomViewModel {
    // MARK: - Room info

    let currentRoom: Room
    let isHost: Bool
    let mode: RoomMode

    // MARK: - Display state (RoomView が読む)

    var syncState: SyncState = .idle
    var currentTrack: Track?
    var isPaused: Bool = false
    var progress: Int { Int(musicService.currentPlaybackTime) }

    // MARK: - Alert state (RoomView が .alert(item:) で読む)
    var roomAlert: RoomAlert?

    // MARK: - 接続状態
    private var connectionObserverTask: Task<Void, Never>?

    // MARK: - Presence

    let channelManager = RealtimeChannelManager()
    var onlineParticipants: [PresenceUser] { channelManager.onlineUsers }

    // MARK: - Services

    let musicService = MusicPlayerService()
    private let roomService = RoomService()
    private let historyService = HistoryService()

    // MARK: - Internal

    private(set) var activeSongId: String = ""
    private var hostBroadcastTask: Task<Void, Never>?
    private var stateListenerTask: Task<Void, Never>?
    private var eventListenerTask: Task<Void, Never>?

    // 両モード共通: 自分の userId。enterRoom 時に設定する。
    private var myUserId: String = ""

    // Shared モード用
    private var sharedPairId: String = ""
    /// last-write-wins: 自分が最後に操作した日時。
    /// 受信 PlayState の hostTimestampMs よりも新しければ、相手の state を無視する。
    private var lastLocalActionAt: Date? = nil

    // Solo / Shared 共通: 30秒履歴タイマー
    private var historyTimerTask: Task<Void, Never>?

    // デバッグ用
    var debugLastDriftMs: Double = 0
    var debugLastSeq: Int = 0

    // MARK: - Init (Solo モード — M4)

    /// マイルーム(RoomV4)から Solo モードの RoomViewModel を作る。
    /// RoomView は `currentRoom.code` を参照するため、pairingCode を code として使う adapter を作る。
    init(myRoom: RoomV4) {
        let adapterRoom = Room(
            id: myRoom.id,
            code: myRoom.pairingCode ?? String(myRoom.id.prefix(6)).uppercased(),
            hostId: "",
            isActive: true,
            currentSongId: myRoom.currentSongId,
            createdAt: myRoom.createdAt
        )
        self.currentRoom = adapterRoom
        self.isHost = true
        self.mode = .solo
    }

    // MARK: - Init (Shared モード — M5)

    /// shared_room(RoomV4)から Shared モードの RoomViewModel を作る。
    /// v0.4 仕様: 両者対等ホスト。isHost = true で両者ともホストコントロールを持つ。
    /// pairId は shared_room_play_history 記録に使う。
    init(sharedRoomV4: RoomV4, pairId: String) {
        // shared_room の UUID をチャネルキー兼 code として使う。
        // 両者が同じ sharedRoomId で connect → 同じ Realtime チャネルに接続される。
        let adapterRoom = Room(
            id: sharedRoomV4.id,
            code: sharedRoomV4.id,
            hostId: "",
            isActive: true,
            currentSongId: sharedRoomV4.currentSongId,
            createdAt: sharedRoomV4.createdAt
        )
        self.currentRoom = adapterRoom
        self.isHost = true   // M5: 両者ホスト
        self.mode = .shared
        self.sharedPairId = pairId
    }

    // MARK: - Init (旧 Shared モード — v0.2 互換、M5 以降は上の init を使う)

    init(room: Room, isHost: Bool) {
        self.currentRoom = room
        self.isHost = isHost
        self.mode = .shared
    }

    // MARK: - Lifecycle

    func enterRoom(userId: String, displayName: String?) async {
        _ = await musicService.requestAuthorization()

        // Solo モード: Realtime 接続は不要、userId だけ保持して終わり
        if mode == .solo {
            myUserId = userId
            return
        }

        // Shared モード (M5): 両者とも broadcast + listen
        myUserId = userId
        startConnectionObserver()

        await channelManager.connect(
            roomCode: currentRoom.code,
            userId: userId,
            isHost: true,   // M5: 両者対等ホスト
            displayName: displayName
        )

        startHostBroadcast()   // 自分の状態を 2 秒間隔で送信
        startGuestListeners()  // 相手からの状態・イベントを受信
        // 遅延参加: DB に曲が保存されていれば先読みしておく
        await syncToCurrentRoomState()
    }

    func reconnect(userId: String, displayName: String?) async {
        // Solo モード: 再接続は不要
        if mode == .solo { return }

        await channelManager.reconnect(
            roomCode: currentRoom.code,
            userId: userId,
            isHost: true,  // M5: 両者対等
            displayName: displayName
        )
        startHostBroadcast()
        startGuestListeners()
    }

    func leaveRoom() async {
        historyTimerTask?.cancel()
        musicService.stop()

        // Solo モード: Realtime/DB 操作は不要
        if mode == .solo { return }

        hostBroadcastTask?.cancel()
        stateListenerTask?.cancel()
        eventListenerTask?.cancel()
        connectionObserverTask?.cancel()
        await channelManager.disconnect()
        // M5: 両者 isHost = true のため RoomService.leaveRoom は実質 no-op(M8 で再設計)
        try? await roomService.leaveRoom(roomId: currentRoom.id, isHost: isHost)
    }

    /// 接続失敗アラートのリトライボタンから呼ぶ。
    func retryConnection() async {
        // Solo モード: Realtime は使わないためリトライ不要
        if mode == .solo { return }

        await channelManager.retryFromFailure()
        guard case .connected = channelManager.connectionState else { return }
        startHostBroadcast()
        startGuestListeners()
    }

    // MARK: - Host actions

    /// SearchSheet から曲が選ばれた時に呼ばれる(Solo / Shared 共通)
    func playAsHost(_ track: Track) async {
        // Apple Music 契約確認(未契約ならアラートで設定誘導)
        if let sub = try? await MusicSubscription.current, !sub.canPlayCatalogContent {
            roomAlert = .appleMusicNotSubscribed
            syncState = .idle
            return
        }

        syncState = .loading
        currentTrack = track
        isPaused = false

        do {
            let songId = track.id
            activeSongId = songId
            try await musicService.load(songId: songId, at: 0)

            // MusicKit Song で Track を上書き(duration を実データに更新)
            if let song = musicService.currentSong {
                currentTrack = song.toTrack()
            }

            syncState = .playing

            if mode == .solo {
                // Solo: Realtime なし。30秒タイマーをリスタートして履歴記録を予約。
                startHistoryTimer(for: currentTrack ?? track)
            } else {
                // Shared: last-write-wins タイムスタンプを更新 → DB 保存 → PlayEvent 2 連投
                lastLocalActionAt = Date()
                try? await roomService.updateCurrentSong(roomId: currentRoom.id, songId: songId)
                let event = PlayEvent(type: .play, songId: songId, playbackTime: musicService.currentTime())
                await channelManager.broadcast(event: "play_event", message: event)
                await channelManager.broadcast(event: "play_event", message: event)
                // 30秒後に履歴記録
                startHistoryTimer(for: currentTrack ?? track)
            }

        } catch {
            print("[RoomViewModel] playAsHost error:", error)
            roomAlert = (error as? MusicLoadError) == .timeout ? .songLoadTimeout : .playbackFailed
            syncState = .idle
        }
    }

    func togglePlayback() async {
        guard syncState != .idle, syncState != .loading else { return }

        if musicService.isPlaying {
            musicService.pause()
            isPaused = true
            syncState = .paused
            if mode == .shared {
                lastLocalActionAt = Date()
                let event = PlayEvent(type: .pause, songId: activeSongId, playbackTime: musicService.currentTime())
                await channelManager.broadcast(event: "play_event", message: event)
                await channelManager.broadcast(event: "play_event", message: event)
            }
        } else {
            do {
                try await musicService.play()
            } catch {
                print("[RoomViewModel] togglePlayback play error:", error)
                roomAlert = .playbackFailed
                return
            }
            isPaused = false
            syncState = .playing
            if mode == .shared {
                lastLocalActionAt = Date()
                let event = PlayEvent(type: .play, songId: activeSongId, playbackTime: musicService.currentTime())
                await channelManager.broadcast(event: "play_event", message: event)
                await channelManager.broadcast(event: "play_event", message: event)
            }
        }
    }

    // MARK: - 履歴タイマー(Solo / Shared 統合)

    /// 曲が変わるたびにリスタート。30秒経過したらモードに応じて履歴を記録する。
    private func startHistoryTimer(for track: Track) {
        historyTimerTask?.cancel()
        historyTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            switch self.mode {
            case .solo:
                await self.historyService.recordSoloPlay(track, userId: self.myUserId, duration: 30)
            case .shared:
                await self.historyService.recordSharedPlay(
                    track,
                    duration: 30,
                    pairId: self.sharedPairId,
                    sharedRoomId: self.currentRoom.id
                )
            }
        }
    }

    // MARK: - Host broadcast loop

    private func startHostBroadcast() {
        hostBroadcastTask?.cancel()
        hostBroadcastTask = Task { [weak self] in
            var seq = 0
            while !Task.isCancelled {
                guard let self else { return }
                if !self.activeSongId.isEmpty {
                    let state = PlayState(
                        songId: self.activeSongId,
                        playbackTime: self.musicService.currentTime(),
                        isPlaying: self.musicService.isPlaying,
                        hostTimestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                        actorUserId: self.myUserId,
                        seq: seq
                    )
                    await self.channelManager.broadcast(event: "play_state", message: state)
                }
                seq += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Listener setup (Shared モード)

    private func startGuestListeners() {
        stateListenerTask?.cancel()
        eventListenerTask?.cancel()

        guard let psStream = channelManager.playStateStream,
              let peStream = channelManager.playEventStream else { return }

        stateListenerTask = Task { [weak self] in
            for await json in psStream {
                guard let self else { return }
                guard let payload = json["payload"] else { continue }
                if let state = try? payload.decode(as: PlayState.self) {
                    await self.applyPlayState(state)
                }
            }
        }

        eventListenerTask = Task { [weak self] in
            for await json in peStream {
                guard let self else { return }
                guard let payload = json["payload"] else { continue }
                if let event = try? payload.decode(as: PlayEvent.self) {
                    await self.applyPlayEvent(event)
                }
            }
        }
    }

    /// 遅延参加: DB の current_song_id があればロードだけ行い、再生は PlayState/PlayEvent を待つ。
    private func syncToCurrentRoomState() async {
        guard let songId = currentRoom.currentSongId, !songId.isEmpty else { return }
        guard activeSongId != songId else { return }

        activeSongId = songId
        syncState = .loading
        do {
            try await musicService.load(songId: songId, at: 0)
            // 即時 pause: 相手の PlayState (isPlaying=true) で再開される。
            musicService.pause()
            if let song = musicService.currentSong {
                currentTrack = song.toTrack()
            }
            syncState = .paused
            isPaused = true
        } catch {
            print("[RoomViewModel] syncToCurrentRoomState error:", error)
            roomAlert = (error as? MusicLoadError) == .timeout ? .songLoadTimeout : .songNotInCatalog
            syncState = .idle
        }
    }

    // MARK: - PlayState correction (Shared)

    private func applyPlayState(_ state: PlayState) async {
        debugLastSeq = state.seq

        // ── last-write-wins ──
        // 自分が直近 1 秒以内に操作していて、かつ自分の操作の方が新しければ相手の state を無視する。
        if let mine = lastLocalActionAt,
           Date().timeIntervalSince(mine) < 1.0,
           state.hostTimestampMs < Int64(mine.timeIntervalSince1970 * 1000) {
            return
        }

        // 曲が変わった場合はロード
        if state.songId != activeSongId, !state.songId.isEmpty {
            activeSongId = state.songId
            syncState = .loading
            do {
                let estimatedPos = estimatedHostTime(state)
                try await musicService.load(songId: state.songId, at: max(0, estimatedPos))
                if let song = musicService.currentSong {
                    currentTrack = song.toTrack()
                }
                syncState = state.isPlaying ? .playing : .paused
                isPaused = !state.isPlaying
                // 受信側: 新しい曲を受け取ったので履歴タイマーを開始
                if let track = currentTrack {
                    startHistoryTimer(for: track)
                }
            } catch {
                print("[RoomViewModel] applyPlayState load error:", error)
                roomAlert = (error as? MusicLoadError) == .timeout ? .songLoadTimeout : .songNotInCatalog
                syncState = .idle
            }
            return
        }

        guard !activeSongId.isEmpty else { return }

        // 再生状態の同期
        if state.isPlaying && !musicService.isPlaying {
            try? await musicService.play()
            syncState = .playing
            isPaused = false
        } else if !state.isPlaying && musicService.isPlaying {
            musicService.pause()
            syncState = .paused
            isPaused = true
        }

        // ドリフト補正
        if state.isPlaying {
            let hostPos = estimatedHostTime(state)
            let localPos = musicService.currentTime()
            let drift = hostPos - localPos
            debugLastDriftMs = drift * 1000

            if abs(drift) > 2.0 {
                // 強制 seek
                musicService.seek(to: max(0, hostPos))
                syncState = .outOfSync
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    if self?.syncState == .outOfSync { self?.syncState = .playing }
                }
            } else if abs(drift) > 0.2 {
                // 静かに補正 (100ms バッファ)
                musicService.seek(to: max(0, hostPos + 0.1))
            }
        }
    }

    // MARK: - PlayEvent handler (Shared)

    private func applyPlayEvent(_ event: PlayEvent) async {
        switch event.type {
        case .play:
            let sid = event.songId ?? activeSongId
            if !sid.isEmpty && sid != activeSongId {
                activeSongId = sid
                syncState = .loading
                do {
                    try await musicService.load(songId: sid, at: max(0, event.playbackTime))
                    if let song = musicService.currentSong {
                        currentTrack = song.toTrack()
                    }
                    syncState = .playing
                    isPaused = false
                    // 受信側: 履歴タイマー開始
                    if let track = currentTrack {
                        startHistoryTimer(for: track)
                    }
                } catch {
                    print("[RoomViewModel] applyPlayEvent load error:", error)
                    roomAlert = (error as? MusicLoadError) == .timeout ? .songLoadTimeout : .songNotInCatalog
                }
            } else if !activeSongId.isEmpty {
                musicService.seek(to: max(0, event.playbackTime))
                try? await musicService.play()
                syncState = .playing
                isPaused = false
            }

        case .pause:
            musicService.pause()
            musicService.seek(to: max(0, event.playbackTime))
            syncState = .paused
            isPaused = true

        case .skip:
            if let sid = event.songId, !sid.isEmpty {
                activeSongId = sid
                syncState = .loading
                do {
                    try await musicService.load(songId: sid, at: max(0, event.playbackTime))
                    if let song = musicService.currentSong {
                        currentTrack = song.toTrack()
                    }
                    syncState = .playing
                    isPaused = false
                    if let track = currentTrack {
                        startHistoryTimer(for: track)
                    }
                } catch {
                    print("[RoomViewModel] applyPlayEvent skip error:", error)
                    roomAlert = (error as? MusicLoadError) == .timeout ? .songLoadTimeout : .songNotInCatalog
                }
            }
        }
    }

    // MARK: - Connection observer

    private func startConnectionObserver() {
        connectionObserverTask?.cancel()
        connectionObserverTask = Task { [weak self] in
            var prev: RealtimeConnectionState? = nil
            while !Task.isCancelled {
                guard let self else { return }
                let cur = self.channelManager.connectionState
                if cur != prev {
                    self.applyConnectionState(cur)
                    prev = cur
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func applyConnectionState(_ state: RealtimeConnectionState) {
        switch state {
        case .idle, .connected:
            if syncState == .disconnected {
                syncState = activeSongId.isEmpty ? .idle : (isPaused ? .paused : .playing)
            }
        case .reconnecting:
            syncState = .disconnected
        case .failed:
            syncState = .disconnected
            roomAlert = .reconnectFailed
        }
    }

    // MARK: - Helper

    private func estimatedHostTime(_ state: PlayState) -> TimeInterval {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsed = Double(nowMs - state.hostTimestampMs) / 1000.0
        return state.playbackTime + (state.isPlaying ? elapsed : 0)
    }
}
