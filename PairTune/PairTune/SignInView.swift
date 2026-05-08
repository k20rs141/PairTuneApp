import SwiftUI

struct SignInView: View {
    /// 進行中フラグ(AuthViewModel.isLoading から流す)。失敗時は呼び出し側で false に戻る。
    var isProcessing: Bool = false
    var onSignIn: () -> Void
    @State private var logoAnimKey: Int = 0

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            // Atmospheric glow
            RadialGradient(
                colors: [Color.pairtuneCoral.opacity(0.22), .clear],
                center: UnitPoint(x: 0.5, y: -0.1),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                // Logo + wordmark + tagline
                VStack(spacing: 0) {
                    PairTuneLogoView(size: 200, glow: true, animate: true, animKey: logoAnimKey)
                        .opacity(isProcessing ? 0.6 : 1)
                        .animation(.easeInOut(duration: 0.3), value: isProcessing)
                        .onTapGesture { logoAnimKey += 1 }

                    PairTuneWordmark(size: 38)
                        .padding(.top, 20)

                    VStack(spacing: 6) {
                        Text("離れていても、同じ音を。")
                            .font(.system(size: 14))
                            .foregroundColor(.pairtuneTextSecondary)
                            .multilineTextAlignment(.center)
                            .tracking(0.4)

                        Text("The same song, together — without a call.")
                            .font(.system(size: 11.5))
                            .foregroundColor(.pairtuneTextTertiary)
                            .tracking(0.6)
                    }
                    .padding(.top, 14)
                    .lineSpacing(4)
                }

                Spacer()

                // Bottom section
                VStack(spacing: 18) {
                    Button {
                        guard !isProcessing else { return }
                        onSignIn()
                    } label: {
                        HStack(spacing: 8) {
                            if isProcessing {
                                SpinnerView(color: .black, size: 17)
                            } else {
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 17, weight: .medium))
                                Text("Sign in with Apple")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.white)
                        .cornerRadius(14)
                        .shadow(color: Color.white.opacity(0.08), radius: 16, y: 4)
                        .opacity(isProcessing ? 0.6 : 1)
                    }
                    .disabled(isProcessing)
                    .animation(.easeInOut(duration: 0.2), value: isProcessing)

                    HStack(spacing: 4) {
                        Text("続行することで")
                        Text("利用規約")
                            .foregroundColor(.pairtuneTextSecondary)
                            .underline()
                        Text("と")
                        Text("プライバシー")
                            .foregroundColor(.pairtuneTextSecondary)
                            .underline()
                        Text("に同意")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.pairtuneTextTertiary)
                    .tracking(0.4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 56)
            }
        }
    }
}

#Preview {
    SignInView(onSignIn: {})
}
