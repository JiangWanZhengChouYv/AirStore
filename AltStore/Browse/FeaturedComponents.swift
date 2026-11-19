//
//  FeaturedComponents.swift
//  AltStore
//
//  Created by Riley Testut on 12/4/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

/// A category tile. The App Store's are a coloured rectangle with the name in the top-left and the
/// glyph bleeding off the bottom-right corner; ours used to centre an 80pt glyph and put the name at
/// the bottom, which read as a button rather than a shelf.
class LargeIconCollectionViewCell: UICollectionViewCell
{
    let textLabel = UILabel(frame: .zero)
    let imageView = UIImageView(frame: .zero)
    
    override init(frame: CGRect)
    {
        self.textLabel.translatesAutoresizingMaskIntoConstraints = false
        self.textLabel.textColor = .white
        self.textLabel.font = .preferredFont(forTextStyle: .headline)
        self.textLabel.adjustsFontForContentSizeCategory = true
        self.textLabel.numberOfLines = 2
        
        self.imageView.translatesAutoresizingMaskIntoConstraints = false
        self.imageView.contentMode = .scaleAspectFit
        self.imageView.tintColor = .white
        self.imageView.alpha = 0.32
        self.imageView.preferredSymbolConfiguration = .init(pointSize: 64, weight: .semibold)
        
        super.init(frame: frame)
        
        self.contentView.clipsToBounds = true
        self.contentView.layer.cornerRadius = 20
        self.contentView.layer.cornerCurve = .continuous
        
        self.contentView.addSubview(self.textLabel)
        self.contentView.addSubview(self.imageView)
        
        self.imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.textLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            // Name in the top-left corner, glyph hanging off the bottom-right: the App Store's
            // arrangement, and the reason the tile reads as a category rather than a button.
            self.textLabel.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12),
            self.textLabel.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 14),
            self.textLabel.trailingAnchor.constraint(lessThanOrEqualTo: self.contentView.trailingAnchor, constant: -14),

            self.imageView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: 14),
            self.imageView.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: 10),
            self.imageView.heightAnchor.constraint(equalToConstant: 64),
            self.imageView.widthAnchor.constraint(equalTo: self.imageView.heightAnchor)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class IconButtonCollectionReusableView: UICollectionReusableView
{
    let iconButton: UIButton
    let titleButton: UIButton
    
    private let stackView: UIStackView
    
    override init(frame: CGRect)
    {
        let iconHeight = 26.0
        
        self.iconButton = UIButton(type: .custom)
        self.iconButton.translatesAutoresizingMaskIntoConstraints = false
        self.iconButton.clipsToBounds = true
        self.iconButton.layer.cornerRadius = iconHeight / 2
        
        let content = UIListContentConfiguration.plainHeader()
        self.titleButton = UIButton(type: .system)
        self.titleButton.translatesAutoresizingMaskIntoConstraints = false
        self.titleButton.titleLabel?.font = content.textProperties.font
        self.titleButton.setTitleColor(content.textProperties.color, for: .normal)
        
        self.stackView = UIStackView(arrangedSubviews: [self.iconButton, self.titleButton])
        self.stackView.translatesAutoresizingMaskIntoConstraints = false
        self.stackView.axis = .horizontal
        self.stackView.alignment = .center
        self.stackView.spacing = UIStackView.spacingUseSystem
        self.stackView.isLayoutMarginsRelativeArrangement = false
        
        super.init(frame: frame)
        
        self.addSubview(self.stackView)
        
        NSLayoutConstraint.activate([
            self.iconButton.heightAnchor.constraint(equalToConstant: iconHeight),
            self.iconButton.widthAnchor.constraint(equalTo: self.iconButton.heightAnchor),
            
            self.stackView.topAnchor.constraint(equalTo: self.topAnchor),
            self.stackView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            self.stackView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.stackView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
