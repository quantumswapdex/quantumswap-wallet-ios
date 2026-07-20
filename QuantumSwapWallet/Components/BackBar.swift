// BackBar.swift
// Shared 44pt-tall back-arrow row used at the top of secondary
// screens (Networks, Add Network, Settings, etc.). Promoted out of
// `BlockchainNetworkViewController.swift` so any UIViewController
// that needs the same chrome can call `makeBackBar(action:)` without
// re-implementing the same image button + spacer pattern.
// Visual + tap behaviour mirror Android `imageButton_*_back_arrow`:
// 32x32 templated `arrow_back_circle_outline` tinted to
// `colorCommon6`, with a leading position and a flexible spacer so
// any title text added to the same row trails to the right.

import UIKit

/// Lightweight wrapper returned by `makeBackBar(backAction:refreshAction:)`
/// when a refresh slot is requested. Callers attach refresh callbacks
/// via the exposed `RefreshIconSwap` reference so the icon/spinner
/// can swap in place while the async refresh is in flight.
public final class BackBarRow: UIStackView {
    /// Refresh swap when the bar was built with a refresh slot.
    /// `nil` when the row only carries the back button.
    public weak var refreshSwap: RefreshIconSwap?
}

internal extension UIViewController {
    /// 44pt-tall row containing a 32x32 back-arrow image button on the
    /// leading edge. The supplied selector is wired to `self` via
    /// `addTarget(_:action:for:)`.
    func makeBackBar(action: Selector) -> BackBarRow {
        return makeBackBar(backAction: action, refreshAction: nil)
    }

    /// 44pt-tall row containing a 32x32 back-arrow image button on the
    /// leading edge, optionally followed by a 32x32 refresh slot.
    /// Mirrors the Android `top_linear_layout_account_transactions_id`
    /// row from `account_transactions_fragment.xml`, where back +
    /// refresh sit side by side with a flexible spacer trailing. The
    /// refresh slot uses `RefreshIconSwap` so the icon disappears
    /// while the async work runs and reappears on completion - the
    /// same in-place swap Android applies via `ProgressBar` toggling.
    /// `backAction` and `refreshAction` selectors target `self`.
    func makeBackBar(backAction: Selector,
        refreshAction: Selector?) -> BackBarRow {
        let row = BackBarRow()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let back = makeChromeImageButton(
            named: "arrow_back_circle_outline",
            action: backAction)
        row.addArrangedSubview(back)

        if let refreshAction = refreshAction {
            let swap = RefreshIconSwap(
                image: UIImage(named: "retry"),
                inset: 0,
                tintColor: UIColor(named: "colorCommon6") ?? .label)
            swap.translatesAutoresizingMaskIntoConstraints = false
            swap.widthAnchor.constraint(equalToConstant: 32).isActive = true
            swap.heightAnchor.constraint(equalToConstant: 32).isActive = true
            // Forward taps to the supplied selector via a trampoline
            // closure - the swap exposes a closure-based callback
            // because the inner button needs the spinner-swap
            // bookkeeping, not a bare `addTarget`.
            let trampoline = RefreshTrampoline(target: self, action: refreshAction)
            swap.onTap = { [weak trampoline] in trampoline?.fire() }
            // Retain the trampoline by attaching it to the swap's
            // associated objects so it lives as long as the bar.
            objc_setAssociatedObject(swap,
                &BackBarKeys.trampoline,
                trampoline,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            row.addArrangedSubview(swap)
            row.refreshSwap = swap
        }

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    /// 32x32 templated image button tinted to `colorCommon6`. Shared by
    /// the back / refresh slots in `makeBackBar(backAction:refreshAction:)`.
    private func makeChromeImageButton(named: String, action: Selector) -> UIButton {
        let b = UIButton(type: .custom)
        let img = UIImage(named: named)?
        .withRenderingMode(.alwaysTemplate)
        b.setImage(img, for: .normal)
        b.tintColor = UIColor(named: "colorCommon6") ?? .label
        b.adjustsImageWhenHighlighted = true
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }
}

private enum BackBarKeys {
    static var trampoline: UInt8 = 0
}

/// Tiny ObjC trampoline that forwards a closure invocation to a
/// `target` / `Selector` pair. Lives only as long as the swap that
/// retains it. Mirrors the pattern used for `UIControl` action
/// dispatch on closures.
private final class RefreshTrampoline: NSObject {
    weak var target: AnyObject?
    let action: Selector
    init(target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
    }
    func fire() {
        guard let target = target else { return }
        _ = target.perform(action, with: nil)
    }
}
