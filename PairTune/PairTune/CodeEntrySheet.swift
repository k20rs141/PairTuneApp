import SwiftUI

// MARK: - CodeEntrySheet (v0.4 ペアリング申請)
//
// v0.2 では「他人のマイルームに参加する」ためのコード入力だったが、
// v0.4 では「パートナーのコードを入力 → ペアリング申請を送る」フローに変わった。
// 仕様: docs/PairTune_Specification_v0.4.md §5.3 / §6
// 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §6
//
// レイアウト(ピン入力/ペーストヒント等)は Claude Design 由来のため変更しない。
// 変更はコピー文言と submit ハンドラのセマンティクスのみ。

struct CodeEntrySheet: View {
    @Binding var isPresented: Bool

    /// コード入力完了時の送信ハンドラ。
    /// nil の場合はモック動作(Preview / デザイン確認用)。
    /// 戻り値: エラーメッセージ(成功時 nil)
    var submitCode: ((String) async -> String?)? = nil

    /// 申請が DB に INSERT 成功した直後に呼ばれる(sheet 閉じた後)
    var onRequested: () -> Void = {}

    @State private var code: String = ""
    @State private var errorMessage: String? = nil
    @State private var isSubmitting: Bool = false
    @FocusState private var isInputFocused: Bool

    private let allowed = CharacterSet(charactersIn: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    var body: some View {
        ZStack {
            Color.pairtuneSurfaceSheet.ignoresSafeArea()

            VStack(spacing: 0) {
                // Handle bar
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 36, height: 5)
                    .padding(.top, 12)
                    .padding(.bottom, 22)

                // Title
                Text("パートナーのコードを入力")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .tracking(0.3)

                Text("Enter your partner's 6-letter code")
                    .font(.system(size: 12.5))
                    .foregroundColor(.pairtuneTextTertiary)
                    .tracking(0.4)
                    .padding(.top, 6)

                // Pin boxes + hidden field
                ZStack {
                    TextField("", text: $code)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($isInputFocused)
                        .opacity(0.001)
                        .frame(width: 1, height: 1)
                        .onChange(of: code) { _, newVal in
                            let filtered = String(
                                newVal
                                    .uppercased()
                                    .unicodeScalars
                                    .filter { allowed.contains($0) }
                                    .map(Character.init)
                                    .prefix(6)
                            )
                            if filtered != newVal { code = filtered }
                            errorMessage = nil
                            if filtered.count == 6 && !isSubmitting {
                                submit(filtered)
                            }
                        }

                    HStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { i in
                            let char: String = code.count > i
                                ? String(code[code.index(code.startIndex, offsetBy: i)])
                                : ""
                            let filled = code.count > i
                            let hasError = errorMessage != nil

                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(hex: "0F0F0F"))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            hasError ? Color.pairtuneSyncBad :
                                                filled ? Color.pairtuneCoral :
                                                Color.white.opacity(0.12),
                                            lineWidth: 1.5
                                        )
                                )
                                .overlay(
                                    Text(char)
                                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                )
                                .frame(width: 44, height: 56)
                                .animation(.easeInOut(duration: 0.15), value: filled)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { isInputFocused = true }
                }
                .padding(.top, 36)

                // Error / hint line
                Group {
                    if isSubmitting {
                        HStack(spacing: 6) {
                            SpinnerView(color: .pairtuneTextTertiary, size: 12)
                            Text("申請を送信中…")
                        }
                    } else if let err = errorMessage {
                        Text(err)
                            .foregroundColor(.pairtuneSyncBad)
                    } else {
                        Text("大文字小文字は問いません · O / I は使われません")
                            .foregroundColor(.pairtuneTextTertiary)
                    }
                }
                .font(.system(size: 12))
                .tracking(0.3)
                .multilineTextAlignment(.center)
                .frame(height: 20)
                .padding(.top, 14)

                // Paste hint (Preview/デザイン確認用、実機ではクリップボード貼り付け)
                Button {
                    code = mockCode
                    submit(mockCode)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12))
                        Text("クリップボードから貼り付け · \(mockCode)")
                            .font(.system(size: 12.5))
                            .tracking(0.3)
                    }
                    .foregroundColor(.pairtuneTextSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                    )
                }
                .padding(.top, 18)

                Spacer()

                Text("申請が届くと相手の画面で承認モーダルが開きます")
                    .font(.system(size: 11))
                    .foregroundColor(.pairtuneTextQuaternary)
                    .tracking(0.4)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 22)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .onAppear {
            code = ""
            errorMessage = nil
            isSubmitting = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                isInputFocused = true
            }
        }
    }

    private func submit(_ full: String) {
        isSubmitting = true
        if let asyncSubmit = submitCode {
            Task {
                let errMsg = await asyncSubmit(full)
                isSubmitting = false
                if errMsg == nil {
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onRequested() }
                } else {
                    errorMessage = errMsg
                }
            }
        } else {
            // モック動作 (Preview 用)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                isSubmitting = false
                if full == mockCode {
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onRequested() }
                } else {
                    errorMessage = "コードが正しくありません"
                }
            }
        }
    }
}
