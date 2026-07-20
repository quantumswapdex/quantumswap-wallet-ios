// AdvancedViewController.swift
// Settings → Advanced hub: Liquidity and Pools. Port of Android
// `AdvancedFragment.java`.

import UIKit

public final class AdvancedViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "colorBackground") ?? .systemBackground
        let L = Localization.shared

        let backBar = makeBackBar(action: #selector(tapBack))
        let title = UILabel()
        title.text = L.lang("advanced", fallback: "Advanced")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        let titleRule = DexScreenChrome.makeDivider()

        let liquidity = DexScreenChrome.makeListRow(
            title: L.lang("adv-liquidity", fallback: "Liquidity"),
            target: self, action: #selector(openLiquidity))
        let pools = DexScreenChrome.makeListRow(
            title: L.lang("adv-pools", fallback: "Pools"),
            target: self, action: #selector(openPools),
            showBottomDivider: false)

        let stack = UIStackView(arrangedSubviews: [
            backBar, title, titleRule, liquidity, pools
        ])
        stack.axis = .vertical
        stack.spacing = 0
        stack.setCustomSpacing(8, after: backBar)
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(8, after: titleRule)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
        view.installPressFeedbackRecursive()
    }

    @objc private func tapBack() {
        (parent as? HomeViewController)?.beginTransactionNow(SettingsViewController())
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
        f.placeholder = placeholder
        f.font = Typography.body(15)
        f.textColor = UIColor(named: "colorCommon6") ?? .label
        f.borderStyle = .roundedRect
        f.keyboardType = keyboard
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return f
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
