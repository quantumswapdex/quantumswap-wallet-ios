// AdvancedViewController.swift
// Settings → Advanced hub: Liquidity and Pools. Port of Android
// `AdvancedFragment.java`.

import UIKit

public final class AdvancedViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Transparent so HomeViewController's AmbientBackgroundView
        // (Android body_ambient: violet / cyan orbs over #050508)
        // shows through the whole screen instead of being blacked
        // out by an opaque fill.
        view.backgroundColor = .clear
        let L = Localization.shared

        let backBar = makeBackBar(action: #selector(tapBack))
        let title = UILabel()
        title.text = L.lang("advanced", fallback: "Advanced")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        let titleRule = DexScreenChrome.makeDivider()

        // Desktop order: Tokens, Liquidity, Pools.
        let tokens = DexScreenChrome.makeListRow(
            title: L.lang("adv-tokens", fallback: "Tokens"),
            target: self, action: #selector(openTokens))
        let liquidity = DexScreenChrome.makeListRow(
            title: L.lang("adv-liquidity", fallback: "Liquidity"),
            target: self, action: #selector(openLiquidity))
        let pools = DexScreenChrome.makeListRow(
            title: L.lang("adv-pools", fallback: "Pools"),
            target: self, action: #selector(openPools),
            showBottomDivider: false)

        let stack = UIStackView(arrangedSubviews: [
            title, titleRule, tokens, liquidity, pools
        ])
        stack.axis = .vertical
        stack.spacing = 0
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(8, after: titleRule)
        // Android parity: back arrow above the 22pt gradient card
        // (center_container screen shell; content is short, no scroll).
        ScreenCard.installUnscrolled(in: view, backBar: backBar, content: stack)
        view.installPressFeedbackRecursive()
    }

    /// Advanced is a top-level drawer entry: back returns Home.
    @objc private func tapBack() {
        (parent as? HomeViewController)?.showMain()
    }

    @objc private func openTokens() {
        (parent as? HomeViewController)?.beginTransactionNow(TokenCreateViewController())
    }

    @objc private func openLiquidity() {
        (parent as? HomeViewController)?.beginTransactionNow(LiquidityViewController())
    }

    @objc private func openPools() {
        (parent as? HomeViewController)?.beginTransactionNow(PoolsViewController())
    }
}

// MARK: - Shared chrome for DEX screens

enum DexScreenChrome {

    static func makeDivider() -> UIView {
        let v = UIView()
        v.backgroundColor =
            (UIColor(named: "colorRectangleLine") ?? .separator).withAlphaComponent(0.4)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    static func makeListRow(title: String, target: Any?, action: Selector,
        showBottomDivider: Bool = true) -> UIControl {
        let row = UIControl()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 48).isActive = true
        row.addTarget(target, action: action, for: .touchUpInside)

        let label = UILabel()
        label.text = title
        label.font = Typography.body(15)
        label.textColor = UIColor(named: "colorCommon6") ?? .label
        label.translatesAutoresizingMaskIntoConstraints = false

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = UIColor(named: "colorCommon4") ?? .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false

        [label, chevron].forEach { row.addSubview($0) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 16)
        ])
        if showBottomDivider {
            let divider = UIView()
            divider.backgroundColor =
                (UIColor(named: "colorRectangleLine") ?? .separator).withAlphaComponent(0.4)
            divider.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(divider)
            NSLayoutConstraint.activate([
                divider.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                divider.heightAnchor.constraint(equalToConstant: 0.5)
            ])
        }
        return row
    }

    /// Bold 14pt colorCommon1 field heading (Android textView_*_label).
    static func makeHeading(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = Typography.boldTitle(14)
        l.textColor = UIColor(named: "colorCommon1") ?? .label
        return l
    }

    /// Teal text link (Android textView_*_link / drawer_item_bg): 15pt
    /// quantumTeal, underlined when `underline`, padded tap target.
    static func makeLink(_ text: String, size: CGFloat = 15, underline: Bool = false,
                         target: Any?, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        let attrs: [NSAttributedString.Key: Any] = underline
            ? [.font: Typography.body(size), .foregroundColor: UIColor.quantumTeal,
               .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [.font: Typography.body(size), .foregroundColor: UIColor.quantumTeal]
        b.setAttributedTitle(NSAttributedString(string: text, attributes: attrs), for: .normal)
        b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        b.addTarget(target, action: action, for: .touchUpInside)
        return b
    }

    static func makeLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = Typography.body(13)
        l.textColor = UIColor(named: "colorCommon6") ?? .label
        return l
    }

    static func makeField(placeholder: String,
        keyboard: UIKeyboardType = .decimalPad) -> UITextField {
        let f = UITextField()
        f.attributedPlaceholder = hintAttributed(placeholder, font: Typography.body(15))
        f.font = Typography.body(15)
        f.textColor = UIColor(named: "colorCommon6") ?? .label
        // Android parity: EditTexts use text_input_selector - no box,
        // just a bottom hairline (see applyUnderline).
        f.borderStyle = .none
        applyUnderline(to: f)
        f.keyboardType = keyboard
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return f
    }

    /// Android `text_input_selector` look: no box chrome, just a
    /// 0.5pt bottom hairline in colorCommon6 (#E0E0E6). Works for
    /// UITextField and UITextView alike.
    static func applyUnderline(to control: UIView) {
        (control as? UITextField)?.borderStyle = .none
        control.layer.borderWidth = 0
        control.layer.cornerRadius = 0
        control.backgroundColor = .clear
        let hairline = UIView()
        hairline.backgroundColor = UIColor(named: "colorCommon6") ?? .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: control.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    /// Placeholder / hint text in Android colorMutedSecondaryText.
    static func hintAttributed(_ text: String, font: UIFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(rgbHex: 0x9A9AA6)
        ])
    }

    /// Android `spinner_dropdown_background`: 6pt radius, transparent
    /// fill, 1pt colorCommon6 border. Used for dropdown-style buttons
    /// (Send asset picker, TokenCreate decimals).
    static func applySpinnerBorder(to control: UIView) {
        control.backgroundColor = .clear
        control.layer.cornerRadius = 6
        control.layer.borderWidth = 1
        control.layer.borderColor = (UIColor(named: "colorCommon6") ?? .separator).cgColor
    }

    static func currentWalletAddress() -> String {
        let idx = PrefConnect.shared.readInt(
            PrefKeys.WALLET_CURRENT_ADDRESS_INDEX_KEY, default: 0)
        return Strongbox.shared.address(forIndex: idx) ?? ""
    }

    static func presentError(from host: UIViewController, message: String) {
        let L = Localization.shared
        let dlg = MessageInformationDialogViewController.error(
            title: L.getErrorTitleByLangValues(),
            message: L.getErrorOccurredByLangValues() + DexBridgeResult.sanitizeError(message))
        host.present(dlg, animated: true)
    }

    /// Every account token that survives the stablecoin-impersonator
    /// filter (recognized AND unrecognized); the token picker partitions
    /// them itself.
    static func loadAccountTokens(for address: String) async -> [AccountTokenSummary] {
        do {
            let resp = try await AccountsApi.accountTokens(address: address, pageIndex: 1)
            return StablecoinImpersonatorFilter.filter(resp.result ?? [])
        } catch {
            return []
        }
    }

    /// Resolve a custom / placeholder picker row's decimals + symbol
    /// through swapGetTokenMetadata (no-op when already known).
    static func resolveMeta(_ picker: DexTokenPickerView, walletAddress: String) async throws {
        guard picker.needsMetadata() else { return }
        let addr = picker.tokenValue()
        var payload = DexPayloads.base()
        payload["contractAddress"] = addr
        payload["ownerAddress"] = walletAddress
        let json = try await JsBridge.shared.dexCallAsync(method: "swapGetTokenMetadata", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        let symbol = (data["symbol"] as? String) ?? ""
        let decimals = (data["decimals"] as? Int) ?? (data["decimals"] as? NSNumber)?.intValue ?? 18
        let contract = (data["contractAddress"] as? String) ?? addr
        await MainActor.run {
            picker.setResolvedMeta(address: contract, symbol: symbol, decimals: decimals)
        }
    }

    /// "Q" -> the active release's wrapped-Q contract (what the bridge
    /// maps it to); otherwise the address as-is.
    static func resolveTokenContract(_ tokenValue: String, release: ReleaseStore.Release) -> String {
        tokenValue == "Q" ? release.wq : tokenValue
    }

    static func loadRecognizedTokens(for address: String) async -> [AccountTokenSummary] {
        do {
            let resp = try await AccountsApi.accountTokens(address: address, pageIndex: 1)
            let filtered = StablecoinImpersonatorFilter.filter(resp.result ?? [])
            return filtered.filter { RecognizedTokens.isRecognized($0.contractAddress) }
        } catch {
            return []
        }
    }
}
