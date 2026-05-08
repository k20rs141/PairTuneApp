import SwiftUI

// MARK: - PairTune Logo (synchronized waveforms — V5 Deep)
// 2本の正弦波が逆相で並走、4サイクル・中振幅
// 仕様: 上=ラベンダー (#9B7BFF) / 下=ピンク (#FF6B9D) / 背景 V5 Deep
//
// 設計トークン (Claude Design `logo.jsx` / `screens-auth-home.jsx::WaveLogo` 由来):
//   viewBox 152×58, 2本のパスは Q+T×3 の anti-phase
//   upper: M 0 14 Q 18 0,  36 14 T 72 14 T 108 14 T 144 14
//   lower: M 0 42 Q 18 56, 36 42 T 72 42 T 108 42 T 144 42

struct PairTuneLogoView: View {
    /// 表示幅 (pt)。高さは width × (58/152) に自動算出。
    var size: CGFloat = 200
    /// 上波(プライマリ)。デフォルトは V5 Deep のラベンダー。
    var upperColor: Color = .pairtunePrimary
    /// 下波(セカンダリ)。デフォルトは V5 Deep のピンク。
    var lowerColor: Color = .pairtuneSecondary
    /// グロー(後光)を有効化
    var glow: Bool = false
    /// 起動アニメ: 位相ずれ → 同期 (0.7s)
    var animate: Bool = false
    /// アニメーションをやり直すためのキー (値を変えると再生される)
    var animKey: Int = 0

    @State private var animProgress: CGFloat = 1   // 0=開始(位相ずれ) / 1=完了(同期)

    /// 後方互換: 単色指定された場合は両波を同色にする旧 API。
    init(size: CGFloat = 200, color: Color, glow: Bool = false) {
        self.size = size
        self.upperColor = color
        self.lowerColor = color
        self.glow = glow
    }

    init(size: CGFloat = 200,
         upperColor: Color = .pairtunePrimary,
         lowerColor: Color = .pairtuneSecondary,
         glow: Bool = false,
         animate: Bool = false,
         animKey: Int = 0) {
        self.size = size
        self.upperColor = upperColor
        self.lowerColor = lowerColor
        self.glow = glow
        self.animate = animate
        self.animKey = animKey
    }

    var body: some View {
        let viewW: CGFloat = 152
        let viewH: CGFloat = 58
        let height = size * (viewH / viewW)
        let strokeBase = size * 0.021    // ≈ 3.2 / 152
        let strokeGlow = strokeBase * 2.5

        // アニメ進行度から各波の位相オフセットと不透明度を導出
        let inverse = 1 - animProgress
        let upperShift = -inverse * size * 0.07   // 上波: 左から右へ寄せる
        let lowerShift =  inverse * size * 0.07   // 下波: 右から左へ寄せる
        let waveOpacity = 0.3 + animProgress * 0.7

        ZStack {
            if glow {
                LogoWaveShape()
                    .stroke(upperColor.opacity(0.22 * waveOpacity),
                            style: StrokeStyle(lineWidth: strokeGlow, lineCap: .round, lineJoin: .round))
                    .blur(radius: 6)
                LogoWaveShape()
                    .stroke(lowerColor.opacity(0.22 * waveOpacity),
                            style: StrokeStyle(lineWidth: strokeGlow, lineCap: .round, lineJoin: .round))
                    .blur(radius: 6)
            }

            UpperWaveShape()
                .stroke(upperColor,
                        style: StrokeStyle(lineWidth: strokeBase, lineCap: .round, lineJoin: .round))
                .offset(x: upperShift)
                .opacity(waveOpacity)

            LowerWaveShape()
                .stroke(lowerColor,
                        style: StrokeStyle(lineWidth: strokeBase, lineCap: .round, lineJoin: .round))
                .offset(x: lowerShift)
                .opacity(waveOpacity)
        }
        .frame(width: size, height: height)
        .onAppear { triggerAnimation() }
        .onChange(of: animKey) { _, _ in triggerAnimation() }
    }

    private func triggerAnimation() {
        guard animate else { animProgress = 1; return }
        animProgress = 0
        withAnimation(.timingCurve(0.6, 0.2, 0.2, 1, duration: 0.7)) {
            animProgress = 1
        }
    }
}

// MARK: - Wave Shapes

/// 上波: 山(上向き)から開始 — anti-phase 上側
private struct UpperWaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 152
        let sy = rect.height / 58
        let ox: CGFloat = 4 * sx
        let yMid: CGFloat = 14 * sy
        let amp: CGFloat = 14 * sy
        let period: CGFloat = 36 * sx
        let half = period / 2

        var p = Path()
        p.move(to: CGPoint(x: ox, y: yMid))
        var x: CGFloat = ox
        var dir: CGFloat = -1   // 最初は上方向(山)
        for _ in 0..<4 {
            let cx = x + half / 2
            let cy = yMid + dir * amp
            let nx = x + half
            p.addQuadCurve(to: CGPoint(x: nx, y: yMid), control: CGPoint(x: cx, y: cy))
            x = nx
            dir = -dir
        }
        return p
    }
}

/// 下波: 谷(下向き)から開始 — anti-phase 下側
private struct LowerWaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 152
        let sy = rect.height / 58
        let ox: CGFloat = 4 * sx
        let yMid: CGFloat = 42 * sy
        let amp: CGFloat = 14 * sy
        let period: CGFloat = 36 * sx
        let half = period / 2

        var p = Path()
        p.move(to: CGPoint(x: ox, y: yMid))
        var x: CGFloat = ox
        var dir: CGFloat = 1    // 最初は下方向(谷) = 上波と逆相
        for _ in 0..<4 {
            let cx = x + half / 2
            let cy = yMid + dir * amp
            let nx = x + half
            p.addQuadCurve(to: CGPoint(x: nx, y: yMid), control: CGPoint(x: cx, y: cy))
            x = nx
            dir = -dir
        }
        return p
    }
}

/// グロー用に上下波を1つのパスで返す
private struct LogoWaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addPath(UpperWaveShape().path(in: rect))
        p.addPath(LowerWaveShape().path(in: rect))
        return p
    }
}

// MARK: - Wordmark

struct PairTuneWordmark: View {
    var size: CGFloat = 28
    var color: Color = .white
    var subdued: Bool = false

    var body: some View {
        Text("PairTune")
            .font(.system(size: size, weight: .medium, design: .default))
            .tracking(-size * 0.025)
            .foregroundColor(color.opacity(subdued ? 0.85 : 1))
    }
}

// MARK: - Lockup (logo + wordmark, vertical)

struct PairTuneLockup: View {
    var size: CGFloat = 36
    var color: Color = .white
    var upperColor: Color = .pairtunePrimary
    var lowerColor: Color = .pairtuneSecondary
    var glow: Bool = false

    var body: some View {
        VStack(spacing: size * 0.35) {
            PairTuneLogoView(size: size * 5.0, upperColor: upperColor, lowerColor: lowerColor, glow: glow)
            PairTuneWordmark(size: size, color: color)
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        PairTuneLogoView(size: 200, glow: true)
        PairTuneWordmark(size: 38)
        PairTuneLockup(size: 36, glow: true)
    }
    .padding(40)
    .background(Color.pairtuneBase)
}
