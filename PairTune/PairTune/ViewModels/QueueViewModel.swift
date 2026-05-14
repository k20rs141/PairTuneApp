import Foundation
import Supabase

// MARK: - QueueViewModel (v0.4 §2.15)
//
// 再生キューの state を保持し、Solo は in-memory、Shared は room_queue + Realtime で
// 両端末同期する。RoomViewModel から `init(mode:roomId:userId:)` で組み立てる。
//
// 設計上の注意:
// - Solo モードの items は配列上の position プロパティをアプリ側で連番管理する
// - Shared モードでは room_queue 行を fetch / insert / delete / update し、別端末からの
//   postgres_changes をリッスンして refresh()
// - キュー先頭の曲が再生開始されたら remove(first) で外側 RoomViewModel が消す想定

@Observable
@MainActor
final class QueueViewModel {

    enum Mode {
        case solo
        case shared
    }

    let mode: Mode
    /// Shared モード時の room_queue.room_id(shared_room の UUID)。Solo では nil。
    private let roomId: String?
    private let myUserId: String

    /// Up Next 一覧(position 昇順)
    private(set) var items: [QueueItem] = []

    private let service = QueueService()
    private let client = SupabaseManager.shared.client
    private var realtimeChannel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?

    init(mode: Mode, roomId: String?, myUserId: String) {
        self.mode = mode
        self.roomId = roomId
        self.myUserId = myUserId
    }

    // MARK: - Lifecycle

    /// 初回ロード + Shared の場合は Realtime 購読開始
    func start() async {
        await refresh()
        if mode == .shared {
            await subscribeRealtime()
        }
    }

    func stop() async {
        listenTask?.cancel()
        listenTask = nil
        if let ch = realtimeChannel {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await ch.unsubscribe() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
        realtimeChannel = nil
    }

    // MARK: - Read

    func refresh() async {
        guard mode == .shared, let roomId else { return }
        do {
            items = try await service.fetchQueue(roomId: roomId)
        } catch {
            print("[QueueViewModel] refresh error:", error)
        }
    }

    // MARK: - Mutations

    /// 末尾に追加(検索結果 → 「+ 追加」フローから呼ぶ)
    func enqueue(_ track: Track) async {
        switch mode {
        case .solo:
            let item = QueueItem.localItem(
                from: track,
                position: items.count,
                addedBy: myUserId.isEmpty ? nil : myUserId
            )
            items.append(item)
        case .shared:
            guard let roomId else { return }
            do {
                let item = try await service.enqueue(roomId: roomId, track: track, addedBy: myUserId)
                // optimistic local insert; realtime も来るがすぐに反映したい
                if !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                }
            } catch {
                print("[QueueViewModel] enqueue error:", error)
            }
        }
    }

    /// 「次に再生」(現再生の直後に挿入)
    func playNext(_ track: Track, afterPosition: Int) async {
        switch mode {
        case .solo:
            let insertAt = max(0, afterPosition + 1)
            // 既存の position をシフト
            for i in items.indices where items[i].position >= insertAt {
                items[i].position += 1
            }
            let item = QueueItem.localItem(
                from: track,
                position: insertAt,
                addedBy: myUserId.isEmpty ? nil : myUserId
            )
            items.append(item)
            items.sort { $0.position < $1.position }
        case .shared:
            guard let roomId else { return }
            do {
                _ = try await service.insertNext(
                    roomId: roomId,
                    afterPosition: afterPosition,
                    track: track,
                    addedBy: myUserId
                )
                await refresh()
            } catch {
                print("[QueueViewModel] playNext error:", error)
            }
        }
    }

    func remove(itemId: String) async {
        switch mode {
        case .solo:
            items.removeAll { $0.id == itemId }
        case .shared:
            do {
                try await service.remove(itemId: itemId)
                items.removeAll { $0.id == itemId }
            } catch {
                print("[QueueViewModel] remove error:", error)
            }
        }
    }

    /// キュー全消し。Solo 退室 / Shared 退室時に呼ぶ。
    func clear() async {
        switch mode {
        case .solo:
            items.removeAll()
        case .shared:
            guard let roomId else { return }
            do {
                try await service.clear(roomId: roomId)
                items.removeAll()
            } catch {
                print("[QueueViewModel] clear error:", error)
            }
        }
    }

    /// キュー先頭の 1 件を取り出して再生対象として返す(RoomViewModel が呼ぶ)。
    /// 取り出した行は同時に削除される。
    func popFirst() async -> QueueItem? {
        guard let first = items.first else { return nil }
        await remove(itemId: first.id)
        return first
    }

    /// 並べ替え結果を反映(QueueSheet の drag-drop 完了時に呼ぶ)。
    /// items の現在の並び順そのものを新しい position として扱う。
    func reorder(_ newOrder: [QueueItem]) async {
        items = newOrder.enumerated().map { idx, item in
            var copy = item
            copy.position = idx
            return copy
        }
        if mode == .shared {
            do {
                try await service.reorder(items: items)
            } catch {
                print("[QueueViewModel] reorder error:", error)
            }
        }
    }

    // MARK: - Realtime (shared only)

    private func subscribeRealtime() async {
        guard let roomId else { return }
        let channel = client.realtimeV2.channel("room_queue:\(roomId)")
        let inserts = channel.postgresChange(InsertAction.self, table: "room_queue", filter: "room_id=eq.\(roomId)")
        let updates = channel.postgresChange(UpdateAction.self, table: "room_queue", filter: "room_id=eq.\(roomId)")
        let deletes = channel.postgresChange(DeleteAction.self, table: "room_queue", filter: "room_id=eq.\(roomId)")
        await channel.subscribe()
        realtimeChannel = channel

        listenTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await _ in inserts { await self?.refresh() }
                }
                group.addTask { [weak self] in
                    for await _ in updates { await self?.refresh() }
                }
                group.addTask { [weak self] in
                    for await _ in deletes { await self?.refresh() }
                }
            }
        }
    }
}
