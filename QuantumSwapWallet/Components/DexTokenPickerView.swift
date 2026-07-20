// DexTokenPickerView.swift
// Shared token picker for DEX screens. Lists "Q", recognized wallet
// tokens, and a trailing Custom entry — port of Android
// `TokenPickerController.java`.

import UIKit

public final class DexTokenPickerView: UIView {

    public var onChanged: (() -> Void)?

    private let button = UIButton(type: .system)
    private let customField = UITextField()
    private var tokens: [AccountTokenSummary] = []
    private var selectedIndex: Int = 0
    private var labels: [String] = ["Q"]
    private let customLabel: String

    private var resolvedCustomAddress: String?
    private var resolvedCustomSymbol: String?
    private var resolvedCustomDecimals: Int = 18

    public init(customLabel: String) {
        self.customLabel = customLabel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = Typography.body(15)
        button.setTitleColor(UIColor(named: "colorCommon6") ?? .label, for: .normal)
        button.backgroundColor = (UIColor(named: "colorBackgroundCard") ?? .secondarySystemBackground)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        button.addTarget(self, action: #selector(tapPicker), for: .touchUpInside)

        customField.translatesAutoresizingMaskIntoConstraints = false
        customField.font = Typography.body(14)
        customField.textColor = UIColor(named: "colorCommon6") ?? .label
        customField.borderStyle = .roundedRect
        customField.autocapitalizationType = .none
        customField.autocorrectionType = .no
        customField.isHidden = true
        customField.addTarget(self, action: #selector(customEdited),
            for: .editingChanged)

        let stack = UIStackView(arrangedSubviews: [button, customField])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        rebuildLabels()
        refreshButtonTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Replace cached token list (recognized only) and rebuild the menu.
    public func setTokens(_ list: [AccountTokenSummary]) {
        tokens = list.filter { t in
            guard let addr = t.contractAddress, !addr.isEmpty else { return false }
            return RecognizedTokens.isRecognized(addr)
        }
        selectedIndex = 0
        rebuildLabels()
        refreshButtonTitle()
        customField.isHidden = true
        onChanged?()
    }

    public var isCustomSelected: Bool {
        selectedIndex == tokens.count + 1
    }

    /// `"Q"`, a cached contract address, or trimmed custom input.
    public func tokenValue() -> String {
        if selectedIndex <= 0 { return "Q" }
        if selectedIndex <= tokens.count {
            return tokens[selectedIndex - 1].contractAddress ?? ""
        }
        return customField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func decimals() -> Int {
        if selectedIndex <= 0 { return 18 }
        if selectedIndex <= tokens.count {
            return tokens[selectedIndex - 1].decimals ?? 18
        }
        if metaResolvedForCurrentCustom() { return resolvedCustomDecimals }
        return 18
    }

    public func symbol() -> String {
        if selectedIndex <= 0 { return "Q" }
        if selectedIndex <= tokens.count {
            let s = tokens[selectedIndex - 1].symbol ?? ""
            return s.isEmpty ? shortValue() : s
        }
        if metaResolvedForCurrentCustom(),
        let s = resolvedCustomSymbol, !s.isEmpty {
            return s
        }
        return shortValue()
    }

    public func needsMetadata() -> Bool {
        isCustomSelected && !metaResolvedForCurrentCustom()
    }

    public func setResolvedMeta(address: String, symbol: String, decimals: Int) {
        resolvedCustomAddress = address.lowercased()
        resolvedCustomSymbol = symbol
        resolvedCustomDecimals = decimals
    }

    // MARK: - Private

    private func rebuildLabels() {
        labels = ["Q"]
        for t in tokens {
            let sym = t.symbol ?? ""
            let addr = t.contractAddress ?? ""
            let short = DexBridgeResult.shortAddr(addr)
            labels.append(sym.isEmpty ? short : "\(sym) (\(short))")
        }
        labels.append(customLabel)
    }

    private func refreshButtonTitle() {
        let title = (selectedIndex >= 0 && selectedIndex < labels.count)
            ? labels[selectedIndex] : "Q"
        button.setTitle(title + "  ▾", for: .normal)
    }

    private func shortValue() -> String {
        DexBridgeResult.shortAddr(tokenValue())
    }

    private func metaResolvedForCurrentCustom() -> Bool {
        guard let resolved = resolvedCustomAddress else { return false }
        return resolved.caseInsensitiveCompare(tokenValue()) == .orderedSame
    }

    @objc private func customEdited() {
        onChanged?()
    }

    @objc private func tapPicker() {
        let sheet = UIAlertController(title: nil, message: nil,
            preferredStyle: .actionSheet)
        for (i, label) in labels.enumerated() {
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                guard let self else { return }
                self.selectedIndex = i
                self.customField.isHidden = !self.isCustomSelected
                self.refreshButtonTitle()
                self.onChanged?()
            })
        }
        sheet.addAction(UIAlertAction(
            title: Localization.shared.getCancelByLangValues(),
            style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = button
            pop.sourceRect = button.bounds
        }
        nearestViewController()?.present(sheet, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var r: UIResponder? = self
        while let cur = r {
            if let vc = cur as? UIViewController { return vc }
            r = cur.next
        }
        return nil
    }
}
