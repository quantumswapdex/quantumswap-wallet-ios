// MaxHeightScrollView.swift
// Scroll box that wraps its content up to a runtime cap (desktop
// `.blocks-content { max-height: ...; overflow: auto }`): short lists
// take only the space they need, long lists scroll INSIDE the box so
// whatever sits below (the "Add Liquidity" / "Create Pair" links) stays
// visible without scrolling the page. Android reference:
// view/widget/MaxHeightScrollView.java

import UIKit

public final class MaxHeightScrollView: UIScrollView {

    private var capConstraint: NSLayoutConstraint?
    private var wrapConstraint: NSLayoutConstraint?
    private var reserveBelow: CGFloat = 0
    private var hasCap = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        showsVerticalScrollIndicator = true
        let wrap = heightAnchor.constraint(equalTo: contentLayoutGuide.heightAnchor)
        // MUST stay below the content labels' vertical compression
        // resistance (750): at exactly .defaultHigh Auto Layout may
        // satisfy the height cap by crushing the rows (labels squashed
        // to zero, dividers drawn through titles, and no scrolling
        // because contentSize == frame) instead of breaking this wrap.
        // One notch lower guarantees the wrap breaks first, so
        // overflowing content scrolls.
        wrap.priority = .defaultHigh - 1
        wrap.isActive = true
        wrapConstraint = wrap
        let cap = heightAnchor.constraint(lessThanOrEqualToConstant: 100_000)
        cap.priority = .required
        cap.isActive = true
        capConstraint = cap
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Host a vertical stack as the scrolling content.
    public func install(content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor)
        ])
    }

    public func setMaxHeight(_ points: CGFloat) {
        capConstraint?.constant = max(points, 0)
    }

    /// Cap so the box ends `reserveBelow` points above the bottom of
    /// the safe area, based on where the box sits on screen (floor
    /// 120pt). Re-evaluated on every layout pass.
    public func capToScreen(reserveBelow: CGFloat) {
        self.reserveBelow = reserveBelow
        hasCap = true
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard hasCap, let window else { return }
        let top = convert(CGPoint.zero, to: window).y
        let bottomInset = window.safeAreaInsets.bottom
        let avail = window.bounds.height - bottomInset - top - reserveBelow
        let cap = max(avail, 120)
        if abs((capConstraint?.constant ?? 0) - cap) > 0.5 {
            capConstraint?.constant = cap
        }
    }
}

/// List box for panels whose rows can be wider than the screen (pool
/// reserves, position amounts). Wide rows pan sideways on demand
/// ("auto": if the content fits, nothing scrolls horizontally). The
/// box hugs its content height UNTIL the screen-derived cap set by
/// `capToScreen(reserveBelow:)` kicks in; past that the list scrolls
/// vertically INSIDE the box, so the surrounding card's bottom border
/// always stays visible on screen.
public final class AutoHorizontalScrollView: UIScrollView {

    private var capConstraint: NSLayoutConstraint?
    private var reserveBelow: CGFloat = 0
    private var hasCap = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
    }

    required init?(coder: NSCoder) { fatalError() }

    public func install(content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // Hug the content height; MUST stay below the content labels'
        // vertical compression resistance (750) so the cap breaks
        // this wrap (list scrolls) instead of crushing rows.
        let wrap = heightAnchor.constraint(equalTo: contentLayoutGuide.heightAnchor)
        wrap.priority = .defaultHigh - 1
        let cap = heightAnchor.constraint(lessThanOrEqualToConstant: 100_000)
        cap.priority = .required
        capConstraint = cap
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            // Short content still spans the visible width so dividers
            // reach the box edge; wide content grows past it and pans.
            content.widthAnchor.constraint(greaterThanOrEqualTo: frameLayoutGuide.widthAnchor),
            wrap, cap
        ])
    }

    /// Cap so the box (and the card chrome below it) ends
    /// `reserveBelow` points above the bottom of the visible area
    /// (floor 120pt). Re-evaluated on every layout pass.
    public func capToScreen(reserveBelow: CGFloat) {
        self.reserveBelow = reserveBelow
        hasCap = true
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard hasCap else { return }
        // When hosted inside a page-level scroll view, measure the
        // box's position in that scroll view's CONTENT coordinates.
        // Subview frames live in content space, so this number does
        // not change as the page scrolls - unlike the previous
        // window-based math, where scrolling the page up enlarged
        // the computed space, grew the box, and created ever more
        // page scrolling (a feedback loop that pushed the card's
        // bottom border off screen). Sizing the box so the whole
        // page content fits the outer viewport means the page never
        // needs to scroll at all: one scroll bar, inside the box.
        var ancestor = superview
        while let a = ancestor, !(a is UIScrollView) { ancestor = a.superview }
        let avail: CGFloat
        if let outer = ancestor as? UIScrollView {
            // convert(_:to:) lands in the outer scroll view's BOUNDS
            // space, whose origin is the live contentOffset - i.e. it
            // still moves while the page scrolls. Adding the offset
            // back yields the true content-space position, which is
            // fixed, killing the grow-as-you-scroll feedback loop.
            let topInContent = convert(CGPoint.zero, to: outer).y
                + outer.contentOffset.y
            avail = outer.frame.height - outer.adjustedContentInset.bottom
                - topInContent - reserveBelow
        } else if let window {
            let top = convert(CGPoint.zero, to: window).y
            avail = window.bounds.height - window.safeAreaInsets.bottom
                - top - reserveBelow
        } else {
            return
        }
        let cap = max(avail, 120)
        if abs((capConstraint?.constant ?? 0) - cap) > 0.5 {
            capConstraint?.constant = cap
        }
    }
}
