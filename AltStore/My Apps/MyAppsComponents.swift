//
//  MyAppsComponents.swift
//  AltStore
//
//  Created by Riley Testut on 7/17/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

final class InstalledAppCollectionViewCell: UICollectionViewCell
{
    var bundleIdentifier: String?
    private(set) var deactivateBadge: UIView?
    
    @IBOutlet var bannerView: AppBannerView!
    
    override func awakeFromNib()
    {
        super.awakeFromNib()
        
        self.contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.contentView.preservesSuperviewLayoutMargins = true
        
        let deactivateBadge = UIView()
        deactivateBadge.translatesAutoresizingMaskIntoConstraints = false
        deactivateBadge.isHidden = true
        self.addSubview(deactivateBadge)
        
        // Solid background to make the X opaque white.
        let backgroundView = UIView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.backgroundColor = .white
        deactivateBadge.addSubview(backgroundView)
                    
        let badgeView = UIImageView(image: UIImage(systemName: "xmark.circle.fill"))
        badgeView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(scale: .large)
        badgeView.tintColor = .systemRed
        deactivateBadge.addSubview(badgeView, pinningEdgesWith: .zero)
        
        NSLayoutConstraint.activate([
            deactivateBadge.centerXAnchor.constraint(equalTo: self.bannerView.iconImageView.trailingAnchor),
            deactivateBadge.centerYAnchor.constraint(equalTo: self.bannerView.iconImageView.topAnchor),
            
            backgroundView.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            backgroundView.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            backgroundView.widthAnchor.constraint(equalTo: badgeView.widthAnchor, multiplier: 0.5),
            backgroundView.heightAnchor.constraint(equalTo: badgeView.heightAnchor, multiplier: 0.5)
        ])
        
        self.deactivateBadge = deactivateBadge
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        self.bannerView?.button?.resetDisplayState()
    }
}

/// A guest running inside AirBox. Built in code because nothing in a storyboard knows about these rows,
/// and the banner is the same view every other row on this screen uses.
final class ContainerAppCollectionViewCell: UICollectionViewCell
{
    let bannerView = AppBannerView(frame: .zero)

    override init(frame: CGRect)
    {
        super.init(frame: frame)

        self.contentView.preservesSuperviewLayoutMargins = true

        self.bannerView.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(self.bannerView)

        NSLayoutConstraint.activate([
            self.bannerView.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor),
            self.bannerView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor),
            self.bannerView.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 4),
            self.bannerView.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse()
    {
        super.prepareForReuse()
        self.bannerView.button.resetDisplayState()
    }
}

final class InstalledAppsCollectionFooterView: UICollectionReusableView
{
    @IBOutlet var textLabel: UILabel!
    @IBOutlet var button: UIButton!
}

final class NoUpdatesCollectionViewCell: UICollectionViewCell
{
    @IBOutlet var blurView: UIVisualEffectView!
    @IBOutlet var textLabel: UILabel!
    @IBOutlet var button: UIButton!
    
    override func awakeFromNib()
    {
        super.awakeFromNib()
        
        self.contentView.preservesSuperviewLayoutMargins = true
        
        let font = self.textLabel.font ?? UIFont.systemFont(ofSize: 17)
        let configuration = UIImage.SymbolConfiguration(font: font)
        let image = UIImage(systemName: "ellipsis.circle", withConfiguration: configuration)
        
        self.button.setTitle("", for: .normal)
        self.button.setImage(image, for: .normal)
    }
}

final class UpdatesCollectionHeaderView: UICollectionReusableView
{
    let button = PillButton(type: .system)
    
    override init(frame: CGRect)
    {
        super.init(frame: frame)
        
        self.button.translatesAutoresizingMaskIntoConstraints = false
        self.button.setTitle(">", for: .normal)
        self.addSubview(self.button)
        
        NSLayoutConstraint.activate([self.button.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -20),
                                     self.button.topAnchor.constraint(equalTo: self.topAnchor),
                                     self.button.widthAnchor.constraint(equalToConstant: 50),
                                     self.button.heightAnchor.constraint(equalToConstant: 26)])
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
