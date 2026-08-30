// ChromeViews.swift
// Home chrome ported from the desktop app / Android `home_activity.xml`:
//   - TopBannerView: header band (#EB020205 + 1pt #14FFFFFF hairline)
//     holding the burger button, the brand row (logo mark + gradient
//     wordmark) and the network chip. Band height = content + a
//     per-screen bottom padding (68pt home so the wallet card overlaps
//     it by 56pt, 12pt elsewhere).
//   - CenterStripView: the wallet card (center_container gradient, 22pt
//     radius) with address, copy / explorer / refresh, balance and the
//     four glass action tiles (Send / Receive / Transactions / Swap).
//   - OfflineOverlayView: unchanged.
// The bottom navigation was replaced by the burger drawer (DrawerView).

import UIKit

// MARK: - Top banner

public final class TopBannerView: UIView {

    public var onBurgerTap: (() -> Void)?

    private let burgerButton = UIButton(type: .custom)
    private let brandRow = UIStackView()
    private let logoView = LogoMarkView()
    private let titleLabel = GradientWordmarkLabel()
    private let hairline = UIView()

    public let networkChipContainer = UIView()

    private var bottomPadding: NSLayoutConstraint?
    /// Required height pin: banner bottom == safe-area top + 12
    /// (brand-row top gap) + 34 (brand-row height) + band padding.
    /// Makes the banner's height rigid so a constraint conflict
    /// anywhere else on the screen can never balloon the band -
    /// Auto Layout must break an optional in the hosted child
    /// (which then stretches correctly) instead.
    private var heightPin: NSLayoutConstraint?
    private var brandLeading: NSLayoutConstraint?
    private var brandCenter: NSLayoutConstraint?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(argbHex: 0xEB020205)
        installContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func installContent() {
        // Burger (Android imageButton_home_burger / burger_button_bg).
        burgerButton.setImage(BurgerIcon.image(), for: .normal)
        burgerButton.backgroundColor = UIColor(argbHex: 0x0AFFFFFF)
        burgerButton.layer.cornerRadius = 9
        burgerButton.layer.borderWidth = 1
        burgerButton.layer.borderColor = UIColor(argbHex: 0x21FFFFFF).cgColor
        burgerButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        burgerButton.accessibilityLabel = Localization.shared.getWalletsByLangValues()
        burgerButton.addAction(UIAction { [weak self] _ in self?.onBurgerTap?() }, for: .touchUpInside)
        burgerButton.addAction(UIAction { [weak self] _ in
            self?.burgerButton.backgroundColor = UIColor(argbHex: 0x14FFFFFF) }, for: .touchDown)
        burgerButton.addAction(UIAction { [weak self] _ in
            self?.burgerButton.backgroundColor = UIColor(argbHex: 0x0AFFFFFF) },
            for: [.touchUpInside, .touchUpOutside, .touchCancel])

        // Brand row: 34pt mark + 10pt gap + 21pt bold gradient wordmark.
        titleLabel.text = Localization.shared.getTitleByLangValues()
        titleLabel.font = Typography.boldTitle(21)
        titleLabel.textColor = .white
        brandRow.axis = .horizontal
        brandRow.alignment = .center
        brandRow.spacing = 10
        brandRow.addArrangedSubview(logoView)
        brandRow.addArrangedSubview(titleLabel)

        hairline.backgroundColor = UIColor(argbHex: 0x14FFFFFF)

        [burgerButton, brandRow, networkChipContainer, hairline].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        let pad = brandRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -68)
        bottomPadding = pad
        let hp = bottomAnchor.constraint(
            equalTo: safeAreaLayoutGuide.topAnchor, constant: 12 + 34 + 68)
        heightPin = hp
        hp.isActive = true
        let center = brandRow.centerXAnchor.constraint(equalTo: centerXAnchor)
        center.priority = .defaultHigh
        brandCenter = center
        let lead = brandRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 56)
        lead.priority = .defaultHigh
        lead.isActive = false
        brandLeading = lead

        NSLayoutConstraint.activate([
            burgerButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            burgerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            burgerButton.widthAnchor.constraint(equalToConstant: 36),
            burgerButton.heightAnchor.constraint(equalToConstant: 36),

            logoView.widthAnchor.constraint(equalToConstant: 34),
            logoView.heightAnchor.constraint(equalToConstant: 34),
            brandRow.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            center,
            pad,

            networkChipContainer.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            networkChipContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Overlap guard (Android brand-row OnGlobalLayoutListener): if the
        // centered brand would collide with the burger (56pt) or the
        // network chip (8pt gap), left-align it with a 56pt start inset.
        let chipHidden = networkChipContainer.subviews.first?.isHidden ?? true
        let chipLeft = chipHidden ? bounds.width : networkChipContainer.frame.minX
        let overlaps = brandRow.frame.minX < 56 || brandRow.frame.maxX > chipLeft - 8
        let wantLeading = overlaps && !(burgerButton.isHidden && chipHidden)
        if wantLeading != (brandLeading?.isActive ?? false) {
            brandCenter?.isActive = !wantLeading
            brandLeading?.isActive = wantLeading
            setNeedsLayout()
        }
    }

    /// Android HomeActivity.setBandBottomPadding: 68 (home, the wallet
    /// card overlaps by 56) / 12 (sub-screens, start).
    public func setBandBottomPadding(_ points: CGFloat) {
        bottomPadding?.constant = -max(0, points)
        heightPin?.constant = 12 + 34 + max(0, points)
    }

    public func setBurgerHidden(_ hidden: Bool) {
        burgerButton.isHidden = hidden
    }

    public func setNetworkChipView(_ chip: UIView) {
        chip.removeFromSuperview()
        chip.translatesAutoresizingMaskIntoConstraints = false
        networkChipContainer.subviews.forEach { $0.removeFromSuperview() }
        networkChipContainer.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.topAnchor.constraint(equalTo: networkChipContainer.topAnchor),
            chip.bottomAnchor.constraint(equalTo: networkChipContainer.bottomAnchor),
            chip.leadingAnchor.constraint(equalTo: networkChipContainer.leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: networkChipContainer.trailingAnchor)
        ])
    }
}

