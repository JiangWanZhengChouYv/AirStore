//
//  NavigationBar.swift
//  AltStore
//
//  Created by Riley Testut on 7/15/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit


class NavigationBarAppearance: UINavigationBarAppearance
{
    // We sometimes need to ignore user interaction so
    // we can tap items underneath the navigation bar.
    var ignoresUserInteraction: Bool = false
    
    override func copy(with zone: NSZone? = nil) -> Any
    {
        let copy = super.copy(with: zone) as! NavigationBarAppearance
        copy.ignoresUserInteraction = self.ignoresUserInteraction
        return copy
    }
}

class NavigationBar: UINavigationBar
{    
    @IBInspectable var automaticallyAdjustsItemPositions: Bool = true
    
    override init(frame: CGRect)
    {
        super.init(frame: frame)
        
        self.initialize()
    }
    
    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        
        self.initialize()
    }
    
    private func initialize()
    {
        #if !os(tvOS)
        self.applyBarColour()
        // This bar sits on the page whose button opens the colour picker, so it has to be able to
        // change while it is on screen.
        NotificationCenter.default.addObserver(self, selector: #selector(self.refreshBarColour),
                                               name: ThemeManager.themeDidChangeNotification, object: nil)
        #else
        if let tintColor = self.barTintColor {
            self.barTintColor = tintColor
            self.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.white]
        }
        #endif
    }

    @objc private func refreshBarColour()
    {
        #if !os(tvOS)
        self.applyBarColour()
        #endif
    }

    private func applyBarColour()
    {
        #if !os(tvOS)
        // The storyboard hands over the stock asset as barTintColor; a picked colour has to win here,
        // otherwise the settings bar stays blue above a page that is now teal. A nil barTintColor is a
        // deliberate "use the system bar" (Browse, Sources, Main), and painting those with the settings
        // surface put an opaque block across the top of every one of them.
        let themedBarColor = (ThemeManager.shared.isUsingCustomTheme && self.barTintColor != nil) ? UIColor.settingsBackground : nil
        let barColor = themedBarColor ?? self.barTintColor

        let standardAppearance = UINavigationBarAppearance()
        standardAppearance.configureWithDefaultBackground()
        standardAppearance.shadowColor = nil
        
        let edgeAppearance = UINavigationBarAppearance()
        edgeAppearance.configureWithOpaqueBackground()
        edgeAppearance.backgroundColor = barColor
        edgeAppearance.shadowColor = nil
        
        if let tintColor = barColor
        {
            let textAttributes = [NSAttributedString.Key.foregroundColor: UIColor.white]
            
            standardAppearance.backgroundColor = tintColor
            standardAppearance.titleTextAttributes = textAttributes
            standardAppearance.largeTitleTextAttributes = textAttributes
            
            edgeAppearance.titleTextAttributes = textAttributes
            edgeAppearance.largeTitleTextAttributes = textAttributes
        }
        else
        {
            standardAppearance.backgroundColor = nil
        }
        
        self.scrollEdgeAppearance = edgeAppearance
        self.standardAppearance = standardAppearance
        #endif
    }
    
    override func layoutSubviews()
    {
        super.layoutSubviews()
        
        if self.automaticallyAdjustsItemPositions
        {
            // We can't easily shift just the back button up, so we shift the entire content view slightly.
            for contentView in self.subviews
            {
                guard NSStringFromClass(type(of: contentView)).contains("ContentView") else { continue }
                contentView.center.y -= 2
            }
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView?
    {
        #if !os(tvOS)
        if let appearance = self.topItem?.standardAppearance as? NavigationBarAppearance, appearance.ignoresUserInteraction
        {
            // Ignore touches.
            return nil
        }
        #endif
        
        return super.hitTest(point, with: event)
    }
}
