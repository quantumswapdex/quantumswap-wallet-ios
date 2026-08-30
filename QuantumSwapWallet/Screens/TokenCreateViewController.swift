// TokenCreateViewController.swift
// Desktop "Create Token" screen (src/app/advanced.ts, Advanced ->
// Tokens) / Android `TokenCreateFragment.java`: Token Name / Symbol /
// Decimals (1..18, default 18) / Total Supply, validation in desktop
// order, screen-level gas chip (2 s debounce on every edit, nothing
// requested until the form validates), one "Deploy token <SYM>" step in
// the tx-steps dialog and an in-dialog result block with the deployed
// contract address (copy + explorer).

import UIKit

public final class TokenCreateViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    private var walletAddress = ""
    private let nameField = DexScreenChrome.makeField(placeholder: "", keyboard: .default)
    private let symbolField = DexScreenChrome.makeField(placeholder: "", keyboard: .asciiCapable)
    private let supplyField = DexScreenChrome.makeField(placeholder: "", keyboard: .decimalPad)
    private let decimalsButton = UIButton(type: .system)
    private var decimals = 18
    private let errorLabel = UILabel()
    private let createButton = GreenPillButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var gasChip: GasChipController?
    private var stepsDialog: TxStepsDialogViewController?
    private var deployedContractAddress: String?

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Transparent so HomeViewController's AmbientBackgroundView
        // (Android body_ambient: violet / cyan orbs over #050508)
        // shows through the whole screen instead of being blacked
        // out by an opaque fill.
        view.backgroundColor = .clear
        let L = Localization.shared
        walletAddress = DexScreenChrome.currentWalletAddress()

        let backBar = makeBackBar(action: #selector(tapBack))
        let title = UILabel()
        title.text = L.lang("create-token", fallback: "Create Token")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        nameField.autocapitalizationType = .words
        nameField.autocorrectionType = .no
        symbolField.autocapitalizationType = .allCharacters
        symbolField.autocorrectionType = .no
        for f in [nameField, symbolField, supplyField] {
            f.addTarget(self, action: #selector(fieldEdited), for: .editingChanged)
        }

        // Desktop: decimals is a 1..18 select defaulting to 18.
        decimalsButton.contentHorizontalAlignment = .leading
        decimalsButton.titleLabel?.font = Typography.body(15)
        decimalsButton.setTitleColor(UIColor(named: "colorCommon6") ?? .label, for: .normal)
        // Android parity: spinner_dropdown_background (r6, transparent
        // fill, 1pt colorCommon6 border, minHeight 44).
        DexScreenChrome.applySpinnerBorder(to: decimalsButton)
        decimalsButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        decimalsButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        decimalsButton.showsMenuAsPrimaryAction = true
        decimalsButton.menu = UIMenu(children: (1...18).map { d in
            UIAction(title: String(d)) { [weak self] _ in
                self?.decimals = d
                self?.decimalsButton.setTitle(String(d), for: .normal)
                self?.scheduleGasEstimate()
            }
        })
        decimalsButton.setTitle("18", for: .normal)

        errorLabel.font = Typography.body(12)
        errorLabel.textColor = UIColor(rgbHex: 0xDC2626)
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        createButton.setTitle(L.lang("create", fallback: "Create"), for: .normal)
        createButton.addTarget(self, action: #selector(tapCreate), for: .touchUpInside)
        // Same footprint as the Send screen's primary button.
        createButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        createButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        spinner.hidesWhenStopped = true
        let chipView = GasChipView()
        gasChip = GasChipController(host: self, walletAddress: walletAddress, chip: chipView, kind: .deployToken)
        let footerSpacer = UIView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = UIStackView(arrangedSubviews: [footerSpacer, spinner, chipView, createButton])
        footer.axis = .horizontal
        footer.spacing = 8
        footer.alignment = .center

        let content = UIStackView(arrangedSubviews: [
            title, DexScreenChrome.makeDivider(),
            DexScreenChrome.makeLabel(L.lang("token-name", fallback: "Token Name")), nameField,
            DexScreenChrome.makeLabel(L.lang("token-symbol", fallback: "Token Symbol")), symbolField,
            DexScreenChrome.makeLabel(L.lang("token-decimals", fallback: "Decimals")), decimalsButton,
            DexScreenChrome.makeLabel(L.lang("token-total-supply", fallback: "Total Supply")), supplyField,
            errorLabel, footer
        ])
        content.axis = .vertical
        content.spacing = 10

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        // Android parity: back arrow above the 22pt gradient card,
        // both scrolling together (center_container screen shell).
        ScreenCard.install(in: scroll, backBar: backBar, content: content)
        view.installPressFeedbackRecursive()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stepsDialog?.dismissSteps()
        stepsDialog = nil
    }

    @objc private func tapBack() {
        (parent as? HomeViewController)?.beginTransactionNow(AdvancedViewController())
    }

    // MARK: - Validation (desktop onCreateTokenClick step A)

    private struct Form {
        let name: String, symbol: String, decimals: Int, supply: String
    }

    /// Returns the validated form or the first error message.
    /// Validation failure carrying the localized message. `Result`
    /// requires an `Error` failure type; a bare `String` does not compile.
    private struct ValidationError: Error { let message: String }

    private func validate() -> Result<Form, ValidationError> {
        let L = Localization.shared
        let name = text(nameField)
        let symbol = text(symbolField)
        let supply = text(supplyField)
        if name.isEmpty || name.count > 48 || Self.containsUnsafeText(name) {
            return .failure(ValidationError(message: L.lang("token-name-invalid", fallback: "Enter a token name (up to 48 plain-text characters).")))
        }
        if symbol.range(of: #"^[A-Za-z0-9]{1,16}$"#, options: .regularExpression) == nil {
            return .failure(ValidationError(message: L.lang("token-symbol-invalid", fallback: "Symbol must be 1-16 letters or digits.")))
        }
        if StablecoinImpersonatorFilter.impersonatesStablecoin(symbol: symbol, name: name) {
            return .failure(ValidationError(message: L.lang("token-impersonator",
                fallback: "This name or symbol is not allowed because it impersonates a stablecoin or fiat currency.")))
        }
        if !Self.isValidSupply(supply, decimals: decimals) {
            return .failure(ValidationError(message: L.lang("token-supply-invalid", fallback: "Enter a valid total supply.")))
        }
        return .success(Form(name: name, symbol: symbol, decimals: decimals, supply: supply))
    }

    /// Desktop containsUnsafeDisplayText: control chars, bidi overrides
    /// and HTML-active characters.
    static func containsUnsafeText(_ s: String) -> Bool {
        s.range(of: #"[\p{Cc}<>&"'`\u{200B}-\u{200F}\u{202A}-\u{202E}\u{2066}-\u{2069}]"#,
                options: .regularExpression) != nil
    }

    /// Desktop parseBaseUnits: plain decimal, fraction no longer than
    /// the token's decimals, value > 0.
    static func isValidSupply(_ supply: String, decimals: Int) -> Bool {
        let cleaned = supply.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard cleaned.range(of: #"^\d+(\.\d*)?$|^\.\d+$"#, options: .regularExpression) != nil else { return false }
        if let dot = cleaned.firstIndex(of: ".") {
            if cleaned.distance(from: cleaned.index(after: dot), to: cleaned.endIndex) > decimals { return false }
        }
        guard let d = Decimal(string: cleaned) else { return false }
        return d > 0
    }

    private func setError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = (message ?? "").isEmpty
    }

    // MARK: - Gas chip (desktop scheduleCreateTokenGasEstimate)

    @objc private func fieldEdited() {
        scheduleGasEstimate()
    }

    private func deployPayload(_ f: Form) -> [String: Any] {
        ["name": f.name, "symbol": f.symbol, "decimals": f.decimals, "totalSupply": f.supply]
    }

    private func scheduleGasEstimate() {
        gasChip?.schedule { [weak self] in
            guard let self, case .success(let form) = self.validate() else { return nil }
            return self.deployPayload(form)
        }
    }

    // MARK: - Create

    @objc private func tapCreate() {
        switch validate() {
        case .failure(let error):
            setError(error.message)
        case .success(let form):
            setError(nil)
            showDeploySteps(form)
        }
    }

    private func showDeploySteps(_ form: Form) {
        let L = Localization.shared
        let stepLabel = L.lang("step-deploy-token", fallback: "Deploy token") + " " + form.symbol
        let base = ReviewSpec()
            .action(L.lang("create-token", fallback: "Create Token") + " " + form.name + " (" + form.symbol + ")")
            .fromAddress(walletAddress)
            .quantityLabelKey("token-total-supply")
            .quantityValue(form.supply + " " + form.symbol)
            .networkText(ReviewSpec.networkText())
        let payload = deployPayload(form)
        let steps = [TxStep(label: stepLabel, kind: .deployToken,
                            estimatePayload: { payload },
                            submitMethod: "tokensSubmitCreate", submitPayload: { payload })]
        deployedContractAddress = nil
        let dlg = TxStepsDialogViewController(
            title: L.lang("create-token-status", fallback: "Create Token Status"),
            walletAddress: walletAddress, steps: steps, baseReview: base)
        dlg.onAllDone = { [weak self] response in
            guard let self else { return nil }
            self.deployedContractAddress = response["contractAddress"] as? String
            return self.buildContractAddressBlock()
        }
        dlg.onClose = { [weak self] in
            guard let self else { return }
            self.stepsDialog = nil
            self.resetForm()
        }
        stepsDialog = dlg
        dlg.show(from: self)
    }

    /// Desktop onAllDone panel inside the steps dialog: bold "Token
    /// contract address" + copy / block-explorer buttons + the full
    /// address (monospace, selectable).
    private func buildContractAddressBlock() -> UIView? {
        guard let addr = deployedContractAddress, !addr.isEmpty else { return nil }
        let L = Localization.shared
        let label = UILabel()
        label.text = L.lang("token-contract-address", fallback: "Token contract address")
        label.font = Typography.boldTitle(13)
        label.textColor = .white
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = IconButton.copyAndExplorer(copyValue: { addr }, explorerUrl: { UrlBuilder.tokenUrl(addr) })
        let header = UIStackView(arrangedSubviews: [label, buttons])
        header.axis = .horizontal
        header.alignment = .center
        let value = ExplorerLinks.makeValueLabel(addr, url: nil, mono: true, size: 11,
                                                 color: UIColor(named: "colorCommon6") ?? .white)
        let wrap = UIStackView(arrangedSubviews: [header, value])
        wrap.axis = .vertical
        wrap.spacing = 4
        return wrap
    }

    private func resetForm() {
        nameField.text = ""
        symbolField.text = ""
        supplyField.text = ""
        decimals = 18
        decimalsButton.setTitle("18", for: .normal)
        setError(nil)
        deployedContractAddress = nil
        gasChip?.reset()
    }

    private func text(_ f: UITextField) -> String {
        f.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
