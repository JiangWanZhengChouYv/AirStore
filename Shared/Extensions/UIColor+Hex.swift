//
//  UIColor+Hex.swift
//  AltStore
//
//  Created by Riley Testut on 7/15/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

public extension UIColor
{
    // Borrowed from https://stackoverflow.com/a/26341062
    var hexString: String {
        let components = self.cgColor.components
        let red: CGFloat = components?[0] ?? 0.0
        let green: CGFloat = components?[1] ?? 0.0
        let blue: CGFloat = components?[2] ?? 0.0

        let hexString = String.init(format: "%02lX%02lX%02lX", lroundf(Float(red * 255)), lroundf(Float(green * 255)), lroundf(Float(blue * 255)))
        return hexString
    }
    
    // Borrowed from https://stackoverflow.com/a/33397427
    convenience init?(hexString: String)
    {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let int32 = Scanner(string: hex).scanInt32(representation: .hexadecimal), case let int = UInt32(int32) else { return nil }
        
        let alphaByte, redByte, greenByte, blueByte: UInt32
        switch hex.count {
        case 3: // RGB (12-bit)
            (alphaByte, redByte, greenByte, blueByte) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (alphaByte, redByte, greenByte, blueByte) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (alphaByte, redByte, greenByte, blueByte) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(red: CGFloat(redByte) / 255, green: CGFloat(greenByte) / 255, blue: CGFloat(blueByte) / 255, alpha: CGFloat(alphaByte) / 255)
    }
}
