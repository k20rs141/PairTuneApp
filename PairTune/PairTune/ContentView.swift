import SwiftUI
import Supabase

struct ContentView: View {
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var screen: AppScreen = .signIn
    @State private var showCodeEntry: Bool = false
    @State private var showSettings: Bool = false

    @State private var homeViewModel = HomeViewModel()
    @State private var pairViewModel = PairViewModel()
    @State private var roomViewModel: RoomViewModel?

    /// 送信側の終端状態(rejected/expired/error)を一度だけ表示するためのフラグ
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
            // session 立ち上がり / 切断で PairViewModel を起動・停止
            if let uid = newUserId {
                Task { await pairViewModel.start(myUserId: uid.uuidString) }
            } else {
                Task { await pairViewModel.stop() }
                screen = .signIn
                homeViewModel = HomeViewModel()
            }
        }
        .onChange(of: pairViewModel.sendState) { _, newState in
            // 送信側終端状態を alert にバインド
            switch newState {
            case .rejected:
                pendingSendAlert = PairSendAlert(
                    title: "申請が拒否されました",
                    message: "残念ながら相手はペアリングに同意しませんでした。"
                )
            case .expired:
                pendingSendAlert = PairSendAlert(
                    title: "申請の有効期限が切れました",
                    message: "申請から 24 時間が経過したため失効しました。もう一度送信してください。"
                )
            case .error(let msg):
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

    @ViewBuilder
    private var authenticatedView: some View {
        @Bindable var pairVM = pairViewModel
        ZStack {
            switch screen {
            case .signIn:
                Color.clear.onAppear { screen = .home }

            case .home:
                // v0.4: pairVM.activePair の有無で state A / B を切替
                HomeView(
                    pairingCode: authViewModel.pairingCode,
                    partnerName: pairViewModel.partnerProfile?.displayName,
                    onShareCode: {
                        // ShareLink を直接埋め込めないので、HomeView 側からは
                        // 何もせず、settings 等から共有する想定。M3 では minimal。
                        // (TODO: M3 仕上げで HomeView に ShareLink を埋め込む)
                    },
                    onJoin: {
                        showCodeEntry = true
                    },
                    onListenWithPartner: {
                        // M5 (Shared モード) で実装。現状ボタン自体 disabled。
                    },
                    onSolo: {
                        Task {
                            await homeViewModel.loadMyRoom()
                            guard let myRoom = homeViewModel.myRoom else { return }
                            let vm = RoomViewModel(myRoom: myRoom)
                            roomViewModel = vm
                            withAnimation(.easeInOut(duration: 0.3)) {
                                screen = .room
                            }
                        }
                    },
                    onProfile: {
                        showSettings = true
                    }
                )
                .transition(.opacity)
                .sheet(isPresented: $showCodeEntry) {
                    CodeEntrySheet(
                        isPresented: $showCodeEntry,
                        submitCode: { code in
                            await pairViewModel.requestPair(targetCode: code)
                        },
                        onRequested: {
                            // sendState は requestPair 内で .waiting に更新済み
                        }
                    )
                }
                .sheet(item: $pairVM.pendingRequest) { request in
                    PairApprovalSheet(
                        request: request,
                        requester: pairViewModel.pendingRequester,
                        onAccept: {
                            Task { await pairViewModel.acceptIncoming() }
                        },
                        onReject: {
                            Task { await pairViewModel.rejectIncoming() }
                        },
                        onDefer: {
                            pairViewModel.dismissIncoming()
                        }
                    )
                }
                .sheet(isPresented: $showSettings) {
                    SettingsSheet(
                        authViewModel: authViewModel,
                        pairViewModel: pairViewModel,
                        sharingPairingCode: authViewModel.pairingCode,
                        onDismiss: { showSettings = false }
                    )
                }

            case .room:
                if let vm = roomViewModel {
                    RoomViewWrapper(
                        roomViewModel: vm,
                        authViewModel: authViewModel,
                        onExit: {
                            let leavingVM = vm
                            roomViewModel = nil
                            withAnimation(.easeInOut(duration: 0.3)) {
                                screen = .home
                            }
                            Task { await leavingVM.leaveRoom() }
                        }
                    )
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: screen)
        .onAppear {
            if screen == .signIn { screen = .home }
        }
    }
}

// MARK: - Pair send alert payload

private struct PairSendAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Settings Sheet

private struct SettingsSheet: View {
    let authViewModel: AuthViewModel
    let pairViewModel: PairViewModel
    let sharingPairingCode: String?
    var onDismiss: () -> Void

    @State private var safariURL: URL?
    @State private var showDeleteConfirm1 = false
    @State private var showDeleteConfirm2 = false
    @State private var isDeleting = false

    @State private var showEndPairConfirm = false
    @State private var isEndingPair = false
    @State private var preserveMemoriesChoice = true

    var body: some View {
        NavigationStack {
            ZStack {
                Color.pairtuneBase.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Pairing code share (M3 で追加: ShareLink で配布)
                    if let code = sharingPairingCode {
                        ShareLink(
                            item: pairtuneInviteURL(for: code),
                            subject: Text("PairTune でペアリングしませんか?"),
                            message: Text("PairTune で一緒に音楽を聴きましょう。\nコード: \(code)")
                        ) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 14))
                                    .foregroundColor(.pairtuneTextSecondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("コードを共有")
                                        .font(.system(size: 15))
                                        .foregroundColor(.white)
                                    Text(code)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.pairtuneTextTertiary)
                                        .tracking(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.pairtuneTextTertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                    }

                    // Pair management (M3 追加: 解消ボタン)
                    if pairViewModel.activePair != nil {
                        VStack(spacing: 0) {
                            Button(role: .destructive) {
                                showEndPairConfirm = true
                            } label: {
                                HStack {
                                    Image(systemName: "person.2.slash")
                                        .font(.system(size: 14))
                                        .foregroundColor(.pairtuneSyncBad)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("ペアリングを解消")
                                            .font(.system(size: 15))
                                            .foregroundColor(.pairtuneSyncBad)
                                        if let partner = pairViewModel.partnerProfile?.displayName {
                                            Text(partner)
                                                .font(.system(size: 11))
                                                .foregroundColor(.pairtuneTextTertiary)
                                        }
                                    }
                                    Spacer()
                                    if isEndingPair {
                                        SpinnerView(color: .pairtuneSyncBad, size: 14)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .disabled(isEndingPair)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                    }

                    VStack(spacing: 0) {
                        SettingsRow(label: "利用規約", systemImage: "doc.text") {
                            safariURL = AppLinks.termsOfService
                        }
                        Divider().background(Color.white.opacity(0.06))
                        SettingsRow(label: "プライバシーポリシー", systemImage: "lock.shield") {
                            safariURL = AppLinks.privacyPolicy
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                    Spacer()

                    VStack(spacing: 12) {
                        Button {
                            onDismiss()
                            Task { await authViewModel.signOut() }
                        } label: {
                            Text("ログアウト")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                                        )
                                )
                        }

                        Button(role: .destructive) {
                            showDeleteConfirm1 = true
                        } label: {
                            HStack(spacing: 8) {
                                if isDeleting {
                                    SpinnerView(color: .pairtuneSyncBad, size: 16)
                                }
                                Text("アカウントを削除")
                                    .font(.system(size: 15, weight: .regular))
                            }
                            .foregroundColor(.pairtuneSyncBad)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .disabled(isDeleting)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .sheet(item: Binding(
            get: { safariURL.map { IdentifiableURL(url: $0) } },
            set: { safariURL = $0?.url }
        )) { wrapper in
            SafariView(url: wrapper.url)
                .ignoresSafeArea()
        }
        .confirmationDialog(
            "アカウントを削除しますか?",
            isPresented: $showDeleteConfirm1,
            titleVisibility: .visible
        ) {
            Button("削除する", role: .destructive) { showDeleteConfirm2 = true }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("マイルームと参加履歴がすべて消えます。この操作は取り消せません。")
        }
        .alert("本当に削除しますか?", isPresented: $showDeleteConfirm2) {
            Button("削除", role: .destructive) {
                isDeleting = true
                Task {
                    let ok = await authViewModel.deleteAccount()
                    isDeleting = false
                    if ok { onDismiss() }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除すると元に戻せません。")
        }
        .confirmationDialog(
            "ペアリングを解消しますか?",
            isPresented: $showEndPairConfirm,
            titleVisibility: .visible
        ) {
            Button("解消する(思い出を残す)") {
                preserveMemoriesChoice = true
                runEndPair()
            }
            Button("解消する(履歴も削除)", role: .destructive) {
                preserveMemoriesChoice = false
                runEndPair()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「思い出を残す」を選ぶと、これまでの再生履歴は閲覧専用で残ります。\n「履歴も削除」を選ぶと 90 日後に完全削除されます。")
        }
    }

    private func runEndPair() {
        isEndingPair = true
        Task {
            _ = await pairViewModel.endActivePair(preserveMemories: preserveMemoriesChoice)
            isEndingPair = false
        }
    }

    private func pairtuneInviteURL(for code: String) -> URL {
        URL(string: "pairtune://room/\(code)") ?? URL(string: "https://pairtune.app")!
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SettingsRow: View {
    let label: String
    let systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                    .foregroundColor(.pairtuneTextSecondary)
                    .frame(width: 22)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.pairtuneTextTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - RoomView Wrapper

private struct RoomViewWrapper: View {
    @Bindable var roomViewModel: RoomViewModel
    let authViewModel: AuthViewModel
    var onExit: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RoomView(
            roomViewModel: roomViewModel,
            isHost: roomViewModel.isHost,
            participantCount: max(1, roomViewModel.onlineParticipants.count),
            guestJoining: !roomViewModel.isHost,
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
