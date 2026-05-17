import SwiftUI

// MARK: - RavenChatWallpaper
//
// RAVEN's chat wallpaper. The pattern is a DENSE tile of tiny, single-
// stroke line-art icons — the same visual grammar as WhatsApp's classic
// doodle wallpaper and Telegram's "Saved Messages" pattern. Icons are
// small (~18 pt), one-colour, low-contrast, and arranged on a tight
// grid so they read as a texture rather than illustrations.
//
// Visual goals:
//   • The user must barely notice the icons unless they look for them.
//     Message bubbles always come first. Stroke opacity caps at 14% on
//     light and 10% on dark.
//   • The vocabulary is brand-aligned — ravens, feathers, stars, moons,
//     planets, comets, antennae, signals, locks, mountains, music
//     notes, coffee cups, leaves… ~30 distinct icons so the pattern
//     never repeats visibly.
//   • Static. No motion. WhatsApp and Telegram don't animate their
//     doodle patterns, and now we don't either — it's distracting in
//     a chat thread.
//
// Performance:
//   • One single `Canvas` draws every icon in one go via `ctx.stroke`.
//     No SwiftUI view hierarchy under the wallpaper — zero invalidation
//     during scroll.
//
struct RavenChatWallpaper: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                BaseLayer(colorScheme: colorScheme)
                DoodleTile(size: geo.size, colorScheme: colorScheme)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Base solid colour

private struct BaseLayer: View {
    let colorScheme: ColorScheme
    var body: some View {
        colorScheme == .dark
            ? Color(red: 0.04, green: 0.04, blue: 0.06)  // near-black with a touch of indigo
            : Color(red: 0.96, green: 0.96, blue: 0.99)  // off-white with a touch of violet
    }
}

// MARK: - Doodle tile (the WhatsApp-style pattern)

private struct DoodleTile: View {
    let size: CGSize
    let colorScheme: ColorScheme

    /// Spacing between icon centres. ~46 pt feels right at iPhone scale
    /// — close enough to read as a dense texture, far enough that no
    /// two icons overlap.
    private let cellSize: CGFloat = 46

    /// Icon target diameter. Slightly smaller than the cell so adjacent
    /// icons have clear breathing room.
    private let iconSize: CGFloat = 30

