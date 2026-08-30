// CardStyle.swift
// Shared card surfaces ported from the Android drawables:
//   - token_picker_dialog_bg.xml: #17151F fill, 1pt #8F8AAA stroke, 16pt
//     radius (token picker, tx-steps, gas-config dialogs).
//   - center_container.xml (v24): vertical gradient #1F1D35 -> #10121F ->
//     #0B0E18, 1pt #8F8AAA stroke, 22pt radius (home card, token /
//     transaction tables, review dialog, yes/no dialog).

import UIKit

public enum CardStyle {

    public static func applyDexDialog(to card: UIView) {
        card.backgroundColor = UIColor(rgbHex: 0x17151F)
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(rgbHex: 0x8F8AAA).cgColor
        card.layer.masksToBounds = true
    }

    /// Installs the center-container gradient as a background sublayer.
    /// Callers must call `layoutCenterContainer(_:in:)` from their
    /// layout pass so the gradient tracks the card bounds.
    @discardableResult
    public static func applyCenterContainer(to card: UIView) -> CAGradientLayer {
        card.backgroundColor = UIColor(rgbHex: 0x10121F)
        card.layer.cornerRadius = 22
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(rgbHex: 0x8F8AAA).cgColor
        card.layer.masksToBounds = true
        let g = CAGradientLayer()
        g.colors = [UIColor(rgbHex: 0x1F1D35).cgColor,
                    UIColor(rgbHex: 0x10121F).cgColor,
                    UIColor(rgbHex: 0x0B0E18).cgColor]
        g.locations = [0, 0.5, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0)
        g.endPoint = CGPoint(x: 0.5, y: 1)
        g.cornerRadius = 22
        g.frame = card.bounds
        card.layer.insertSublayer(g, at: 0)
        return g
    }

    public static func layoutCenterContainer(_ gradient: CAGradientLayer?, in card: UIView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient?.frame = card.bounds
        CATransaction.commit()
    }
}

/// A view whose background is the center-container gradient card.
public final class CenterContainerView: UIView {
    private var gradient: CAGradientLayer?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        gradient = CardStyle.applyCenterContainer(to: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CardStyle.layoutCenterContainer(gradient, in: self)
    }
}

// MARK: - Screen card shell (Android center_container screen pattern)

/// Metrics copied from the Android screen layouts (swap_fragment.xml
/// et al.): every main screen is back-arrow row above a
/// `center_container` card with 10dp side margins and content inset
/// 10 top / 15 bottom / 10 left / 10 right.
public enum ScreenCardMetrics {
    public static let horizontalMargin: CGFloat = 10
    public static let backBarBottomGap: CGFloat = 20
    public static let contentInsets = UIEdgeInsets(top: 10, left: 10, bottom: 15, right: 10)
}

/// Installs the Android screen shell inside a scroll view:
/// back bar, then the 22pt gradient card wrapping `content`. The
/// back bar and card both live inside the scroll (Android parity -
/// the whole card scrolls). The caller keeps its own
/// `scroll` <-> `view` constraints (safe-area top, keyboard guide
/// bottom, etc.).
public enum ScreenCard {

    @discardableResult
    public static func install(in scroll: UIScrollView,
                               backBar: UIView,
                               content: UIView) -> CenterContainerView {
        let card = CenterContainerView()
        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        let insets = ScreenCardMetrics.contentInsets
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -insets.right)
        ])

        let outer = UIStackView(arrangedSubviews: [backBar, card])
        outer.axis = .vertical
        outer.spacing = ScreenCardMetrics.backBarBottomGap
        outer.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            outer.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            outer.leadingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.leadingAnchor,
                constant: ScreenCardMetrics.horizontalMargin),
            outer.trailingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.trailingAnchor,
                constant: -ScreenCardMetrics.horizontalMargin)
        ])
        return card
    }

    /// Same shell for short screens that have no scroll view
    /// (Advanced, Settings): back bar + card pinned directly to the
    /// host view's safe area; the card hugs its content height.
    @discardableResult
    public static func installUnscrolled(in host: UIView,
                                         backBar: UIView,
                                         content: UIView) -> CenterContainerView {
        let card = CenterContainerView()
        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        let insets = ScreenCardMetrics.contentInsets
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -insets.right)
        ])
        let outer = UIStackView(arrangedSubviews: [backBar, card])
        outer.axis = .vertical
        outer.spacing = ScreenCardMetrics.backBarBottomGap
        outer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 8),
            outer.leadingAnchor.constraint(
                equalTo: host.leadingAnchor, constant: ScreenCardMetrics.horizontalMargin),
            outer.trailingAnchor.constraint(
                equalTo: host.trailingAnchor, constant: -ScreenCardMetrics.horizontalMargin)
        ])
        return card
    }
}
