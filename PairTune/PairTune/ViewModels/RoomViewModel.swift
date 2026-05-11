import Foundation
import MusicKit
import Supabase

// M4: Solo モード(ローカル再生 + my_room_play_history 記録)を追加。
// 既存の Shared(v0.2)は mode == .shared として維持し、M5 で両者対等ホストに昇格。
// 仕様: docs/PairTune_Specification_v0.4.md §7
// 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §7

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
        case .hostOffline:             return "ホストがオフラインです"
        case .playbackFailed:          return "再生に失敗しました"
        }
    }

    var message: String {
        switch self {
        case .appleMusicNotSubscribed: return "設定アプリから Apple Music をご契約ください。"
        case .songNotInCatalog:        return "地域カタログにない曲の可能性があります。別の曲を選んでください。"
        case .songLoadTimeout:         return "ネットワーク状況をご確認ください。"
        case .reconnectFailed:         return "通信状況をご確認のうえリトライしてください。"
        case .hostOffline:             return "ローカル再生は継続しています。"
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

    // Solo モード用: 履歴記録に使う userId(enterRoom 時に設定)
    private var soloUserId: String = ""

    // MARK: - Display state (RoomView が読む)

    var syncState: SyncState = .idle
    var currentTrack: Track?
    var isPaused: Bool = false
    var progress: Int { Int(musicService.currentPlaybackTime) }

    // MARK: - Alert state (RoomView が .alert(item:) で読む)
    var roomAlert: RoomAlert?

    // MARK: - 接続状態
    private var connectionObserverTask: Task<Void, Never>?

    // MARK: - ホストオフライン監視 (ゲスト側のみ)
    private var lastPlayStateAt: Date = Date()
    private var hostWatchTask: Task<Void, Never>?
    private var hostOfflineNotified: Bool = false

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

    // Solo モード用: 30秒履歴タイマー
    private var historyTimerTask: Task<Void, Never>?

    // デバッグ用
    var debugLastDriftMs: Double = 0
    var debugLastSeq: Int = 0

    // MARK: - Init (Shared モード — v0.2 互換)

    init(room: Room, isHost: Bool) {
        self.currentRoom = room
        self.isHost = isHost
        self.mode = .shared
    }

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

    // MARK: - Lifecycle

    func enterRoom(userId: String, displayName: String?) async {
        _ = await musicService.requestAuthorization()

        // Solo モード: Realtime 接続は不要、userId だけ保持して終わり
        if mode == .solo {
            soloUserId = userId
            return
        }

        startConnectionObserver()

        await channelManager.connect(
            roomCode: currentRoom.code,
            userId: userId,
            isHost: isHost,
            displayName: displayName
        )

        if isHost {
            startHostBroadcast()
        } else {
            startGuestListeners()
            startHostOfflineWatcher()
            // ホストがすでに再生中かチェック
            await syncToCurrentRoomState()
        }
    }

    func reconnect(userId: String, displayName: String?) async {
        // Solo モード: 再接続は不要
        if mode == .solo { return }

        await channelManager.reconnect(
            roomCode: currentRoom.code,
            userId: userId,
            isHost: isHost,
            displayName: displayName
        )
        if isHost {
            startHostBroadcast()
        } else {
            startGuestListeners()
        }
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
        hostWatchTask?.cancel()
        await channelManager.disconnect()
        try? await roomService.leaveRoom(roomId: currentRoom.id, isHost: isHost)
    }

    /// 接続失敗アラートのリトライボタンから呼ぶ。
    func retryConnection() async {
        // Solo モード: Realtime は使わないためリトライ不要
        if mode == .solo { return }

        await channelManager.retryFromFailure()
        guard case .connected = channelManager.connectionState else { return }
        if isHost {
            startHostBroadcast()
        } else {
            startGuestListeners()
            startHostOfflineWatcher()
        }
    }

    // MARK: - Host actions

    /// SearchSheet から曲が選ばれた時に呼ばれる
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
                // Shared: DB に保存して PlayEvent を 2 連投
                try? await roomService.updateCurrentSong(roomId: currentRoom.id, songId: songId)
                let event = PlayEvent(type: .play, songId: songId, playbackTime: musicService.currentTime())
                await channelManager.broadcast(event: "play_event", message: event)
                await channelManager.broadcast(event: "play_event", message: event)
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
                let event = PlayEvent(type: .play, songId: activeSongId, playbackTime: musicService.currentTime())
                await channelManager.broadcast(event: "play_event", message: event)
                await channelManager.broadcast(event: "play_event", message: event)
            }
        }
    }

    // MARK: - Solo: 30秒履歴タイマー

    /// 曲が変わるたびにリスタートし、30秒経過したら my_room_play_history に記録する。
    private func startHistoryTimer(for track: Track) {
        historyTimerTask?.cancel()
        historyTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            await self.historyService.recordSoloPlay(track, userId: self.soloUserId, duration: 30)
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
                        seq: seq
                    )
                    await self.channelManager.broadcast(event: "play_state", message: state)
                }
                seq += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Guest listeners

    private func startGuestListeners() {
        stateListenerTask?.cancel()
        eventListenerTask?.cancel()

        guard let psStream = channelManager.playStateStream,
              let peStream = channelManager.playEventStream else { return }

        stateListenerTask = Task { [weak self] in
            for await json in psStream {
                guard let self else { return }
                // broadcastStream は envelope {event, payload, type} を yield するので
                // 内側の "payload" を取り出してからデコードする
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

    /// ゲスト後入室: DB の current_song_id があればロードだけ行い、再生は PlayState/PlayEvent を待つ。
    /// ホストがオンラインでない/再生中でないのに古い曲を勝手に流さないため。
    private func syncToCurrentRoomState() async {
        guard let songId = currentRoom.currentSongId, !songId.isEmpty else { return }
        guard activeSongId != songId else { return }

        activeSongId = songId
        syncState = .loading
        do {
            try await musicService.load(songId: songId, at: 0)
            // 即時 pause: ホストが現に再生していれば PlayState (isPlaying=true) で再開される。
            // ホストがオフライン/未選曲なら静かに待機する。
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

    // MARK: - PlayState correction (guest)

    private func applyPlayState(_ state: PlayState) async {
        debugLastSeq = state.seq
        lastPlayStateAt = Date()
        hostOfflineNotified = false

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

    // MARK: - PlayEvent handler (guest)

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
            // RealtimeChannelManager の connectionState は @Observable なので、
            // 明示的にポーリングして変化を syncState/roomAlert に反映する。
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

    // MARK: - Host offline watcher (guest only)

    private func startHostOfflineWatcher() {
        hostWatchTask?.cancel()
        lastPlayStateAt = Date()
        hostOfflineNotified = false
        hostWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                // 再生中(activeSongId 設定済み)かつホストが presence にいなければオフライン扱い
                guard !self.activeSongId.isEmpty else { continue }
                let hostOnline = self.channelManager.onlineUsers.contains { $0.role == "host" }
                if hostOnline {
                    // presence にホストがいる: 通知済みフラグもリセット(再オンライン後の再判定用)
                    self.hostOfflineNotified = false
                    continue
                }
                let elapsed = Date().timeIntervalSince(self.lastPlayStateAt)
                if elapsed > 5, !self.hostOfflineNotified {
                    self.hostOfflineNotified = true
                    self.roomAlert = .hostOffline
                }
            }
        }
    }

    // MARK: - Helper

    private func estimatedHostTime(_ state: PlayState) -> TimeInterval {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsed = Double(nowMs - state.hostTimestampMs) / 1000.0
        return state.playbackTime + (state.isPlaying ? elapsed : 0)
    }
}
