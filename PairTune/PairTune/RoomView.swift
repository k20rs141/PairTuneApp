import SwiftUI
import Combine

struct RoomView: View {
    let roomViewModel: RoomViewModel
    var isHost: Bool = true
    var participantCount: Int = 2
    var guestJoining: Bool = false
    var onExit: () -> Void
    var onSelectTrack: (Track) -> Void

    @State private var toastMessage: String? = nil
    @State private var showSearch: Bool = false
    @State private var showDebug: Bool = false
    @State private var searchViewModel: SearchViewModel?

    private var syncState: SyncState { roomViewModel.syncState }
    private var currentTrack: Track? { roomViewModel.currentTrack }
    private var isPaused: Bool { roomViewModel.isPaused }
    private var progress: Int { roomViewModel.progress }
    private var dominant: Color { currentTrack?.dominant ?? .pairtuneCoral }

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            // Ambient color bleed from artwork
            VStack {
                RadialGradient(
                    colors: [dominant.opacity(0.45), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 360
                )
                .blur(radius: 30)
                .frame(height: 480)
                .opacity(syncState == .idle || syncState == .disconnected ? 0.2 : 0.7)
                .animation(.easeInOut(duration: 0.6), value: syncState)
                .allowsHitTesting(false)
                Spacer()
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Disconnect banner
                if syncState == .disconnected {
                    disconnectBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                // Header
                headerBar

                // Main content
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        // Artwork
                        ArtworkCardView(track: currentTrack, state: syncState)
                            .aspectRatio(1, contentMode: .fit)
                            .padding(.horizontal, geo.size.width * 0.12)
                            .padding(.top, 20)

                        // Track info
                        trackInfo
                            .padding(.top, 22)
                            .padding(.horizontal, 28)

                        // Progress bar
                        if syncState != .idle {
                            progressBar(width: geo.size.width - 56)
                                .padding(.top, 22)
                                .padding(.horizontal, 28)
                        }

                        // Sync wave (V5 Deep redesign)
                        SyncWaveView(state: syncState, primary: .pairtunePrimary, secondary: .pairtuneSecondary)
                            .padding(.top, 18)

                        Spacer()

                        // Participants + controls
                        VStack(spacing: 14) {
                            participantsRow
                            if isHost { hostControls }
                            else       { guestLabel }
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 38)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: syncState)

            // Toast overlay
            if let msg = toastMessage {
                VStack {
                    Spacer()
                    ToastView(message: msg)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .padding(.bottom, 130)
                }
                .animation(.easeOut(duration: 0.25), value: toastMessage != nil)
            }

            // Debug overlay (3本指タップで表示)
            if showDebug {
                debugOverlay
            }
        }
        .onTapGesture(count: 1) { }
        .simultaneousGesture(
            TapGesture(count: 3).onEnded { showDebug.toggle() }
        )
        .task {
            if roomViewModel.isHost {
                searchViewModel = SearchViewModel(roomViewModel: roomViewModel)
            }
        }
        .sheet(isPresented: $showSearch) {
            if let vm = searchViewModel {
                @Bindable var bindableVM = vm
                SearchSheet(isPresented: $showSearch, viewModel: vm)
                    .alert(
                        bindableVM.searchError ?? "",
                        isPresented: Binding(
                            get: { bindableVM.searchError != nil },
                            set: { if !$0 { bindableVM.searchError = nil } }
                        )
                    ) {
                        if bindableVM.subscriptionMissing {
                            Button("設定を開く") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                                bindableVM.searchError = nil
                            }
                            Button("閉じる", role: .cancel) { bindableVM.searchError = nil }
                        } else {
                            Button("OK", role: .cancel) { bindableVM.searchError = nil }
                        }
                    }
            }
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            FrostedCircleButton(icon: "rectangle.portrait.and.arrow.forward", size: 38) {
                onExit()
            }

            Spacer()

            Button {
                UIPasteboard.general.string = roomViewModel.currentRoom.code
                showToast("コードをコピーしました · Code copied")
            } label: {
                VStack(spacing: 2) {
                    Text(roomViewModel.currentRoom.code)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .tracking(3.5)
                    Text("TAP TO COPY")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(.pairtuneTextTertiary)
                        .tracking(0.6)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
            }

            Spacer()

            FrostedCircleButton(icon: "square.and.arrow.up", size: 38) {
                showToast("招待リンクをシェア · Share invite")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var trackInfo: some View {
        VStack(spacing: 0) {
            if syncState == .idle {
                Text(isHost ? "曲を選んでください" : "ホストが選曲中…")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                Text(isHost ? "Pick a song to begin" : "The host is choosing")
                    .font(.system(size: 12))
                    .foregroundColor(.pairtuneTextTertiary)
                    .padding(.top, 5)
            } else {
                Text(currentTrack?.title ?? mockTrack.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .tracking(0.1)
                Text(currentTrack?.artist ?? mockTrack.artist)
                    .font(.system(size: 14))
                    .foregroundColor(.pairtuneTextSecondary)
                    .padding(.top, 4)
                    .tracking(0.2)
            }
        }
        .multilineTextAlignment(.center)
    }

    private func progressBar(width: CGFloat) -> some View {
        let duration = currentTrack?.duration ?? mockTrack.duration
        let ratio = max(0, min(1, Double(progress) / Double(max(1, duration))))

        return VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 3)

                Capsule()
                    .fill(Color.pairtuneCoral)
                    .frame(width: max(0, width * ratio), height: 3)
                    .shadow(color: Color.pairtuneCoral.opacity(0.5), radius: 4)
                    .animation(.linear(duration: 1), value: progress)

                Circle()
                    .fill(Color.pairtuneCoral)
                    .frame(width: 9, height: 9)
                    .shadow(color: Color.pairtuneCoral.opacity(0.8), radius: 6)
                    .offset(x: max(0, width * ratio - 4.5))
                    .animation(.linear(duration: 1), value: progress)
            }

            HStack {
                Text(fmt(progress))
                Spacer()
                Text("−\(fmt(max(0, duration - progress)))")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.pairtuneTextTertiary)
            .padding(.top, 8)
        }
    }

    private var participantsRow: some View {
        let visible = Array(mockParticipants.prefix(participantCount))
        return HStack(spacing: 14) {
            ForEach(visible) { p in
                VStack(spacing: 5) {
                    AvatarView(participant: p, size: 40, showCrown: true)
                    Text(p.nameJa)
                        .font(.system(size: 10.5))
                        .foregroundColor(p.id == "me" ? .white : .pairtuneTextSecondary)
                        .tracking(0.2)
                }
            }
        }
    }

    private var hostControls: some View {
        Group {
            if syncState == .idle {
                Button { showSearch = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                        Text("曲を選ぶ · Pick a song")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(Color.pairtuneCoral)
                            .shadow(color: Color.pairtuneCoral.opacity(0.5), radius: 14, y: 4)
                    )
                }
            } else if syncState != .disconnected {
                HStack(spacing: 14) {
                    // Search
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundColor(.white)
                            .frame(width: 52, height: 52)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                            )
                    }

                    // Play / Pause
                    Button { togglePlayback() } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 68, height: 68)
                            .background(
                                Circle()
                                    .fill(Color.pairtuneCoral)
                                    .shadow(color: Color.pairtuneCoral.opacity(0.55), radius: 18, y: 4)
                                    .overlay(
                                        Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                                    )
                            )
                    }

