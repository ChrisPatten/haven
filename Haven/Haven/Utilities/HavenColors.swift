//
//  HavenColors.swift
//  Haven
//
//  Created by Codex on 11/8/25.
//

import SwiftUI
import AppKit

/// Brand-aware color conveniences used across the unified UI.
enum HavenColors {
    static let textPrimary = adaptiveColor(lightHex: "#2E3B36", darkHex: "#EAF6FF")
    static let textSecondary = adaptiveColor(lightHex: "#6E7C78", darkHex: "#C5D9D3")
    static let neutralChrome = adaptiveColor(lightHex: "#C2B8A2", darkHex: "#4F4A3D")
    static let accentGlow = adaptiveColor(lightHex: "#EAF6FF", darkHex: "#DAFFF9")
    static let warning = Color(red: 0.98, green: 0.62, blue: 0.19)
    static let error = Color(red: 0.93, green: 0.32, blue: 0.32)

    static func status(_ status: AppStatus) -> Color {
        switch status {
        case .green:
            return adaptiveColor(lightHex: "#00B8A9", darkHex: "#9AD99A")
        case .yellow:
            return warning
        case .red:
            return error
        }
    }

    private static func adaptiveColor(lightHex: String, darkHex: String) -> Color {
        Color(
            NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    let usesDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return NSColor(hex: usesDark ? darkHex : lightHex)
                }
            )
        )
    }
}

enum HavenGradients {
    static let primaryGradient = LinearGradient(
        colors: [
            Color(hex: "#9AD99A"),
            Color(hex: "#00B8A9")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let backgroundLight = LinearGradient(
        colors: [
            Color(hex: "#D8EEE1"),
            Color(hex: "#9BCFBF")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let backgroundDark = LinearGradient(
        colors: [
            Color(hex: "#2A3B38"),
            Color(hex: "#1B2422")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension NSColor {
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if hexSanitized.count == 3 {
            // Expand shorthand form (#abc -> #aabbcc)
            hexSanitized = hexSanitized.map { "\($0)\($0)" }.joined()
        }

        var int: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0

        self.init(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }
}

extension Color {
    init(hex: String) {
        self.init(NSColor(hex: hex))
    }
}
