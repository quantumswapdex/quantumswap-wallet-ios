// RefreshIconSwap.swift
// Composite refresh affordance that swaps its icon for a UIActivity-
// IndicatorView in the same on-screen slot for the duration of an
// async refresh. Mirrors the Android `ProgressBar` swap-in / swap-out
// applied to every icon-driven refresh button on Android (account
// transactions top bar, home address strip, confirm-wallet balance
// row). Reused across iOS call sites so the loading feedback stays
// visually consistent.

import UIKit

/// View that hosts an icon `UIButton` and a `UIActivityIndicatorView`
/// pinned to identical center+size constraints. Callers set
/// `setLoading(true)` immediately before kicking off the async work
/// and `setLoading(false)` on the main actor in both the success and
/// failure branches; exactly one of the two children is visible at
/// any given moment.
public final class RefreshIconSwap: UIView {

    /// Tap callback forwarded from the underlying button's
    /// `.touchUpInside`. Cleared while loading so a second tap mid-
    /// fetch is a no-op.
    public var onTap: (() -> Void)?

    /// Mirrors `UIControl.isEnabled` on the inner button. Disabling
    /// also dims the icon for visual feedback.
    public var isEnabled: Bool {
        get { button.isEnabled }
        set {
            button.isEnabled = newValue
            button.alpha = newValue ? 1.0 : 0.4
        }
    }

    private let button = UIButton(type: .system)
    private let spinner: UIActivityIndicatorView

    /// - Parameters:
    ///   - image: refresh glyph asset (`retry` in the strip's case).
    ///   - inset: image inset matching the surrounding chrome's icon
    ///     padding so the swap sits flush with adjacent icons.
    ///   - tintColor: tint applied to the templated icon. Defaults to
    ///     `.label` so the swap reads correctly in both light and
    ///     dark mode.
    ///   - spinnerStyle: indicator style; `.medium` matches the
    ///     32x32 chrome buttons used by the address strip and the
    ///     account-transactions top bar.
    public init(image: UIImage?,
                inset: CGFloat = 5,
                tintColor: UIColor = .label,
                spinnerStyle: UIActivityIndicatorView.Style = .medium) {
        self.spinner = UIActivityIndicatorView(style: spinnerStyle)
        super.init(frame: .zero)

        let templated = image?.withRenderingMode(.alwaysTemplate)
        button.setImage(templated, for: .normal)
        button.tintColor = tintColor
        button.imageView?.contentMode = .scaleAspectFit
        button.contentEdgeInsets = UIEdgeInsets(top: inset, left: inset,
                                                bottom: inset, right: inset)
        button.adjustsImageWhenHighlighted = true
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false

        spinner.hidesWhenStopped = true
        spinner.color = tintColor
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true

        addSubview(button)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Hide the icon and start the spinner while `loading == true`;
    /// reverse the swap when loading flips back to false. Safe to
    /// call repeatedly with the same value.
    public func setLoading(_ loading: Bool) {
        button.isHidden = loading
        button.isUserInteractionEnabled = !loading
        if loading {
            spinner.startAnimating()
            spinner.isHidden = false
        } else {
            spinner.stopAnimating()
            spinner.isHidden = true
        }
    }

    @objc private func handleTap() { onTap?() }
}
