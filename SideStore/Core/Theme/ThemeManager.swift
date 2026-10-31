//
//  ThemeManager.swift
//  SideStore
//
//  Created by Magesh K on 9/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit
import Combine

public struct ThemePreset: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let hex: String
    
    public var color: UIColor {
        UIColor(hex: hex) ?? .defaultAltPrimary
    }
    
    public static let presets: [ThemePreset] = [
        ThemePreset(id: "classic", name: "SideStore Teal", hex: "#19D3B5"),
        ThemePreset(id: "neonViolet", name: "Neon Violet", hex: "#8B5CF6"),
        ThemePreset(id: "sunsetCrimson", name: "Sunset Crimson", hex: "#EF4444"),
        ThemePreset(id: "sapphireBlue", name: "Sapphire Blue", hex: "#3B82F6"),
        ThemePreset(id: "cyberpunkGold", name: "Cyberpunk Gold", hex: "#F59E0B"),
        ThemePreset(id: "emeraldMint", name: "Emerald Mint", hex: "#10B981"),
        ThemePreset(id: "electricPink", name: "Electric Pink", hex: "#EC4899")
    ]
}

public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    public static let themeDidChangeNotification = Notification.Name("SideStoreThemeDidChangeNotification")

    private static let userDefaultsKey = "userCustomThemeHex"

    @Published public var primaryColor: UIColor {
        didSet {
            UserDefaults.standard.set(primaryColor.hexString, forKey: Self.userDefaultsKey)
            NotificationCenter.default.post(name: Self.themeDidChangeNotification, object: primaryColor)
            DispatchQueue.main.async {
                for window in UIApplication.altShared?.altAllWindows ?? []
                {
                    window.tintColor = self.primaryColor
                }
            }
        }
    }

    private init() {
        if let hex = UserDefaults.standard.string(forKey: Self.userDefaultsKey),
           let color = UIColor(hex: hex) {
            self.primaryColor = color
        } else {
            self.primaryColor = .defaultAltPrimary
        }
    }

    public func resetToDefault() {
        self.primaryColor = .defaultAltPrimary
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
    }

    /// Whether the colour came from the picker rather than from the shipped asset. The settings
    /// surfaces only follow the theme in that case -- the stock look must not change for anyone who
    /// never touched the picker.
    public var isUsingCustomTheme: Bool {
        UserDefaults.standard.string(forKey: Self.userDefaultsKey) != nil
    }

    /// The settings page's own surface: a dark shade of whatever colour was picked, so the page where
    /// the colour is chosen is itself affected by it. The two brightness numbers come from the shipped
    /// pair -- Primary #3B82F6 has a settings surface of #1E3A8A (0.54) and #172554 in dark mode
    /// (0.33) -- and saturation is capped so a neon pick cannot make the page unreadable.
    public var settingsSurfaceColor: UIColor {
        UIColor { traits in
            ThemeManager.surfaceColor(for: self.primaryColor, isDark: traits.userInterfaceStyle == .dark)
        }
    }

    public static func surfaceColor(for color: UIColor, isDark: Bool) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            // Achromatic colours (black, white, pure grey) have no hue to keep; leave them alone.
            return color
        }
        return UIColor(hue: hue, saturation: min(saturation, 0.8), brightness: isDark ? 0.33 : 0.54, alpha: 1)
    }
}

public extension UIColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hexSanitized.hasPrefix("#") {
            hexSanitized.remove(at: hexSanitized.startIndex)
        }

        var rgbValue: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgbValue) else { return nil }

        let red, green, blue, alpha: CGFloat
        if hexSanitized.count == 6 {
            red = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
            green = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
            blue = CGFloat(rgbValue & 0x0000FF) / 255.0
            alpha = 1.0
        } else if hexSanitized.count == 8 {
            red = CGFloat((rgbValue & 0xFF000000) >> 24) / 255.0
            green = CGFloat((rgbValue & 0x00FF0000) >> 16) / 255.0
            blue = CGFloat((rgbValue & 0x0000FF00) >> 8) / 255.0
            alpha = CGFloat(rgbValue & 0x000000FF) / 255.0
        } else {
            return nil
        }

        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    var rgbComponents: (r: Int, g: Int, b: Int) {
        var redChannel: CGFloat = 0
        var greenChannel: CGFloat = 0
        var blueChannel: CGFloat = 0
        var alphaChannel: CGFloat = 0
        getRed(&redChannel, green: &greenChannel, blue: &blueChannel, alpha: &alphaChannel)
        return (Int(redChannel * 255), Int(greenChannel * 255), Int(blueChannel * 255))
    }

    var hslComponents: (h: Int, s: Int, l: Int) {
        var redChannel: CGFloat = 0
        var greenChannel: CGFloat = 0
        var blueChannel: CGFloat = 0
        var alphaChannel: CGFloat = 0
        getRed(&redChannel, green: &greenChannel, blue: &blueChannel, alpha: &alphaChannel)

        let maxVal = max(redChannel, max(greenChannel, blueChannel))
        let minVal = min(redChannel, min(greenChannel, blueChannel))
        let delta = maxVal - minVal

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        let lightness: CGFloat = (maxVal + minVal) / 2.0

        if delta != 0 {
            saturation = lightness > 0.5 ? delta / (2.0 - maxVal - minVal) : delta / (maxVal + minVal)

            if maxVal == redChannel {
                hue = (greenChannel - blueChannel) / delta + (greenChannel < blueChannel ? 6 : 0)
            } else if maxVal == greenChannel {
                hue = (blueChannel - redChannel) / delta + 2
            } else {
                hue = (redChannel - greenChannel) / delta + 4
            }
            hue /= 6.0
        }

        return (Int(hue * 360), Int(saturation * 100), Int(lightness * 100))
    }
}
