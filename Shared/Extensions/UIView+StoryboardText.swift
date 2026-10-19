//  UIView+StoryboardText.swift
//  AltStore
//

import UIKit

public extension UIView
{
    /// Localizes the text Interface Builder baked into this view hierarchy.
    ///
    /// A storyboard stores the English literal directly rather than a key, so nothing consults the
    /// string catalog for it and the label stays English in every language. Looking each string up
    /// again turns those literals into keys. A string with no catalog entry is returned unchanged,
    /// which is what makes this safe to run over reused cells and over labels that show app names.
    @MainActor
    func localizingStoryboardText()
    {
        if let label = self as? UILabel, let text = label.text, !text.isEmpty
        {
            let localized = NSLocalizedString(text, comment: "")
            if localized != text { label.text = localized }
        }

        if let button = self as? UIButton, let title = button.title(for: .normal), !title.isEmpty
        {
            let localized = NSLocalizedString(title, comment: "")
            if localized != title { button.setTitle(localized, for: .normal) }
        }

        if let textField = self as? UITextField, let placeholder = textField.placeholder, !placeholder.isEmpty
        {
            let localized = NSLocalizedString(placeholder, comment: "")
            if localized != placeholder { textField.placeholder = localized }
        }

        for subview in self.subviews
        {
            subview.localizingStoryboardText()
        }
    }
}
