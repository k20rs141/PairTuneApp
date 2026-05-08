import SwiftUI

struct HomeView: View {
    var onCreate: () -> Void
    var onJoin: () -> Void
    var onProfile: () -> Void

    @State private var creating = false

    var body: some View {
        ZStack {
            Color.pairtuneBase.ignoresSafeArea()

            // Ambient glows
            GeometryReader { geo in
                ZStack {
                    RadialGradient(
                        colors: [Color.pairtuneCoral.opacity(0.15), .clear],
                        center: UnitPoint(x: 1.3, y: 0.12),
                        startRadius: 0,
                        endRadius: 360
                    )
                    .blur(radius: 10)

                    RadialGradient(
                        colors: [Color.pairtuneCream.opacity(0.06), .clear],
                        center: UnitPoint(x: -0.3, y: 0.86),
                        startRadius: 0,
                        endRadius: 300
                    )
                    .blur(radius: 10)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    PairTuneWordmark(size: 20)
                    Spacer()
                    Button(action: onProfile) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.pairtuneTextSecondary)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                            )
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)

                Spacer()

                // Hero
                VStack(spacing: 0) {
                    PairTuneLogoView(size: 220, glow: true)

                    Text("離れていても、\n同じ音を。")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .tracking(0.2)
                        .padding(.top, 28)

                    Text("Tune in, side by side — without a call.")
                        .font(.system(size: 12.5))
                        .foregroundColor(.pairtuneTextTertiary)
                        .tracking(0.6)
                        .padding(.top, 12)
                }
                .padding(.bottom, 20)

                Spacer()

                // CTAs
                VStack(spacing: 12) {
                    Button {
                        guard !creating else { return }
                        creating = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
                            creating = false
                            onCreate()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if creating {
                                SpinnerView(color: .white, size: 18)
                            } else {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .medium))
                                Text("ルームを開く")
                                    .font(.system(size: 17, weight: .semibold))
                                    .tracking(0.2)
                                Text("· Open a room")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.pairtuneCoral)
                                .shadow(color: Color.pairtuneCoral.opacity(0.40), radius: 20, y: 6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                )
                        )
                    }
                    .disabled(creating)
                    .animation(.easeInOut(duration: 0.2), value: creating)

                    Button(action: onJoin) {
                        HStack(spacing: 10) {
                            Image(systemName: "door.left.hand.open")
                                .font(.system(size: 18, weight: .regular))
                            Text("コードで参加")
                                .font(.system(size: 17, weight: .medium))
                                .tracking(0.2)
                            Text("· Join with code")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                                )
                        )
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 44)
            }
        }
    }
}

#Preview {
    HomeView(onCreate: {}, onJoin: {}, onProfile: {})
}
