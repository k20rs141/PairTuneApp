import SwiftUI
import Supabase
import PhotosUI
import UIKit

// MARK: - ProfileView (v0.4 プロフィール / 設定画面)
//
// デザイン: Claude Design v2 `screens-profile.jsx`
// 仕様: PairTune §7-5 / §8-6 / §8-7
//
// セクション:
//   - Identity card: アバター + 表示名(編集可) + handle(pairingCode)
//   - Pair card / NoPair card: パートナー情報 + 解消ボタン
//   - Privacy: 履歴・お気に入りの共有 toggle
//   - Notifications: 記念日 / 1年前の今日 / オンライン通知
//   - Memories & data: 解消後の思い出保持 + 履歴削除
//   - Account: Apple ID / マイルームコード / サインアウト
//   - Footer

struct ProfileView: View {
    let authViewModel: AuthViewModel
    let pairViewModel: PairViewModel
    let sharingPairingCode: String?

    // Identity
    @State private var displayName: String = ""
    @State private var editingName: Bool = false
    @State private var avatarUrl: String? = nil
    @State private var avatarPickerItem: PhotosPickerItem? = nil
    @State private var avatarUploading: Bool = false

    // Privacy (load from profile)
    @State private var sharePlayHistory: Bool = false
    @State private var shareFavorites: Bool = true

    // Notifications
    @State private var notifyMilestones: Bool = true
    @State private var notifyPartnerOnline: Bool = false
    @AppStorage("pt.notifyYearAgo") private var notifyYearAgo: Bool = true

    // Memories preference (UI-only / UserDefaults)
    @AppStorage("pt.preferPreserveMemories") private var preferPreserveMemories: Bool = true

