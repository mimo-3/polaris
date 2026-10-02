import AppKit
import SwiftUI

/// 北極星を達成したときの演出。付箋の外まで星を弾けさせたいので、付箋とは別に透明でクリックを通す窓を一瞬だけ重ねる。
@MainActor
final class CelebrationController {
    private var panel: NSPanel?
    private var closeTask: _Concurrency.Task<Void, Never>?

    /// - Parameter source: 弾ける起点にする付箋の枠（スクリーン座標）。
    func burst(from source: NSRect, reduceMotion: Bool, sound: Bool) {
        if sound { NSSound(named: "Hero")?.play() }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        // 視差効果を減らす設定では、飛び散る動きは出さず音だけにする。
        guard !reduceMotion else { return }

        let size = NSSize(width: 760, height: 640)
        // 起点は北極星のあたり（付箋の上端から少し下）。
        let emit = NSPoint(x: source.midX, y: source.maxY - 36)
        let frame = NSRect(x: emit.x - size.width / 2, y: emit.y - size.height * 0.62, width: size.width, height: size.height)
        let origin = CGPoint(x: emit.x - frame.minX, y: frame.maxY - emit.y)

        closeTask?.cancel()
        panel?.orderOut(nil)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: ConfettiBurst(origin: origin, start: Date()))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel

        closeTask = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(ConfettiBurst.duration + 0.1))
            guard !_Concurrency.Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}

/// 起点から上へ弾けて、重力で落ちながら消える紙吹雪と、最初の一瞬の光の輪。
struct ConfettiBurst: View {
    var origin: CGPoint
    var start: Date
    nonisolated static let duration: Double = 2.2

    private static let pieces: [Piece] = (0..<110).map(Piece.init)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, _ in
                let t = timeline.date.timeIntervalSince(start)
                drawFlash(&context, t: t)
                for piece in Self.pieces { piece.draw(&context, origin: origin, t: t) }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawFlash(_ context: inout GraphicsContext, t: Double) {
        let p = t / 0.55
        guard p < 1 else { return }
        let radius = 20 + 220 * (1 - pow(1 - p, 3))
        let rect = CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(Piece.gold.opacity(0.7 * (1 - p))), lineWidth: 6 * (1 - p) + 1)
        let glow = CGRect(x: origin.x - 60, y: origin.y - 60, width: 120, height: 120)
        context.fill(Path(ellipseIn: glow), with: .radialGradient(
            Gradient(colors: [Piece.gold.opacity(0.55 * (1 - p)), .clear]),
            center: origin, startRadius: 0, endRadius: 60))
    }

    struct Piece {
        enum Shape { case star, dot, ribbon }
        static let gold = Color(red: 0.94, green: 0.76, blue: 0.31)
        private static let palette: [Color] = [
            gold, Color(red: 0.64, green: 0.44, blue: 0.05), Color(red: 0.91, green: 0.42, blue: 0.57),
            Color(red: 0.42, green: 0.66, blue: 0.91), Color(red: 0.61, green: 0.73, blue: 0.53), Color(red: 0.86, green: 0.61, blue: 0.49),
        ]

        let shape: Shape
        let color: Color
        let vx: Double, vy: Double
        let spin: Double, size: Double, delay: Double

        init(_ index: Int) {
            // 毎回同じ並びでよいので、添字から決まる擬似乱数を使う。
            var seed = UInt64(index &* 2_654_435_761 &+ 97)
            func next() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(seed >> 11) / Double(1 << 53)
            }
            let angle = (-90 + (next() - 0.5) * 150) * .pi / 180
            let speed = 420 + next() * 620
            vx = cos(angle) * speed
            vy = sin(angle) * speed
            spin = (next() - 0.5) * 14
            size = 5 + next() * 7
            delay = next() * 0.12
            color = Self.palette[Int(next() * Double(Self.palette.count)) % Self.palette.count]
            let r = next()
            shape = r < 0.3 ? .star : (r < 0.6 ? .dot : .ribbon)
        }

        func draw(_ context: inout GraphicsContext, origin: CGPoint, t raw: Double) {
            let t = raw - delay
            guard t > 0, t < ConfettiBurst.duration - delay else { return }
            // 空気抵抗で横はすぐ緩み、縦は重力で落ちる。
            let drag = 1.6
            let x = origin.x + vx * (1 - exp(-drag * t)) / drag
            let y = origin.y + vy * (1 - exp(-drag * t)) / drag + 0.5 * 1100 * t * t * 0.55
            let life = t / (ConfettiBurst.duration - delay)
            let alpha = life < 0.65 ? 1 : max(0, 1 - (life - 0.65) / 0.35)
            var ctx = context
            ctx.opacity = alpha
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: .radians(spin * t))
            switch shape {
            case .dot:
                ctx.fill(Path(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)), with: .color(color))
            case .ribbon:
                // 紙がひらひら裏返るように、幅を周期的に潰す。
                let w = size * 1.6 * abs(cos(t * 9 + spin))
                ctx.fill(Path(roundedRect: CGRect(x: -w / 2, y: -size * 0.3, width: max(w, 1), height: size * 0.6), cornerRadius: 1),
                         with: .color(color))
            case .star:
                ctx.fill(Self.starPath(radius: size * 0.9), with: .color(color))
            }
        }

        private static func starPath(radius: Double) -> Path {
            var path = Path()
            for i in 0..<8 {
                let r = i.isMultiple(of: 2) ? radius : radius * 0.38
                let a = Double(i) * .pi / 4 - .pi / 2
                let p = CGPoint(x: cos(a) * r, y: sin(a) * r)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.closeSubpath()
            return path
        }
    }
}