                    // Music note (future: queue)
                    Button { } label: {
                        Image(systemName: "music.note")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundColor(.pairtuneTextSecondary)
                            .frame(width: 52, height: 52)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                            )
                    }
                }
            }
        }
    }

    private var guestLabel: some View {
        Text("ホストが操作中 · Host is in control")
            .font(.system(size: 11))
            .foregroundColor(.pairtuneTextQuaternary)
            .tracking(0.5)
            .padding(.top, 14)
    }

    private var disconnectBanner: some View {
        HStack(spacing: 10) {
            SpinnerView(color: .pairtuneSyncBad, size: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("接続が切れました")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text("Reconnecting… (try 2 of 3)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.pairtuneSyncBad.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.pairtuneSyncBad.opacity(0.40), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Debug overlay

    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("🛠 Debug")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.pairtuneCoral)
            Group {
                Text("role: \(isHost ? "host" : "guest")")
                Text("syncState: \(syncState.labelEn)")
                Text("songId: \(roomViewModel.activeSongId.prefix(12))…")
                Text("localTime: \(String(format: "%.2f", roomViewModel.musicService.currentTime()))s")
                Text("drift: \(String(format: "%.0f", roomViewModel.debugLastDriftMs))ms")
                Text("seq: \(roomViewModel.debugLastSeq)")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.8))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.75))
        )
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func showToast(_ msg: String) {
        withAnimation { toastMessage = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toastMessage = nil }
        }
    }

    private func togglePlayback() {
        Task { await roomViewModel.togglePlayback() }
    }
}

#Preview {
    let mockRoom = Room(
        id: "preview",
        code: "KTOMSO",
        hostId: "me",
        isActive: true,
        currentSongId: nil,
        createdAt: Date()
    )
    RoomView(
        roomViewModel: RoomViewModel(room: mockRoom, isHost: true),
        isHost: true,
        participantCount: 2,
        onExit: {},
        onSelectTrack: { _ in }
    )
}