    var body: some View {
        Canvas(opaque: false) { ctx, sz in
            let cols = Int((sz.width / cellSize).rounded(.up)) + 1
            let rows = Int((sz.height / cellSize).rounded(.up)) + 1
            let strokeColor = colorScheme == .dark
                ? Color.white.opacity(0.10)
                : Color(red: 0.30, green: 0.20, blue: 0.45).opacity(0.14)

            for row in 0..<rows {
                for col in 0..<cols {
                    // Stagger every other row so icons sit on a hex
                    // lattice rather than a square grid — feels more
                    // organic, less "wallpaper from 1995".
                    let xOffset: CGFloat = (row.isMultiple(of: 2)) ? 0 : cellSize / 2
                    let cx = CGFloat(col) * cellSize + xOffset
                    let cy = CGFloat(row) * cellSize

                    // Deterministic seed for this cell, drives both
                    // the icon choice and a tiny rotational wobble so
                    // the pattern doesn't look stamped.
                    let seed = Double(row * 73 + col * 31 + (row + col))
                    let iconIndex = Int(fract(sin(seed * 12.9898) * 43758.5453) * Double(IconKind.allCases.count)) % IconKind.allCases.count
                    let kind = IconKind.allCases[iconIndex]
                    let rotation = (fract(sin(seed * 5.13) * 99.0) - 0.5) * 0.35  // ±0.17 rad ≈ ±10°
                    let jitterX = (fract(sin(seed * 17.7) * 9999.0) - 0.5) * Double(cellSize) * 0.10
                    let jitterY = (fract(sin(seed * 41.3) * 9999.0) - 0.5) * Double(cellSize) * 0.10

                    let originX = cx + CGFloat(jitterX) - iconSize / 2
                    let originY = cy + CGFloat(jitterY) - iconSize / 2
                    let iconRect = CGRect(x: originX, y: originY, width: iconSize, height: iconSize)

                    // Build the icon's path in local coordinates and
                    // stroke it. Rotation is applied around the icon's
                    // own centre via a transform.
                    var path = kind.path(in: CGRect(origin: .zero, size: CGSize(width: iconSize, height: iconSize)))
                    let centre = CGPoint(x: iconRect.midX, y: iconRect.midY)
                    var transform = CGAffineTransform.identity
                    transform = transform.translatedBy(x: centre.x, y: centre.y)
                    transform = transform.rotated(by: CGFloat(rotation))
                    transform = transform.translatedBy(x: -iconSize / 2, y: -iconSize / 2)
                    path = path.applying(transform)

                    ctx.stroke(path,
                               with: .color(strokeColor),
                               style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .drawingGroup() // rasterise the doodle layer once; massive scroll win
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

// =========================================================================
// MARK: - Icon library
//
// Every icon is a single closed (or open) path drawn inside a 0–1 normalised
// rect. The renderer scales them into the target cell. Keep each one to
// 1–4 strokes max — they must be readable at 30 pt with a 1 pt stroke.
// =========================================================================

private enum IconKind: CaseIterable {
    case ravenFlying
    case ravenPerched
    case feather
    case star4
    case star5
    case sparkle
    case crescentMoon
    case fullMoon
    case planet
    case saturn
    case ufo
    case comet
    case shootingStar
    case satellite
    case antenna
    case wifi
    case lockClosed
    case key
    case envelope
    case speechBubble
    case microphone
    case headphones
    case musicNote
    case heart
    case diamond
    case lightning
    case coffeeCup
    case mountain
    case leaf
    case compass

    /// Returns the icon's path inside the given rectangle. All
    /// coordinates are computed from `rect.width` / `rect.height`
    /// so the same path scales to any size without distortion.
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        switch self {

        // MARK: Ravens & feathers
        case .ravenFlying:
            // Two arc'd wings + a tiny body — like the classic
            // "M-shaped" bird-in-flight glyph but rounded.
            p.move(to: CGPoint(x: w * 0.10, y: h * 0.55))
            p.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.45),
                           control: CGPoint(x: w * 0.30, y: h * 0.30))
            p.addQuadCurve(to: CGPoint(x: w * 0.90, y: h * 0.55),
                           control: CGPoint(x: w * 0.70, y: h * 0.30))
            // Tiny body dimple in the centre
            p.move(to: CGPoint(x: w * 0.45, y: h * 0.48))
            p.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.48),
                           control: CGPoint(x: w * 0.50, y: h * 0.58))

        case .ravenPerched:
            // Round body, beak, two feet — minimal silhouette
            let bodyRect = CGRect(x: w * 0.22, y: h * 0.20, width: w * 0.55, height: h * 0.55)
            p.addEllipse(in: bodyRect)
            // Beak
            p.move(to: CGPoint(x: w * 0.74, y: h * 0.38))
            p.addLine(to: CGPoint(x: w * 0.90, y: h * 0.42))
            p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.46))
            // Feet
            p.move(to: CGPoint(x: w * 0.40, y: h * 0.75))
            p.addLine(to: CGPoint(x: w * 0.40, y: h * 0.90))
            p.move(to: CGPoint(x: w * 0.58, y: h * 0.75))
            p.addLine(to: CGPoint(x: w * 0.58, y: h * 0.90))

        case .feather:
            // Curved spine + side ribs
            p.move(to: CGPoint(x: w * 0.30, y: h * 0.85))
            p.addQuadCurve(to: CGPoint(x: w * 0.75, y: h * 0.20),
                           control: CGPoint(x: w * 0.45, y: h * 0.40))
            // Ribs
            for i in 1...3 {
                let t = Double(i) / 4.0
                let along = CGPoint(x: w * (0.30 + 0.45 * t),
                                    y: h * (0.85 - 0.65 * t))
                p.move(to: along)
                p.addLine(to: CGPoint(x: along.x + w * 0.18 * cos(.pi * 0.6),
                                      y: along.y - h * 0.10))
            }

        // MARK: Stars
        case .star4:
            // 4-point twinkle
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.10))
            p.addLine(to: CGPoint(x: w * 0.55, y: h * 0.45))
            p.addLine(to: CGPoint(x: w * 0.90, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.55, y: h * 0.55))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.90))
            p.addLine(to: CGPoint(x: w * 0.45, y: h * 0.55))
            p.addLine(to: CGPoint(x: w * 0.10, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.45, y: h * 0.45))
            p.closeSubpath()

        case .star5:
            // 5-point classic
            let centre = CGPoint(x: w * 0.5, y: h * 0.5)
            let outer = min(w, h) * 0.42
            let inner = outer * 0.4
            for i in 0..<10 {
                let angle = -Double.pi / 2 + Double(i) * .pi / 5
                let r = i.isMultiple(of: 2) ? outer : inner
                let pt = CGPoint(x: centre.x + cos(angle) * r,
                                 y: centre.y + sin(angle) * r)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()

        case .sparkle:
            // Diamond cross-hair
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.10))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.90))
            p.move(to: CGPoint(x: w * 0.10, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.90, y: h * 0.50))
            p.move(to: CGPoint(x: w * 0.25, y: h * 0.25))
            p.addLine(to: CGPoint(x: w * 0.75, y: h * 0.75))
            p.move(to: CGPoint(x: w * 0.75, y: h * 0.25))
            p.addLine(to: CGPoint(x: w * 0.25, y: h * 0.75))

        // MARK: Moons & planets
        case .crescentMoon:
            // Outer disk minus offset inner disk
            let outer = Path(ellipseIn: CGRect(x: w * 0.18, y: h * 0.15,
                                                width: w * 0.7, height: h * 0.7))
            let inner = Path(ellipseIn: CGRect(x: w * 0.30, y: h * 0.10,
                                                width: w * 0.7, height: h * 0.7))
            p = outer.subtracting(inner)

        case .fullMoon:
            // Disk + a couple of craters
            p.addEllipse(in: CGRect(x: w * 0.18, y: h * 0.18,
                                     width: w * 0.64, height: h * 0.64))
            p.addEllipse(in: CGRect(x: w * 0.35, y: h * 0.30,
                                     width: w * 0.12, height: h * 0.12))
            p.addEllipse(in: CGRect(x: w * 0.55, y: h * 0.55,
                                     width: w * 0.10, height: h * 0.10))

        case .planet:
            // Simple sphere with a band
            p.addEllipse(in: CGRect(x: w * 0.20, y: h * 0.22,
                                     width: w * 0.60, height: h * 0.60))
            p.move(to: CGPoint(x: w * 0.22, y: h * 0.55))
            p.addQuadCurve(to: CGPoint(x: w * 0.78, y: h * 0.55),
                           control: CGPoint(x: w * 0.50, y: h * 0.40))

        case .saturn:
            // Disk + tilted ring
            p.addEllipse(in: CGRect(x: w * 0.28, y: h * 0.32,
                                     width: w * 0.45, height: h * 0.45))
            // Ring as a flattened ellipse stroke
            p.move(to: CGPoint(x: w * 0.05, y: h * 0.62))
            p.addQuadCurve(to: CGPoint(x: w * 0.95, y: h * 0.42),
                           control: CGPoint(x: w * 0.50, y: h * 0.10))
            p.move(to: CGPoint(x: w * 0.95, y: h * 0.42))
            p.addQuadCurve(to: CGPoint(x: w * 0.05, y: h * 0.62),
                           control: CGPoint(x: w * 0.50, y: h * 0.95))

        // MARK: Space objects
        case .ufo:
            // Saucer + dome
            p.addEllipse(in: CGRect(x: w * 0.10, y: h * 0.50,
                                     width: w * 0.80, height: h * 0.20))
            p.move(to: CGPoint(x: w * 0.30, y: h * 0.55))
            p.addQuadCurve(to: CGPoint(x: w * 0.70, y: h * 0.55),
                           control: CGPoint(x: w * 0.50, y: h * 0.25))
            // Beam
            p.move(to: CGPoint(x: w * 0.38, y: h * 0.72))
            p.addLine(to: CGPoint(x: w * 0.30, y: h * 0.95))
            p.move(to: CGPoint(x: w * 0.62, y: h * 0.72))
            p.addLine(to: CGPoint(x: w * 0.70, y: h * 0.95))

        case .comet:
            // Head + dashed trail
            p.addEllipse(in: CGRect(x: w * 0.65, y: h * 0.30,
                                     width: w * 0.20, height: h * 0.20))
            p.move(to: CGPoint(x: w * 0.62, y: h * 0.45))
            p.addLine(to: CGPoint(x: w * 0.20, y: h * 0.80))
            p.move(to: CGPoint(x: w * 0.55, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.25, y: h * 0.72))

        case .shootingStar:
            // Star with trailing line
            p.addEllipse(in: CGRect(x: w * 0.65, y: h * 0.18,
                                     width: w * 0.18, height: h * 0.18))
            p.move(to: CGPoint(x: w * 0.65, y: h * 0.35))
            p.addLine(to: CGPoint(x: w * 0.20, y: h * 0.85))

        case .satellite:
            // Body + two solar panels + signal arc
            p.addRect(CGRect(x: w * 0.40, y: h * 0.40,
                             width: w * 0.20, height: h * 0.20))
            p.move(to: CGPoint(x: w * 0.40, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.12, y: h * 0.50))
            p.move(to: CGPoint(x: w * 0.60, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.50))
            // Antenna
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.40))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.18))
            p.addEllipse(in: CGRect(x: w * 0.46, y: h * 0.10,
                                     width: w * 0.08, height: h * 0.08))

        case .antenna:
            // Tower with broadcasting rings
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.80))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.40))
            p.move(to: CGPoint(x: w * 0.35, y: h * 0.80))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.40))
            p.addLine(to: CGPoint(x: w * 0.65, y: h * 0.80))
            // Top signal arcs
            p.addArc(center: CGPoint(x: w * 0.50, y: h * 0.40),
                     radius: w * 0.18,
                     startAngle: .degrees(200),
                     endAngle: .degrees(340),
                     clockwise: false)
            p.addArc(center: CGPoint(x: w * 0.50, y: h * 0.40),
                     radius: w * 0.30,
                     startAngle: .degrees(210),
                     endAngle: .degrees(330),
                     clockwise: false)

        case .wifi:
            // Three nested arcs + dot
            for i in 0..<3 {
                p.addArc(center: CGPoint(x: w * 0.50, y: h * 0.80),
                         radius: w * (0.16 + 0.12 * Double(i)),
                         startAngle: .degrees(210),
                         endAngle: .degrees(330),
                         clockwise: false)
            }
            p.addEllipse(in: CGRect(x: w * 0.45, y: h * 0.75,
                                     width: w * 0.10, height: h * 0.10))

        // MARK: Communication
        case .lockClosed:
            // Body + shackle
            p.addRect(CGRect(x: w * 0.28, y: h * 0.45,
                             width: w * 0.44, height: h * 0.40))
            p.move(to: CGPoint(x: w * 0.36, y: h * 0.45))
            p.addArc(center: CGPoint(x: w * 0.50, y: h * 0.40),
                     radius: w * 0.16,
                     startAngle: .degrees(180),
                     endAngle: .degrees(360),
                     clockwise: false)

        case .key:
            // Round head + simple shaft + tooth
            p.addEllipse(in: CGRect(x: w * 0.15, y: h * 0.38,
                                     width: w * 0.25, height: h * 0.25))
            p.move(to: CGPoint(x: w * 0.40, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.50))
            p.move(to: CGPoint(x: w * 0.78, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.65))
            p.move(to: CGPoint(x: w * 0.65, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.65, y: h * 0.60))

        case .envelope:
            // Rect + flap V
            p.addRect(CGRect(x: w * 0.15, y: h * 0.30,
                             width: w * 0.70, height: h * 0.40))
            p.move(to: CGPoint(x: w * 0.15, y: h * 0.30))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.55))
            p.addLine(to: CGPoint(x: w * 0.85, y: h * 0.30))

        case .speechBubble:
            // Rounded rect with tail
            let bubble = CGRect(x: w * 0.15, y: h * 0.20,
                                width: w * 0.70, height: h * 0.50)
            p.addRoundedRect(in: bubble, cornerSize: CGSize(width: w * 0.14, height: h * 0.14))
            // Tail
            p.move(to: CGPoint(x: w * 0.35, y: h * 0.70))
            p.addLine(to: CGPoint(x: w * 0.30, y: h * 0.86))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.70))

        case .microphone:
            // Capsule head + arc base + stand
            p.addRoundedRect(in: CGRect(x: w * 0.38, y: h * 0.18,
                                         width: w * 0.24, height: h * 0.40),
                              cornerSize: CGSize(width: w * 0.12, height: h * 0.12))
            // Arc cradle
            p.addArc(center: CGPoint(x: w * 0.50, y: h * 0.50),
                     radius: w * 0.20,
                     startAngle: .degrees(20),
                     endAngle: .degrees(160),
                     clockwise: false)
            // Stand
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.70))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.85))
            p.move(to: CGPoint(x: w * 0.35, y: h * 0.85))
            p.addLine(to: CGPoint(x: w * 0.65, y: h * 0.85))

        case .headphones:
            // Top arc + two ear cups
            p.addArc(center: CGPoint(x: w * 0.50, y: h * 0.55),
                     radius: w * 0.35,
                     startAngle: .degrees(200),
                     endAngle: .degrees(340),
                     clockwise: false)
            p.addRoundedRect(in: CGRect(x: w * 0.12, y: h * 0.50,
                                         width: w * 0.16, height: h * 0.28),
                              cornerSize: CGSize(width: w * 0.06, height: h * 0.06))
            p.addRoundedRect(in: CGRect(x: w * 0.72, y: h * 0.50,
                                         width: w * 0.16, height: h * 0.28),
                              cornerSize: CGSize(width: w * 0.06, height: h * 0.06))

        case .musicNote:
            // Note head + stem + flag
            p.addEllipse(in: CGRect(x: w * 0.18, y: h * 0.62,
                                     width: w * 0.22, height: h * 0.18))
            p.move(to: CGPoint(x: w * 0.40, y: h * 0.70))
            p.addLine(to: CGPoint(x: w * 0.40, y: h * 0.20))
            p.addQuadCurve(to: CGPoint(x: w * 0.75, y: h * 0.40),
                           control: CGPoint(x: w * 0.70, y: h * 0.10))

        // MARK: Misc cosy
        case .heart:
            // Simple heart from two arcs + V tip
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.85))
            p.addCurve(to: CGPoint(x: w * 0.10, y: h * 0.40),
                       control1: CGPoint(x: w * 0.25, y: h * 0.75),
                       control2: CGPoint(x: w * 0.05, y: h * 0.55))
            p.addArc(center: CGPoint(x: w * 0.30, y: h * 0.32),
                     radius: w * 0.22,
                     startAngle: .degrees(180),
                     endAngle: .degrees(0),
                     clockwise: false)
            p.addArc(center: CGPoint(x: w * 0.70, y: h * 0.32),
                     radius: w * 0.22,
                     startAngle: .degrees(180),
                     endAngle: .degrees(0),
                     clockwise: false)
            p.addCurve(to: CGPoint(x: w * 0.50, y: h * 0.85),
                       control1: CGPoint(x: w * 0.95, y: h * 0.55),
                       control2: CGPoint(x: w * 0.75, y: h * 0.75))

        case .diamond:
            // Faceted gem
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.10))
            p.addLine(to: CGPoint(x: w * 0.90, y: h * 0.40))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.90))
            p.addLine(to: CGPoint(x: w * 0.10, y: h * 0.40))
            p.closeSubpath()
            p.move(to: CGPoint(x: w * 0.10, y: h * 0.40))
            p.addLine(to: CGPoint(x: w * 0.90, y: h * 0.40))
            p.move(to: CGPoint(x: w * 0.30, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.40))
            p.addLine(to: CGPoint(x: w * 0.70, y: h * 0.20))

        case .lightning:
            // Zigzag bolt
            p.move(to: CGPoint(x: w * 0.58, y: h * 0.10))
            p.addLine(to: CGPoint(x: w * 0.25, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.48, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.90))
            p.addLine(to: CGPoint(x: w * 0.75, y: h * 0.42))
            p.addLine(to: CGPoint(x: w * 0.52, y: h * 0.42))
            p.closeSubpath()

        case .coffeeCup:
            // Mug + handle + steam
            p.addRoundedRect(in: CGRect(x: w * 0.25, y: h * 0.40,
                                         width: w * 0.40, height: h * 0.40),
                              cornerSize: CGSize(width: w * 0.04, height: h * 0.04))
            // Handle
            p.move(to: CGPoint(x: w * 0.65, y: h * 0.50))
            p.addArc(center: CGPoint(x: w * 0.70, y: h * 0.58),
                     radius: w * 0.12,
                     startAngle: .degrees(-90),
                     endAngle: .degrees(90),
                     clockwise: false)
            p.move(to: CGPoint(x: w * 0.65, y: h * 0.66))
            // Steam
            p.move(to: CGPoint(x: w * 0.35, y: h * 0.30))
            p.addQuadCurve(to: CGPoint(x: w * 0.35, y: h * 0.10),
                           control: CGPoint(x: w * 0.42, y: h * 0.20))
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.30))
            p.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.10),
                           control: CGPoint(x: w * 0.43, y: h * 0.20))

        case .mountain:
            // Two peaks + base line + small sun
            p.move(to: CGPoint(x: w * 0.05, y: h * 0.80))
            p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.40))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.60))
            p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.30))
            p.addLine(to: CGPoint(x: w * 0.95, y: h * 0.80))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: w * 0.18, y: h * 0.15,
                                     width: w * 0.16, height: h * 0.16))

        case .leaf:
            // Pointed oval + central vein
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.10))
            p.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.90),
                           control: CGPoint(x: w * 0.10, y: h * 0.55))
            p.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.10),
                           control: CGPoint(x: w * 0.90, y: h * 0.45))
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.10))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.90))

        case .compass:
            // Circle + N-S needle
            p.addEllipse(in: CGRect(x: w * 0.12, y: h * 0.12,
                                     width: w * 0.76, height: h * 0.76))
            p.move(to: CGPoint(x: w * 0.50, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.40, y: h * 0.50))
            p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.80))
            p.addLine(to: CGPoint(x: w * 0.60, y: h * 0.50))
            p.closeSubpath()
        }

        return p
    }
}

// MARK: - utilities

private func fract(_ x: Double) -> Double { x - floor(x) }

// MARK: - Previews

#if DEBUG
#Preview("Dark") {
    RavenChatWallpaper()
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    RavenChatWallpaper()
        .preferredColorScheme(.light)
}
#endif