    // Confirmations
    @State private var safariURL: URL?
    @State private var showDeleteConfirm1 = false
    @State private var showDeleteConfirm2 = false
    @State private var isDeleting = false
    @State private var showUnpairDialog = false
    @State private var isEndingPair = false
    @State private var toastMessage: String?

    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            // Ambient glow — clipped to screen bounds so the 480pt circle doesn't expand the parent
            Color.clear
                .overlay(alignment: .top) {
                    Circle()
                        .fill(Color.pairtunePrimary.opacity(0.12))
                        .frame(width: 480, height: 480)
                        .blur(radius: 60)
                        .offset(y: -240)
                }
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 22) {
                    identityCard
                    pairCard
                    privacyGroup
                    notificationsGroup
                    memoriesGroup
                    accountGroup
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 60)
            }

            // Toast overlay (コードコピー時の確認用)
            if let msg = toastMessage {
                VStack {
                    Spacer()
                    ToastView(message: msg)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .padding(.bottom, 90)
                }
                .animation(.easeOut(duration: 0.25), value: toastMessage != nil)
                .allowsHitTesting(false)
                .zIndex(110)
            }

            if showUnpairDialog {
                UnpairDialog(
                    partnerName: pairViewModel.partnerProfile?.displayName,
                    onCommit: { choice in
                        await runEndPair(choice: choice)
                    },
                    onDismiss: {
                        showUnpairDialog = false
                    }
                )
                .transition(.opacity)
                .zIndex(120)
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if let profile = authViewModel.currentProfile {
                displayName = profile.displayName
                avatarUrl = profile.avatarUrl
                sharePlayHistory = profile.sharePlayHistory
                shareFavorites = profile.shareFavorites
                notifyMilestones = profile.notifyMilestones
                notifyPartnerOnline = profile.notifyPartnerOnline
            }
        }
        .onChange(of: avatarPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await uploadAvatar(from: newItem) }
        }
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
                    _ = await authViewModel.deleteAccount()
                    isDeleting = false
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除すると元に戻せません。")
        }
    }

    // MARK: - Identity card

    private var identityCard: some View {
        HStack(spacing: 14) {
            // Avatar with photo picker
            PhotosPicker(selection: $avatarPickerItem, matching: .images, photoLibrary: .shared()) {
                ZStack(alignment: .bottomTrailing) {
                    avatarImage
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1.5))
                        .shadow(color: Color.pairtunePrimary.opacity(0.27), radius: 12, y: 6)

                    ZStack {
                        Circle()
                            .fill(Color.pairtuneSurface)
                            .overlay(Circle().stroke(Color.pairtunePrimary.opacity(0.40), lineWidth: 0.5))
                            .frame(width: 24, height: 24)
                        if avatarUploading {
                            SpinnerView(color: .pairtunePrimary, size: 10)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.pairtunePrimary)
                        }
                    }
                    .offset(x: 2, y: 2)
                }
            }
            .disabled(avatarUploading)
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                if editingName {
                    TextField("表示名", text: $displayName)
                        .focused($nameFocused)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .submitLabel(.done)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.pairtunePrimary.opacity(0.40), lineWidth: 0.5)
                                )
                        )
                        .onSubmit { commitName() }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { commitName() }
                        }
                } else {
                    Button(action: { editingName = true; nameFocused = true }) {
                        HStack(spacing: 6) {
                            Text(displayName.isEmpty ? "未設定" : displayName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .tracking(0.2)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(hex: "7A7588"))
                        }
                    }
                    .buttonStyle(.plain)
                }

                if let code = sharingPairingCode {
                    Text("@\(code.lowercased())")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Color(hex: "7A7588"))
                        .tracking(0.3)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.pairtunePrimary.opacity(0.08), Color.pairtuneSecondary.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.pairtunePrimary.opacity(0.27), lineWidth: 0.5)
                )
        )
    }

    private func commitName() {
        editingName = false
        Task { await authViewModel.updateDisplayName(displayName) }
    }

    /// マイルームコードをクリップボードへコピーし、haptic + トーストで確認表示する。
    private func copyMyRoomCode() {
        guard let code = sharingPairingCode, !code.isEmpty else { return }
        UIPasteboard.general.string = code
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation { toastMessage = "コードをコピーしました" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { toastMessage = nil }
        }
    }

    private func initialsOf(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "YO" }
        let prefix = String(trimmed.prefix(2)).uppercased()
        return prefix
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let urlStr = avatarUrl, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    initialsAvatar
                }
            }
        } else {
            initialsAvatar
        }
    }

    private var initialsAvatar: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.pairtunePrimary, Color.pairtunePrimary.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Text(initialsOf(displayName))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(Color(red: 0x0A/255, green: 0x06/255, blue: 0x12/255))
            )
    }

    private func uploadAvatar(from item: PhotosPickerItem) async {
        avatarUploading = true
        defer { avatarUploading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            // ダウンサイズして JPEG エンコード(512x512、品質 0.85)
            guard let jpegData = downscaleToJPEG(data, maxDimension: 512, quality: 0.85) else { return }
            if await authViewModel.updateAvatarImage(jpegData: jpegData) {
                avatarUrl = authViewModel.currentProfile?.avatarUrl
            }
        } catch {
            print("[ProfileView] uploadAvatar error:", error)
        }
    }

    /// 元画像を maxDimension の正方形以内に縮小し JPEG にエンコード。
    /// アップロード帯域・Storage 容量を抑えるため。
    private func downscaleToJPEG(_ data: Data, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        guard let uiImage = UIImage(data: data) else { return nil }
        let original = uiImage.size
        let longest = max(original.width, original.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let newSize = CGSize(width: original.width * scale, height: original.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    // MARK: - Pair card

    @ViewBuilder
    private var pairCard: some View {
        if let partnerProfile = pairViewModel.partnerProfile,
           let pair = pairViewModel.activePair {
            pairedCard(partner: partnerProfile, pair: pair)
        } else {
            noPairCard
        }
    }

    private func pairedCard(partner: ProfileV4, pair: PairRelationship) -> some View {
        let days = max(1, Calendar.current.dateComponents([.day], from: pair.pairedAt, to: Date()).day ?? 1)
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.pairtuneSecondary, Color.pairtuneSecondary.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                    .overlay(
                        Text(String(partner.displayName.prefix(2)).uppercased())
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color(red: 0x0A/255, green: 0x06/255, blue: 0x12/255))
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1.5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(partner.displayName) さん")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .tracking(0.2)
                        Circle()
                            .fill(Color.pairtuneSyncOk)
                            .frame(width: 6, height: 6)
                            .shadow(color: Color.pairtuneSyncOk.opacity(0.7), radius: 4)
                    }
                    Text("ペアリング \(days) 日")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "7A7588"))
                        .tracking(0.2)
                }

                Spacer()

                Text("PAIRED")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.pairtunePrimary)
                    .tracking(0.6)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.pairtunePrimary.opacity(0.11))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                            )
                    )
            }

            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)

            Button(role: .destructive, action: { showUnpairDialog = true }) {
                HStack(spacing: 8) {
                    if isEndingPair { SpinnerView(color: .pairtuneSyncBad, size: 14) }
                    Text("ペアリングを解消…")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.pairtuneSyncBad)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.pairtuneSyncBad.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.pairtuneSyncBad.opacity(0.20), lineWidth: 0.5)
                        )
                )
            }
            .disabled(isEndingPair)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                )
        )
    }

    private var noPairCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.pairtunePrimary.opacity(0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.pairtunePrimary.opacity(0.30), lineWidth: 0.5)
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: "person.2")
                    .font(.system(size: 15))
                    .foregroundColor(.pairtunePrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("まだペアリングしていません")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text("コードを共有して、相手とペアになりましょう。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "7A7588"))
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.pairtunePrimary.opacity(0.27), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                )
        )
    }

    // MARK: - Privacy group

    private var privacyGroup: some View {
        SettingsGroup(label: "プライバシー", sub: "Privacy", icon: "lock", accent: .pairtunePrimary) {
            SettingsToggleRow(
                title: "お気に入りをパートナーに見せる",
                description: "あなたが ♥ をつけた曲だけが、パートナーの Solo モードに表示されます。",
                isOn: $shareFavorites,
                accent: .pairtunePrimary
            )
            .onChange(of: shareFavorites) { _, newValue in
                Task {
                    await authViewModel.updatePrivacySettings(
                        sharePlayHistory: sharePlayHistory,
                        shareFavorites: newValue
                    )
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                title: "再生履歴をパートナーに見せる",
                description: "あなたがマイルームで聴いた曲が、パートナーの Solo モードに表示されます。",
                isOn: $sharePlayHistory,
                accent: .pairtunePrimary
            )
            .onChange(of: sharePlayHistory) { _, newValue in
                Task {
                    await authViewModel.updatePrivacySettings(
                        sharePlayHistory: newValue,
                        shareFavorites: shareFavorites
                    )
                }
            }
        }
    }

    // MARK: - Notifications group

    private var notificationsGroup: some View {
        SettingsGroup(label: "通知", sub: "Notifications", icon: "bell", accent: .pairtuneSecondary) {
            SettingsToggleRow(
                title: "記念日のお知らせ",
                description: "1 ヶ月、100 日、1 周年など節目だけお知らせ。",
                isOn: $notifyMilestones,
                accent: .pairtunePrimary
            )
            .onChange(of: notifyMilestones) { _, newValue in
                Task {
                    await authViewModel.updateNotificationSettings(
                        notifyPartnerOnline: notifyPartnerOnline,
                        notifyMilestones: newValue
                    )
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                title: "1 年前の今日",
                description: "去年同じ日に聴いた曲を、控えめに思い出させます。",
                isOn: $notifyYearAgo,
                accent: .pairtunePrimary
            )
            SettingsDivider()
            SettingsToggleRow(
                title: "相手がオンラインになった時",
                description: "",
                isOn: $notifyPartnerOnline,
                accent: .pairtunePrimary
            )
            .onChange(of: notifyPartnerOnline) { _, newValue in
                Task {
                    await authViewModel.updateNotificationSettings(
                        notifyPartnerOnline: newValue,
                        notifyMilestones: notifyMilestones
                    )
                }
            }
        }
    }

    // MARK: - Memories group

    private var memoriesGroup: some View {
        // 解消済み pair があれば、その preserve_memories を直接 binding に反映する。
        // ない場合は UnpairDialog の初期値として使う AppStorage のローカル prefer に向ける。
        let hasEndedPair = pairViewModel.endedPairs.first != nil
        let toggleBinding = Binding<Bool>(
            get: {
                pairViewModel.endedPairs.first?.preserveMemories ?? preferPreserveMemories
            },
            set: { newValue in
                preferPreserveMemories = newValue
                if hasEndedPair {
                    Task {
                        _ = await pairViewModel.updateLatestEndedPairPreserveMemories(newValue)
                    }
                }
            }
        )
        return SettingsGroup(label: "思い出と履歴", sub: "Memories & data", icon: "music.note", accent: Color(hex: "7A7588")) {
            SettingsToggleRow(
                title: "解消後も思い出を残す",
                description: hasEndedPair
                    ? "オフにすると 90 日後に過去の履歴が削除されます。"
                    : "ペアリングが終わっても、ふたりで聴いた曲を Solo に閲覧専用で残します。",
                isOn: toggleBinding,
                accent: .pairtunePrimary
            )
        }
    }

    // MARK: - Account group

    private var accountGroup: some View {
        SettingsGroup(label: "アカウント", sub: "Account", icon: "person.crop.circle", accent: Color(hex: "A8A8A8")) {
            SettingsRow(
                label: "Apple ID",
                value: authViewModel.session?.user.email ?? "—"
            )
            SettingsDivider()
            SettingsRow(
                label: "マイルームコード",
                value: sharingPairingCode ?? "------",
                valueIsMono: true,
                valueColor: .pairtunePrimary,
                onCopy: (sharingPairingCode?.isEmpty == false) ? { copyMyRoomCode() } : nil
            )
            SettingsDivider()
            SettingsLinkRow(label: "サインアウト", style: .subtle) {
                Task { await authViewModel.signOut() }
            }
            SettingsDivider()
            SettingsLinkRow(label: "利用規約", style: .subtle) {
                safariURL = AppLinks.termsOfService
            }
            SettingsDivider()
            SettingsLinkRow(label: "プライバシーポリシー", style: .subtle) {
                safariURL = AppLinks.privacyPolicy
            }
            SettingsDivider()
            SettingsLinkRow(label: "アカウントを削除", style: .danger) {
                showDeleteConfirm1 = true
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Text("PairTune v0.4 · 離れていても、同じ音を。")
            .font(.system(size: 10))
            .foregroundColor(Color(hex: "3F3F4A"))
            .tracking(0.6)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
    }

    // MARK: - Helpers

    /// UnpairDialog の「思い出はどうしますか?」で選択された choice をもとに
    /// PairViewModel.endActivePair を呼ぶ。成功なら true を返し、UnpairDialog 側で
    /// Done step に遷移する。
    private func runEndPair(choice: UnpairChoice) async -> Bool {
        isEndingPair = true
        let ok = await pairViewModel.endActivePair(preserveMemories: choice.preserveMemories)
        isEndingPair = false
        return ok
    }
}

// MARK: - Identifiable URL wrapper

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Settings UI primitives

private struct SettingsGroup<Content: View>: View {
    let label: String
    let sub: String
    let icon: String
    let accent: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(accent.opacity(0.11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(accent.opacity(0.30), lineWidth: 0.5)
                        )
                        .frame(width: 18, height: 18)
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(accent)
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "A8A8A8"))
                    .tracking(0.4)
                    .textCase(.uppercase)
                Text("· \(sub)")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "3F3F4A"))
                    .tracking(0.3)
                Spacer()
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.04))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool
    let accent: Color

    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .tracking(0.2)
                        .multilineTextAlignment(.leading)
                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(hex: "7A7588"))
                            .multilineTextAlignment(.leading)
                            .lineSpacing(2)
                    }
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRow: View {
    let label: String
    let value: String
    var valueIsMono: Bool = false
    var valueColor: Color = Color(hex: "7A7588")
    /// 設定値の右側に doc.on.doc コピーボタンを表示する場合のハンドラ。
    /// nil の時はボタン非表示。
    var onCopy: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .tracking(0.2)
            Spacer()
            Text(value)
                .font(.system(size: valueIsMono ? 12.5 : 12, design: valueIsMono ? .monospaced : .default))
                .foregroundColor(valueColor)
                .tracking(valueIsMono ? 2 : 0.2)
            if let onCopy {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.pairtuneTextSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private struct SettingsLinkRow: View {
    enum Style { case normal, subtle, danger }

    let label: String
    var style: Style = .normal
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)
                    .tracking(0.2)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "5A5566"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var textColor: Color {
        switch style {
        case .normal: return .white
        case .subtle: return Color(hex: "A8A8A8")
        case .danger: return .pairtuneSyncBad
        }
    }
}
