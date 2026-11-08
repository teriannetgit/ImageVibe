import SwiftUI

/// Colour tokens for the main window.
enum Darkroom {
    static let canvas = Color(red: 0x0F / 255, green: 0x0E / 255, blue: 0x0D / 255)
    static let panel = Color(red: 0x17 / 255, green: 0x15 / 255, blue: 0x14 / 255)
    static let field = Color(red: 0x22 / 255, green: 0x1F / 255, blue: 0x1D / 255)
    static let hairline = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.62)
    /// Reserved for Generate, progress and the selected frame.
    static let safelight = Color(red: 0xC4 / 255, green: 0x42 / 255, blue: 0x1F / 255)
    /// The film strip itself; the panel around it shows through where the leader is trimmed.
    static let filmBase = Color(red: 0x0B / 255, green: 0x0A / 255, blue: 0x09 / 255)
    static let edgePrint = Color(red: 0xD4 / 255, green: 0x9A / 255, blue: 0x3A / 255)
}