// MARK: - Center strip

/// The wallet card (Android center_relative_layout_home_id on
/// center_container.xml): address (14pt monospace), copy / explorer /
/// refresh, balance (green placeholder), hairline, four glass tiles.
public final class CenterStripView: UIView {

    public var onSend: (() -> Void)?
    public var onReceive: (() -> Void)?
    public var onTransactions: (() -> Void)?
    public var onSwap: (() -> Void)?
    public var onRefresh: (() -> Void)?
    public var onExploreAddress: (() -> Void)?

    public var currentAddress: String = "" { didSet { addressLabel.text = currentAddress } }

    private let cardView = CenterContainerView()
    private let addressLabel = UILabel()
    private let balanceLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let exploreButton = UIButton(type: .system)
    private let refreshSwap = RefreshIconSwap(image: UIImage(named: "retry"))

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)

        addressLabel.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        addressLabel.textColor = UIColor(named: "colorCommon6") ?? .label
        addressLabel.numberOfLines = 2
        addressLabel.lineBreakMode = .byCharWrapping
        addressLabel.textAlignment = .center

        balanceLabel.font = Typography.body(20)
        balanceLabel.textColor = .quantumGreen
        balanceLabel.text = CoinUtils.UNKNOWN_BALANCE_PLACEHOLDER

        configureIcon(copyButton, image: "copy_outline", inset: 5, action: #selector(tapCopy))
        configureIcon(exploreButton, image: "address_explore", inset: 5, action: #selector(tapExplore))
        refreshSwap.onTap = { [weak self] in self?.onRefresh?() }
        refreshSwap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            refreshSwap.widthAnchor.constraint(equalToConstant: 40),
            refreshSwap.heightAnchor.constraint(equalToConstant: 40)
        ])

        let iconRow = UIStackView(arrangedSubviews: [copyButton, exploreButton, refreshSwap])
        iconRow.axis = .horizontal
        iconRow.spacing = 24
        iconRow.alignment = .center

        let cardRow = makeActionRow()

        let balanceRule = UIView()
        balanceRule.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        balanceRule.translatesAutoresizingMaskIntoConstraints = false
        balanceRule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let stack = UIStackView(arrangedSubviews: [addressLabel, iconRow, balanceLabel, balanceRule, cardRow])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(stack)
        stack.setCustomSpacing(20, after: balanceLabel)
        stack.setCustomSpacing(20, after: balanceRule)
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            addressLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            addressLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            balanceRule.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cardRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            cardRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])

        installPressFeedbackRecursive()
    }
    required init?(coder: NSCoder) { fatalError() }

    public func setBalance(_ text: String) { balanceLabel.text = text }
    public func setBalance(loading: Bool) {
        refreshSwap.setLoading(loading)
    }

    public func refreshBalanceLoadingAppearanceIfNeeded() {
        refreshSwap.setLoading(refreshSwap.isShowingLoading)
    }

    public func setRefreshEnabled(_ enabled: Bool) {
        refreshSwap.isEnabled = enabled
    }

    @objc private func tapCopy() {
        Pasteboard.copySensitive(currentAddress)
        Toast.showMessage(Localization.shared.getCopiedByLangValues())
    }
    @objc private func tapExplore() { onExploreAddress?() }
    @objc private func tapSend() { onSend?() }
    @objc private func tapReceive() { onReceive?() }
    @objc private func tapTransactions() { onTransactions?() }
    @objc private func tapSwap() { onSwap?() }

    private func configureIcon(_ b: UIButton, image name: String, inset: CGFloat, action: Selector) {
        let img = UIImage(named: name)?.withRenderingMode(.alwaysTemplate)
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.imageView?.contentMode = .scaleAspectFit
        b.contentEdgeInsets = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 40),
            b.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    /// Desktop action tiles: glass fills amber / emerald / blue / magenta
    /// with 1pt strokes and white icons (Android tile_press_overlay).
    private func makeActionRow() -> UIStackView {
        let L = Localization.shared
        let send = makeCardActionButton(icon: "arrow_up", fill: 0x24F59E0B, stroke: 0x99F59E0B,
                                        iconInset: 13, title: L.getSendByLangValues(), action: #selector(tapSend))
        let recv = makeCardActionButton(icon: "arrow_down_outline", fill: 0x2410B981, stroke: 0x9910B981,
                                        iconInset: 15, title: L.getReceiveByLangValues(), action: #selector(tapReceive))
        let txn = makeCardActionButton(icon: "document", fill: 0x243B82F6, stroke: 0x993B82F6,
                                       iconInset: 15, title: L.getTransactionsByLangValues(), action: #selector(tapTransactions))
        let swap = makeCardActionButton(icon: nil, fill: 0x24D946EF, stroke: 0x99D946EF,
                                        iconInset: 15, title: L.lang("swap", fallback: "Swap"), action: #selector(tapSwap))
        let row = UIStackView(arrangedSubviews: [send, recv, txn, swap])
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    private func makeCardActionButton(icon: String?, fill: UInt32, stroke: UInt32, iconInset: CGFloat,
                                      title: String, action: Selector) -> UIView {
        let card = TileControl()
        card.baseFill = UIColor(argbHex: fill)
        card.backgroundColor = UIColor(argbHex: fill)
        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(argbHex: stroke).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addTarget(self, action: action, for: .touchUpInside)
        let image = icon.flatMap { UIImage(named: $0) } ?? UIImage(systemName: "arrow.left.arrow.right")
        let iv = UIImageView(image: image?.withRenderingMode(.alwaysTemplate))
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iv)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 64),
            card.widthAnchor.constraint(equalToConstant: 64),
            iv.topAnchor.constraint(equalTo: card.topAnchor, constant: iconInset),
            iv.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -iconInset),
            iv.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: iconInset),
            iv.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -iconInset)
        ])

        let label = UILabel()
        label.text = title
        label.font = Typography.body(12)
        label.textColor = UIColor(named: "colorCommon6") ?? .white // Android tile label colorCommon6
        label.textAlignment = .center

        let col = UIStackView(arrangedSubviews: [card, label])
        col.axis = .vertical
        col.alignment = .center
        col.spacing = 4
        return col
    }
}

