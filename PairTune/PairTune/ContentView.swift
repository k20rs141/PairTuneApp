import SwiftUI
import Supabase

struct ContentView: View {
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var showCodeEntry: Bool = false
    @State private var showSettings: Bool = false
    @State private var showSoloMode: Bool = false
    @State private var showPairWaiting: Bool = false

    @State private var homeViewModel = HomeViewModel()
    @State private var pairViewModel = PairViewModel()
    @State private var soloHistoryVM = SoloHistoryViewModel()
    @State private var roomViewModel: RoomViewModel?

    // SoloModeView から検索モーダル経由で曲を選ぶフロー用
    // - search ボタンタップ時に room + search VM を pre-create し SearchSheet を表示
    // - 曲選択 (playAsHost が走り activeSongId が立つ) → onDismiss で RoomView に遷移
    @State private var preparedSoloRoom: RoomViewModel?
    @State private var preparedSearchVM: SearchViewModel?
    @State private var showSoloSearch: Bool = false

    @State private var pendingSendAlert: PairSendAlert?

    var body: some View {
        @Bindable var auth = authViewModel
        ZStack {
            if authViewModel.session == nil {
                SignInView(isProcessing: authViewModel.isLoading) {
                    Task { await authViewModel.signInWithApple() }
                }
                .transition(.opacity)
            } else {
                authenticatedView
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: authViewModel.session == nil)
        .onChange(of: authViewModel.session?.user.id) { _, newUserId in
            if let uid = newUserId {
                Task { await pairViewModel.start(myUserId: uid.uuidString) }
            } else {
                Task { await pairViewModel.stop() }
                roomViewModel = nil
                homeViewModel = HomeViewModel()
                soloHistoryVM = SoloHistoryViewModel()
                // ナビゲーション状態をリセット（再サインイン時に設定画面が残らないよう）
                showSettings = false
                showCodeEntry = false
                showSoloMode = false
                showPairWaiting = false
            }
        }
        .onChange(of: pairViewModel.sendState) { _, newState in
            switch newState {
            case .waiting:
                // 申請が DB に INSERT 成功した直後 → コード入力 sheet を閉じて
                // 承認待ち fullScreenCover を表示する
                showCodeEntry = false
                showPairWaiting = true
            case .accepted:
                // 相手が承認(activePair も立つ) → 承認待ち画面を閉じる
                showPairWaiting = false
            case .rejected:
                showPairWaiting = false
                pendingSendAlert = PairSendAlert(
                    title: "申請が拒否されました",
                    message: "残念ながら相手はペアリングに同意しませんでした。"
                )
            case .expired:
                showPairWaiting = false
                pendingSendAlert = PairSendAlert(
                    title: "申請の有効期限が切れました",
                    message: "申請から 24 時間が経過したため失効しました。もう一度送信してください。"
                )
            case .error(let msg):
                showPairWaiting = false
                pendingSendAlert = PairSendAlert(title: "申請エラー", message: msg)
            default:
                break
            }
        }
        .alert(
            authViewModel.lastError ?? "",
            isPresented: Binding(
                get: { auth.lastError != nil },
                set: { if !$0 { auth.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { auth.lastError = nil }
        }
        .alert(item: $pendingSendAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    pairViewModel.clearSendState()
                }
            )
        }
    }

    // MARK: - Authenticated root

    @ViewBuilder
    private var authenticatedView: some View {
        @Bindable var pairVM = pairViewModel

        ZStack {
            // ホーム + 設定: NavigationStack
            NavigationStack {
                HomeView(
                    pairingCode: authViewModel.pairingCode,
                    myName: authViewModel.currentProfile?.displayName,
                    partnerName: pairViewModel.partnerProfile?.displayName,
                    myAvatarUrl: authViewModel.currentProfile?.avatarUrl,
                    partnerAvatarUrl: pairViewModel.partnerProfile?.avatarUrl,
                    // MVP: presence 未実装。partnerProfile が解決した時点で online とする。
                    // 将来は Realtime Presence や `last_seen_at` で実装。
                    partnerOnline: pairViewModel.partnerProfile != nil,
                    partnerLastSeen: nil,
                    onShareCode: {},
                    onJoin: { showCodeEntry = true },
                    onListenWithPartner: {
                        Task {
                            guard let pair = pairViewModel.activePair else { return }
                            await homeViewModel.loadSharedRoom(roomId: pair.sharedRoomId)
                            guard let sharedRoom = homeViewModel.sharedRoom else { return }
                            roomViewModel = RoomViewModel(sharedRoomV4: sharedRoom, pairId: pair.id)
                        }
                    },
                    onSolo: {
                        showSoloMode = true
                        Task {
                            let userId = authViewModel.session?.user.id.uuidString ?? ""
                            let partnerId = pairViewModel.activePair?.partnerUserId(meId: userId.lowercased())
                            await soloHistoryVM.load(
                                pairId: pairViewModel.activePair?.id,
                                userId: userId,
                                partnerUserId: partnerId
                            )
                        }
                    },
                    onProfile: { showSettings = true },
                    onOpenAndWait: {
                        // オフライン状態でも部屋に入って待機(現状はオンライン時と同じ動作)
                        Task {
                            guard let pair = pairViewModel.activePair else { return }
                            await homeViewModel.loadSharedRoom(roomId: pair.sharedRoomId)
                            guard let sharedRoom = homeViewModel.sharedRoom else { return }
                            roomViewModel = RoomViewModel(sharedRoomV4: sharedRoom, pairId: pair.id)
                        }
                    }
                )
                .toolbar(.hidden, for: .navigationBar)
                // 設定: Navigation push（HIG — 階層的ドリルダウン）
                .navigationDestination(isPresented: $showSettings) {
                    ProfileView(
                        authViewModel: authViewModel,
                        pairViewModel: pairViewModel,
                        sharingPairingCode: authViewModel.pairingCode
                    )
                }
                // Solo モード: Navigation push（HIG — 階層的ドリルダウン）
                .navigationDestination(isPresented: $showSoloMode) {
                    SoloModeView(
                        viewModel: soloHistoryVM,
                        partnerName: pairViewModel.partnerProfile?.displayName,
                        hasPair: pairViewModel.activePair != nil,
                        partnerSharesFavorites: pairViewModel.partnerProfile?.shareFavorites ?? false,
                        userId: authViewModel.session?.user.id.uuidString ?? "",
                        pairId: pairViewModel.activePair?.id,
                        pair: pairViewModel.activePair,
                        onExit: { showSoloMode = false },
                        onPlayTrack: { entry in
                            Task { await startSoloPlayback(entry: entry) }
                        },
                        onSearch: {
                            Task { await openSoloSearch() }
                        },
                        onPair: {
                            showSoloMode = false
                            showCodeEntry = true
                        }
                    )
                    // 検索モーダル: SoloModeView 直接表示。曲選択後 (activeSongId が立った状態で onDismiss)、
                    // pre-created RoomViewModel を表示用 state にコピーして RoomView を開く。
                    .sheet(isPresented: $showSoloSearch, onDismiss: handleSoloSearchDismiss) {
                        if let svm = preparedSearchVM {
                            SearchSheet(isPresented: $showSoloSearch, viewModel: svm)
                        }
                    }
                }
                // コード入力: Modal sheet（HIG — 独立した完結タスク）
                .sheet(isPresented: $showCodeEntry) {
                    CodeEntrySheet(
                        isPresented: $showCodeEntry,
                        submitCode: { code in
                            await pairViewModel.requestPair(targetCode: code)
                        },
                        onRequested: {}
                    )
                }
                // ペア申請中: 承認待ち画面（fullScreenCover）
                // sendState == .waiting の間、A 側に表示。相手の承認(activePair が立つ)で
                // 自動 dismiss → home が paired 状態へ。`requestPair` 直後は code entry の sheet
                // と重なるので、code entry が閉じた後に表示するよう .onChange 監視で開く。
                .fullScreenCover(isPresented: $showPairWaiting) {
                    PairWaitingView(
                        targetCode: nil,
                        expiresAt: pairViewModel.outgoingRequest?.expiresAt,
                        myInitial: String((authViewModel.currentProfile?.displayName ?? "Y").prefix(1)).uppercased(),
                        onCancel: {
                            // 申請を取り消す: cancel_pair_request RPC で DB の status を
                            // 'cancelled' に更新し、B 側が承認できない状態にする
                            Task { await pairViewModel.cancelOutgoingRequest() }
                            showPairWaiting = false
                        },
                        onClose: { showPairWaiting = false }
                    )
                }
                // ペア承認: Modal sheet（HIG — 割り込み通知）
                .sheet(item: $pairVM.pendingRequest) { request in
                    PairApprovalSheet(
                        request: request,
                        requester: pairViewModel.pendingRequester,
                        mode: pairViewModel.showingCelebration
                            ? .celebrating(
                                partnerName: pairViewModel.partnerProfile?.displayName ?? "パートナー",
                                partnerInitial: String((pairViewModel.partnerProfile?.displayName ?? "P").prefix(1)).uppercased()
                            )
                            : .incoming,
                        myInitial: String((authViewModel.currentProfile?.displayName ?? "Y").prefix(1)).uppercased(),
                        onAccept: { Task { await pairViewModel.acceptIncoming() } },
                        onReject: { Task { await pairViewModel.rejectIncoming() } },
                        onDefer: { pairViewModel.dismissIncoming() },
                        onEnterRoom: {
                            Task {
                                guard let pair = pairViewModel.activePair else {
                                    pairViewModel.finishCelebration()
                                    return
                                }
                                await homeViewModel.loadSharedRoom(roomId: pair.sharedRoomId)
                                pairViewModel.finishCelebration()
                                guard let sharedRoom = homeViewModel.sharedRoom else { return }
                                roomViewModel = RoomViewModel(sharedRoomV4: sharedRoom, pairId: pair.id)
                            }
                        }
                    )
                }
            }

            // ルーム: ZStack オーバーレイ（fullScreenCover 内の .sheet 競合を回避）
            if let vm = roomViewModel {
                RoomViewWrapper(
                    roomViewModel: vm,
                    authViewModel: authViewModel,
                    pairViewModel: pairViewModel,
                    onExit: {
                        // 再生中の閉じるは RoomView のダイアログで「閉じる(再生は続ける)」を選んだ後のみ
                        // 到達する。leaveRoom は keepPlaying=true で呼び、ApplicationMusicPlayer.shared
                        // による再生は継続させる。停止したい場合はユーザーが一時停止してから閉じる。
                        let leavingVM = vm
                        let stillPlaying = leavingVM.musicService.isPlaying
                        roomViewModel = nil
                        Task { await leavingVM.leaveRoom(keepPlaying: stillPlaying) }
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: roomViewModel != nil)
    }

    // MARK: - Solo playback helpers

    /// Solo モードで指定曲(または最後に聴いた曲)を再生してルームを開く。
    /// 1) myRoom をロード → RoomViewModel 生成
    /// 2) pendingInitialTrack に Track を仕込む(enterRoom 後に playAsHost が走る)
    /// 3) roomViewModel に代入 → RoomView オーバーレイ表示 → .task で enterRoom + 自動再生
    private func startSoloPlayback(entry: PlayHistoryEntry?) async {
        await homeViewModel.loadMyRoom()
        guard let myRoom = homeViewModel.myRoom else { return }
        let vm = RoomViewModel(myRoom: myRoom)
        vm.pendingInitialTrack = entry?.toTrack()
        roomViewModel = vm
    }

    /// SoloModeView の検索ボタン → SearchSheet モーダルを直接表示する。
    /// RoomViewModel + SearchViewModel を裏で生成しておき、曲選択時に SearchViewModel が
    /// playAsHost を呼ぶ。onDismiss で activeSongId をチェックし、再生開始済みなら RoomView へ。
    private func openSoloSearch() async {
        await homeViewModel.loadMyRoom()
        guard let myRoom = homeViewModel.myRoom else { return }
        let vm = RoomViewModel(myRoom: myRoom)
        // SearchSheet 内の playAsHost 用に enterRoom を済ませて musicService の権限を取得しておく
        let userId = authViewModel.session?.user.id.uuidString ?? ""
        await vm.enterRoom(userId: userId, displayName: nil)
        preparedSoloRoom = vm
        preparedSearchVM = SearchViewModel(roomViewModel: vm)
        showSoloSearch = true
    }

    private func handleSoloSearchDismiss() {
        defer {
            preparedSoloRoom = nil
            preparedSearchVM = nil
        }
        guard let vm = preparedSoloRoom else { return }
        // 曲が選ばれて playAsHost が走った場合のみ activeSongId が立つ。立っていなければ
        // ユーザーがキャンセルしたとみなし、ルームを開かずに破棄する。
        if !vm.activeSongId.isEmpty {
            roomViewModel = vm
        } else {
            Task { await vm.leaveRoom() }
        }
    }
}

// MARK: - Pair send alert payload

private struct PairSendAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - RoomView Wrapper

private struct RoomViewWrapper: View {
    @Bindable var roomViewModel: RoomViewModel
    let authViewModel: AuthViewModel
    let pairViewModel: PairViewModel
    var onExit: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RoomView(
            roomViewModel: roomViewModel,
            isHost: roomViewModel.isHost,
            participantCount: max(1, roomViewModel.onlineParticipants.count),
            guestJoining: !roomViewModel.isHost,
            meName: authViewModel.currentProfile?.displayName ?? "あなた",
            partnerName: pairViewModel.partnerProfile?.displayName,
            myAvatarUrl: authViewModel.currentProfile?.avatarUrl,
            partnerAvatarUrl: pairViewModel.partnerProfile?.avatarUrl,
            onExit: onExit,
            onSelectTrack: { _ in }
        )
        .task {
            let userId = authViewModel.session?.user.id.uuidString ?? ""
            let name = authViewModel.session?.user.userMetadata["full_name"]?.stringValue
            await roomViewModel.enterRoom(userId: userId, displayName: name)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                let userId = authViewModel.session?.user.id.uuidString ?? ""
                let name = authViewModel.session?.user.userMetadata["full_name"]?.stringValue
                Task {
                    await roomViewModel.reconnect(userId: userId, displayName: name)
                }
            }
        }
        .alert(item: $roomViewModel.roomAlert) { alert in
            switch alert {
            case .appleMusicNotSubscribed:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("設定を開く")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel(Text("閉じる"))
                )
            case .reconnectFailed:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("リトライ")) {
                        Task { await roomViewModel.retryConnection() }
                    },
                    secondaryButton: .cancel(Text("閉じる"))
                )
            default:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthViewModel())
}
