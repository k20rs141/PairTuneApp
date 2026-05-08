import SwiftUI

extension Color {
    // Base palette — V5 Deep (Lavender Dream)
    static let pairtuneBase          = Color(hex: "0C0818")
    static let pairtuneSurface       = Color(hex: "16112A")
    static let pairtuneSurfaceSheet  = Color(hex: "16112A")
    static let pairtuneSurfaceHi     = Color(hex: "1E1836")
    static let pairtuneHairline      = Color(hex: "262238")

    // Accent — V5 Deep
    static let pairtunePrimary    = Color(hex: "9B7BFF")  // lavender violet
    static let pairtuneSecondary  = Color(hex: "FF6B9D")  // pink

    // Backwards-compat aliases (旧 V1 命名で参照しているコード用)
    static let pairtuneCoral  = Color(hex: "9B7BFF")
    static let pairtuneCream  = Color(hex: "FF6B9D")

    // Text
    static let pairtuneTextPrimary    = Color.white
    static let pairtuneTextSecondary  = Color(hex: "A8A8A8")
    static let pairtuneTextTertiary   = Color(hex: "6B6B6B")
    static let pairtuneTextQuaternary = Color(hex: "3F3F3F")

    // Status
    static let pairtuneSyncOk   = Color(hex: "7BD389")
    static let pairtuneSyncWarn = Color(hex: "F4C26A")
    static let pairtuneSyncBad  = Color(hex: "E85B6B")

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r, g, b: UInt64
        switch h.count {
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (255, 255, 255)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
    }
}