/// Android tile_press_overlay: #26FFFFFF overlay while pressed.
final class TileControl: UIControl {
    var baseFill: UIColor = .clear
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
                ? baseFill.blended(with: UIColor(argbHex: 0x26FFFFFF)) : baseFill
        }
    }
}

private extension UIColor {
    func blended(with top: UIColor) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        top.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let a = a2 + a1 * (1 - a2)
        guard a > 0 else { return .clear }
        return UIColor(red: (r2 * a2 + r1 * a1 * (1 - a2)) / a,
                       green: (g2 * a2 + g1 * a1 * (1 - a2)) / a,
                       blue: (b2 * a2 + b1 * a1 * (1 - a2)) / a, alpha: a)
    }
}

// MARK: - Offline overlay

public final class OfflineOverlayView: UIView {

    private let label = UILabel()
    private let retry = UIButton(type: .system)

    public var onRetry: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(named: "colorBackground")?.withAlphaComponent(0.97)
        ?? UIColor.systemBackground.withAlphaComponent(0.97)
        label.font = Typography.body(14)
        label.textAlignment = .center
        label.numberOfLines = 0
        retry.setTitle(Localization.shared.getOkByLangValues(), for: .normal)
        retry.addTarget(self, action: #selector(tapRetry), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
            ])
        isHidden = true

        installPressFeedbackRecursive()
    }
    required init?(coder: NSCoder) { fatalError() }

    public func configure(isNetworkError: Bool) {
        let L = Localization.shared
        label.text = isNetworkError ? L.getErrorOccurredByLangValues() : L.getErrorTitleByLangValues()
    }

    @objc private func tapRetry() { onRetry?() }
}
