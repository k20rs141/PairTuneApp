import SwiftUI

// MARK: - HoldButton
//
// 「タップで onTap、長押しで onHoldTick が一定間隔で発火する」ボタン。
// Prev / Next の早送り・巻き戻し用。
//
// 設計:
// - DragGesture(minimumDistance: 0) を「タッチ追跡用」に使う(指が触れた瞬間に onChanged が来る)
// - 触れてから `holdDelay`(0.35s)経過すると "hold" 判定して onHoldTick を初回発火 +
//   `tickInterval`(0.18s)間隔の Timer を起動
// - 指が離れた(onEnded)時点で hold モードでなければ onTap、hold モードなら Timer 停止
// - SwiftUI の Button + simultaneousGesture は「タップと長押しが両方発火する」問題が起きやすいので
//   Button を使わず Image + gesture で組み立てる

struct HoldButton<Label: View>: View {
    let onTap: () -> Void
    let onHoldTick: () -> Void
    var holdDelay: TimeInterval = 0.35
    var tickInterval: TimeInterval = 0.18
    @ViewBuilder var label: () -> Label

    @State private var pressStartAt: Date?
    @State private var holdStartTimer: Timer?
    @State private var holdRepeatTimer: Timer?
    @State private var isHolding: Bool = false

    var body: some View {
        label()
            .contentShape(Rectangle())
            .scaleEffect(isHolding ? 0.94 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHolding)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in handlePressBegin() }
                    .onEnded { _ in handlePressEnd() }
            )
    }

    private func handlePressBegin() {
        guard pressStartAt == nil else { return }
        pressStartAt = Date()
        // holdDelay 経過後に hold 判定に入る
        holdStartTimer?.invalidate()
        holdStartTimer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { _ in
            Task { @MainActor in self.beginHold() }
        }
    }

    @MainActor
    private func beginHold() {
        guard pressStartAt != nil, !isHolding else { return }
        isHolding = true
        onHoldTick()
        holdRepeatTimer?.invalidate()
        holdRepeatTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            Task { @MainActor in onHoldTick() }
        }
    }

    private func handlePressEnd() {
        let started = pressStartAt
        pressStartAt = nil
        holdStartTimer?.invalidate(); holdStartTimer = nil
        holdRepeatTimer?.invalidate(); holdRepeatTimer = nil

        if isHolding {
            isHolding = false
        } else if started != nil {
            onTap()
        }
    }
}
