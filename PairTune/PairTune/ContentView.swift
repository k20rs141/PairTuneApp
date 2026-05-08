import SwiftUI
import Supabase

struct ContentView: View {
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var screen: AppScreen = .signIn
    @State private var showCodeEntry: Bool = false
    @State private var showSettings: Bool = false

    @State private var homeViewModel = HomeViewModel()
    @State private var joinViewModel = JoinRoomViewModel()
    @State private var roomViewModel: RoomViewModel?

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
        .onChange(of: authViewModel.session == nil) { _, isSignedOut in
            if isSignedOut {
                screen = .signIn
                homeViewModel = HomeViewModel()
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
    }

    @ViewBuilder
    private var authenticatedView: some View {
        ZStack {
            switch screen {
            case .signIn:
                Color.clear.onAppear { screen = .home }

            case .home:
                HomeView(
                    onCreate: {
                        Task {
                            await homeViewModel.loadMyRoom()
                            guard let room = homeViewModel.myRoom else { return }
                            let vm = RoomViewModel(room: room, isHost: true)
                            roomViewModel = vm
                            withAnimation(.easeInOut(duration: 0.3)) {
                                screen = .room
                            }
                            let userId = authViewModel.session?.user.id.uuidString ?? ""
                            let name = authViewModel.session?.user.userMetadata["full_name"]?.stringValue
                            await vm.enterRoom(userId: userId, displayName: name)
                        }
                    },
                    onJoin: {
                        showCodeEntry = true
                    },
                    onProfile: {
                        showSettings = true
                    }
                )
                .transition(.opacity)
                .sheet(isPresented: $showCodeEntry) {
                    CodeEntrySheet(
                        isPresented: $showCodeEntry,
                        onJoin: {
                            if let room = joinViewModel.joinedRoom {
                                let vm = RoomViewModel(room: room, isHost: false)
                                roomViewModel = vm
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    screen = .room
                                }
                                let userId = authViewModel.session?.user.id.uuidString ?? ""
                                let name = authViewModel.session?.user.userMetadata["full_name"]?.stringValue
                                Task { await vm.enterRoom(userId: userId, displayName: name) }
                            }
                        },
                        validateCode: { code in
                            await joinViewModel.joinRoom(code: code)
                        }
                    )
                }
                .sheet(isPresented: $showSettings) {
                    SettingsSheet(
                        authViewModel: authViewModel,
                        onDismiss: { showSettings = false }
                    )
                }
                .alert(
                    homeViewModel.lastError ?? "",
                    isPresented: Binding(
                        get: { homeViewModel.lastError != nil },
                        set: { if !$0 { homeViewModel.lastError = nil } }
                    )
                ) {
                    Button("リトライ") {
                        homeViewModel.lastError = nil
                        Task { await homeViewModel.reloadMyRoom() }
                    }
                    Button("キャンセル", role: .cancel) {
                        homeViewModel.lastError = nil
                    }
                }

            case .room:
                if let vm = roomViewModel {
                    RoomViewWrapper(
                        roomViewModel: vm,
                        authViewModel: authViewModel,
                        onExit: {
                            // 画面遷移を先に行い、後始末はバックグラウンドで(WS 切断や DB 更新が
                            // 遅延しても画面が固まらないように)
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
        .task(id: authViewModel.session?.user.id) {
            guard authViewModel.session != nil else { return }
            await homeViewModel.loadMyRoom()
        }
    }
}

// MARK: - Settings Sheet

private struct SettingsSheet: View {
    let authViewModel: AuthViewModel
    var onDismiss: () -> Void

    @State private var safariURL: URL?
    @State private var showDeleteConfirm1 = false
    @State private var showDeleteConfirm2 = false
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.pairtuneBase.ignoresSafeArea()

                VStack(spacing: 0) {
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
