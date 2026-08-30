// SwapViewController.swift
// Desktop swap form (src/app/swap.ts) / Android `SwapFragment.java`:
//   - two token pickers (no Q preselect; the "To" picker always lists
//     the recognized allow-list);
//   - From / To boxes (balance row + editable amount) and the flip
//     button appear only once BOTH tokens are selected;
//   - bidirectional quote with a 400 ms debounce (swapGetAmountsOut /
//     swapGetAmountsIn); tapping a balance fills that side;
//   - route line "Route: A > B > C";
//   - Next -> allowance check -> tx-steps dialog [Approve FROM]? [Swap
//     FROM -> TO] with per-step gas estimate, review (+ "i agree" ->
//     unlock) and scan-API confirmation.

import UIKit

public final class SwapViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    private static let quoteDebounceMs: UInt64 = 400

    private var walletAddress = ""
    private var fromPicker: DexTokenPickerView!
    private var toPicker: DexTokenPickerView!
    private let fromBox = UIStackView()
    private let toBox = UIStackView()
    private let flipRow = UIStackView()
    private let fromBalanceButton = UIButton(type: .system)
    private let toBalanceButton = UIButton(type: .system)
    private let amountInField = DexScreenChrome.makeField(placeholder: "", keyboard: .decimalPad)
    private let amountOutField = DexScreenChrome.makeField(placeholder: "", keyboard: .decimalPad)
    private let slippageField = DexScreenChrome.makeField(placeholder: "1", keyboard: .decimalPad)
    private let routeLabel = UILabel()
    private let statusLabel = UILabel()
    private let nextButton = GreenPillButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var lastQuotedAmountOut: String?
    /// Which side the user typed last (web-app lastEdited): From ->
    /// exact-in, To -> exact-out. Wrap / unwrap and fee-on-transfer
    /// pairs are always exact-in, see `isExactOut()`.
    private var lastEditedFromSide = true
    /// Exact-out quote: the required input and the most that may be
    /// spent (quote plus slippage), as returned by swapGetAmountsIn.
    private var lastQuotedAmountIn: String?
    private var lastQuotedAmountInMax: String?
    /// Set when the estimate reported an exact-in fallback: the steps
    /// dialog closes and the close handler re-quotes exact-in from the
    /// quoted input instead of clearing the amounts.
    private var restartAsExactIn = false
    /// The path the last quote priced (web-app routePath): sent with the
    /// swap payload so estimate and submit build the same route.
    private var lastQuotedPath: [String]?
    /// "router" (re-quoted on-chain) or "api-estimate" (indexed reserves).
    private var lastQuoteSource = ""
    private var lastQuoteIndexedBlock: Int64 = 0
    private let quoteSourceLabel = UILabel()
    private var flowInFlight = false
    private var syncingAmounts = false
    private var quoteTask: Task<Void, Never>?
    private var stepsDialog: TxStepsDialogViewController?

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
        title.text = L.lang("swap", fallback: "Swap")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        let releaseBanner = UILabel()
        releaseBanner.font = Typography.body(12)
        releaseBanner.textColor = UIColor(rgbHex: 0xFBBF24) // Android quantumAmber
        releaseBanner.numberOfLines = 0
        let active = ReleaseStore.readActive()
        if !active.builtin {
            releaseBanner.text = L.lang("custom-release-banner-prefix",
                fallback: "Custom release contracts: ") + active.name
        } else {
            releaseBanner.isHidden = true
        }

        let customLabel = L.lang("custom-contract-address", fallback: "Custom...")
        fromPicker = DexTokenPickerView(customLabel: customLabel, preselectNative: false,
                                        alwaysIncludeRecognized: false)
        toPicker = DexTokenPickerView(customLabel: customLabel, preselectNative: false,
                                      alwaysIncludeRecognized: true)
        fromPicker.onChanged = { [weak self] in self?.onTokensChanged() }
        toPicker.onChanged = { [weak self] in self?.onTokensChanged() }

        buildBox(fromBox, balanceButton: fromBalanceButton, field: amountInField, fromSide: true)
        buildBox(toBox, balanceButton: toBalanceButton, field: amountOutField, fromSide: false)

        // Flip button (desktop swap-flip): 40pt oval.
        let flip = UIButton(type: .custom)
        flip.setImage(UIImage(systemName: "arrow.up.arrow.down")?.withRenderingMode(.alwaysTemplate), for: .normal)
        flip.tintColor = .white
        flip.backgroundColor = UIColor(rgbHex: 0x1C1F2F)
        flip.layer.cornerRadius = 20
        flip.layer.borderWidth = 1
        flip.layer.borderColor = UIColor(argbHex: 0x99917DCF).cgColor
        flip.widthAnchor.constraint(equalToConstant: 40).isActive = true
        flip.heightAnchor.constraint(equalToConstant: 40).isActive = true
        flip.addTarget(self, action: #selector(flipTokens), for: .touchUpInside)
        flipRow.axis = .horizontal
        flipRow.alignment = .center
        flipRow.addArrangedSubview(UIView())
        flipRow.addArrangedSubview(flip)
        flipRow.addArrangedSubview(UIView())
        flipRow.distribution = .equalCentering

        slippageField.text = "1"
        // Slippage feeds the exact-out maximum, so re-quote the last side.
        slippageField.addAction(UIAction { [weak self] _ in self?.slippageEdited() }, for: .editingChanged)

        routeLabel.font = Typography.body(12)
        routeLabel.textColor = UIColor(rgbHex: 0x9A9AA6) // Android colorMutedSecondaryText
        routeLabel.numberOfLines = 0
        routeLabel.isHidden = true

        quoteSourceLabel.font = Typography.body(12)
        quoteSourceLabel.textColor = UIColor(rgbHex: 0x9A9AA6) // Android colorMutedSecondaryText
        quoteSourceLabel.numberOfLines = 0
        quoteSourceLabel.isHidden = true

        statusLabel.font = Typography.body(12)
        statusLabel.textColor = UIColor(rgbHex: 0xFBBF24) // Android quantumAmber
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        nextButton.setTitle(L.lang("next", fallback: "Next"), for: .normal)
        nextButton.addTarget(self, action: #selector(tapNext), for: .touchUpInside)
        // Same footprint as Send's primary button (43pt tall, >=96pt
        // wide) so the CTA reads at regular size instead of hugging
        // the short "Next" title.
        nextButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        nextButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        spinner.hidesWhenStopped = true
        let footerSpacer = UIView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = UIStackView(arrangedSubviews: [footerSpacer, spinner, nextButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .center

        // Slippage row: the field is capped to ~4 characters' width
        // (56pt covers 4 digits at body(15) plus the roundedRect
        // insets) with a trailing "%" unit label; the spacer absorbs
        // the remaining row width so the field stays left-aligned.
        slippageField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let percentLabel = UILabel()
        percentLabel.text = "%"
        percentLabel.font = Typography.body(15)
        percentLabel.textColor = UIColor(named: "colorCommon6") ?? .label
        let slippageSpacer = UIView()
        slippageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let slippageRow = UIStackView(arrangedSubviews: [slippageField, percentLabel, slippageSpacer])
        slippageRow.axis = .horizontal
        slippageRow.spacing = 6
        slippageRow.alignment = .center

        let content = UIStackView(arrangedSubviews: [
            title, DexScreenChrome.makeDivider(), releaseBanner,
            DexScreenChrome.makeLabel(L.lang("swap-from-token", fallback: "From token")),
            fromPicker,
            fromBox,
            flipRow,
            DexScreenChrome.makeLabel(L.lang("swap-to-token", fallback: "To token")),
            toPicker,
            toBox,
            routeLabel,
            quoteSourceLabel,
            DexScreenChrome.makeLabel(L.lang("slippage", fallback: "Slippage")),
            slippageRow,
            buttonRow,
            statusLabel
        ])
        content.axis = .vertical
        content.spacing = 10
        content.setCustomSpacing(4, after: flipRow)

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
        // both scrolling together (swap_fragment.xml structure).
        ScreenCard.install(in: scroll, backBar: backBar, content: content)

        onTokensChanged()
        Task { [weak self] in
            guard let self else { return }
            let tokens = await DexScreenChrome.loadAccountTokens(for: self.walletAddress)
            await MainActor.run {
                self.fromPicker.setTokens(tokens, walletAddress: self.walletAddress)
                self.toPicker.setTokens(tokens, walletAddress: self.walletAddress)
            }
        }
        view.installPressFeedbackRecursive()
    }

    private func buildBox(_ box: UIStackView, balanceButton: UIButton, field: UITextField, fromSide: Bool) {
        let L = Localization.shared
        let balanceLabel = UILabel()
        balanceLabel.text = L.getBalanceByLangValues() + ":"
        balanceLabel.font = Typography.body(12)
        balanceLabel.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel
        balanceButton.setTitle("0", for: .normal)
        balanceButton.titleLabel?.font = Typography.body(12)
        balanceButton.setTitleColor(UIColor(named: "colorCommon6") ?? .label, for: .normal)
        balanceButton.addAction(UIAction { [weak self] _ in self?.fillFromBalance(fromSide: fromSide) },
                                for: .touchUpInside)
        let balanceRow = UIStackView(arrangedSubviews: [balanceLabel, balanceButton, UIView()])
        balanceRow.axis = .horizontal
        balanceRow.spacing = 6
        balanceRow.alignment = .center
        field.placeholder = L.lang(fromSide ? "swap-from-quantity" : "swap-to-quantity",
                                   fallback: fromSide ? "From quantity" : "To quantity")
        field.addAction(UIAction { [weak self] _ in self?.amountEdited(fromSide: fromSide) }, for: .editingChanged)
        box.axis = .vertical
        box.spacing = 6
        box.addArrangedSubview(balanceRow)
        box.addArrangedSubview(field)
        box.isHidden = true
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Desktop: early-phase warning on every screen open.
        let L = Localization.shared
        let warn = YesNoDialogViewController(message: L.lang("swapEarlyPhaseWarn",
            fallback: "This is a feature still in early phases of testing. Do you want to continue?"))
        warn.onNo = { [weak self] in self?.tapBack() }
        present(warn, animated: true)
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        quoteTask?.cancel()
        stepsDialog?.dismissSteps()
        stepsDialog = nil
    }

    @objc private func tapBack() {
        (parent as? HomeViewController)?.showMain()
    }

    // MARK: - Token / amount changes (desktop updateSwapScreenInfo)

    private func onTokensChanged() {
        quoteTask?.cancel()
        lastQuotedAmountOut = nil
        lastQuotedAmountIn = nil
        lastQuotedAmountInMax = nil
        lastEditedFromSide = true
        lastQuotedPath = nil
        lastQuoteSource = ""
        updateQuoteSourceNote()
        setAmountSilently(amountInField, "")
        setAmountSilently(amountOutField, "")
        routeLabel.isHidden = true
        updateBalances()
        let ready = !fromPicker.isEmpty && !toPicker.isEmpty
        fromBox.isHidden = !ready
        toBox.isHidden = !ready
        flipRow.isHidden = !ready
        // A fee-on-transfer side has no exact-output form: the To field
        // only shows the estimate and the hint says why.
        let locked = exactOutLocked()
        amountOutField.isUserInteractionEnabled = !locked
        amountOutField.alpha = locked ? 0.6 : 1
        let mode = wrapMode()
        nextButton.setTitle(modeLabel(mode), for: .normal)
        guard ready, fromPicker.tokenValue().caseInsensitiveCompare(toPicker.tokenValue()) != .orderedSame else { return }
        if mode != nil { return }      // 1:1 wrap / unwrap: no route search
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await DexScreenChrome.resolveMeta(self.fromPicker, walletAddress: self.walletAddress)
                try await DexScreenChrome.resolveMeta(self.toPicker, walletAddress: self.walletAddress)
                try await self.fetchRoute(alertWhenMissing: true)
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func updateBalances() {
        fromBalanceButton.setTitle(fromPicker.balanceText(), for: .normal)
        toBalanceButton.setTitle(toPicker.balanceText(), for: .normal)
    }

    private func fillFromBalance(fromSide: Bool) {
        if !fromSide, exactOutLocked() { return }
        let picker = fromSide ? fromPicker! : toPicker!
        let field = fromSide ? amountInField : amountOutField
        let v = picker.balanceText()
        guard v != "0", !v.isEmpty else { return }
        field.text = v
        amountEdited(fromSide: fromSide)
    }

    @objc private func flipTokens() {
        let a = fromPicker.captureSelection()
        let b = toPicker.captureSelection()
        let oldOut = text(amountOutField)
        quoteTask?.cancel()
        fromPicker.restoreSelection(b)
        toPicker.restoreSelection(a)
        onTokensChanged()
        if !oldOut.isEmpty {
            setAmountSilently(amountInField, oldOut)
            scheduleQuote(fromChanged: true)
        }
    }

    private func setAmountSilently(_ field: UITextField, _ value: String) {
        syncingAmounts = true
        field.text = value
        syncingAmounts = false
    }

    private func amountEdited(fromSide: Bool) {
        guard !syncingAmounts else { return }
        scheduleQuote(fromChanged: fromSide)
    }

    // MARK: - Quote (bidirectional, 400 ms debounce)

    private func scheduleQuote(fromChanged: Bool) {
        quoteTask?.cancel()
        quoteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: SwapViewController.quoteDebounceMs * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runQuote(fromChanged: fromChanged)
        }
    }

    private func runQuote(fromChanged: Bool) async {
        guard !fromPicker.isEmpty, !toPicker.isEmpty,
              fromPicker.tokenValue().caseInsensitiveCompare(toPicker.tokenValue()) != .orderedSame else { return }
        lastEditedFromSide = fromChanged || wrapMode() != nil
        let source = text(fromChanged ? amountInField : amountOutField)
        let target = fromChanged ? amountOutField : amountInField
        guard Self.isPositiveAmount(source) else {
            setAmountSilently(target, "")
            lastQuotedAmountOut = nil
            lastQuotedAmountIn = nil
            lastQuotedAmountInMax = nil
            return
        }
        if wrapMode() != nil {           // web-app swap.ts: wrap / unwrap quotes 1:1
            setAmountSilently(target, source)
            lastQuotedAmountOut = source
            return
        }
        setBusy(true)
        do {
            try await DexScreenChrome.resolveMeta(fromPicker, walletAddress: walletAddress)
            try await DexScreenChrome.resolveMeta(toPicker, walletAddress: walletAddress)
            var payload = DexPayloads.base()
            payload["fromTokenValue"] = fromPicker.tokenValue()
            payload["toTokenValue"] = toPicker.tokenValue()
            payload["fromDecimals"] = fromPicker.decimals()
            payload["toDecimals"] = toPicker.decimals()
            if fromChanged {
                payload["amountIn"] = source
                let json = try await JsBridge.shared.dexCallAsync(method: "swapGetAmountsOut", payload: payload)
                let data = try DexBridgeResult.unwrapData(json)
                let out = (data["amountOut"] as? String) ?? ""
                guard !Task.isCancelled else { return }
                lastQuotedAmountOut = out
                lastQuotedAmountIn = nil
                lastQuotedAmountInMax = nil
                rememberQuoteMeta(data)
                setAmountSilently(amountOutField, out)
            } else {
                payload["amountOut"] = source
                payload["slippagePercent"] = slippagePercent()
                let json = try await JsBridge.shared.dexCallAsync(method: "swapGetAmountsIn", payload: payload)
                let data = try DexBridgeResult.unwrapData(json)
                let input = (data["amountIn"] as? String) ?? ""
                guard !Task.isCancelled else { return }
                lastQuotedAmountOut = source
                lastQuotedAmountIn = input
                lastQuotedAmountInMax = (data["amountInMax"] as? String) ?? input
                rememberQuoteMeta(data)
                setAmountSilently(amountInField, input)
            }
            setBusy(false)
        } catch {
            failFlow("\(error)")
        }
    }

    private func rememberQuoteMeta(_ data: [String: Any]) {
        lastQuotedPath = (data["path"] as? [Any])?.compactMap { $0 as? String }
        lastQuoteSource = (data["source"] as? String) ?? ""
        lastQuoteIndexedBlock = (data["indexedBlock"] as? NSNumber)?.int64Value ?? 0
        updateQuoteSourceNote()
    }

    /// Web app appendQuoteSource: say so when the number came from the
    /// indexed reserves rather than the router.
    private func updateQuoteSourceNote() {
        let show = lastQuoteSource == "api-estimate"
        quoteSourceLabel.isHidden = !show
        if show {
            quoteSourceLabel.text = Localization.shared.lang("swap-quote-source-indexed",
                fallback: "Estimated from indexed reserves · block [BLOCK]")
                .replacingOccurrences(of: "[BLOCK]", with: String(lastQuoteIndexedBlock))
        }
    }

    private func fetchRoute(alertWhenMissing: Bool) async throws {
        var payload = DexPayloads.base()
        payload["fromTokenValue"] = fromPicker.tokenValue()
        payload["toTokenValue"] = toPicker.tokenValue()
        let json = try await JsBridge.shared.dexCallAsync(method: "swapCheckPairExists", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        let exists = (data["exists"] as? Bool) ?? false
        let path = data["path"] as? [Any]
        let symbols = data["pathSymbols"] as? [Any]
        await MainActor.run {
            self.setBusy(false)
            let L = Localization.shared
            guard exists, let path, !path.isEmpty else {
                self.routeLabel.isHidden = true
                if alertWhenMissing {
                    DexScreenChrome.presentError(from: self, message: L.lang("swap-no-pair",
                        fallback: "No swap route exists between these two tokens (max 3 hops)"))
                }
                return
            }
            var parts: [String] = []
            for i in 0..<path.count {
                let sym = (symbols?[safe: i] as? String)
                let addr = (path[i] as? String) ?? ""
                if let sym, !sym.isEmpty, sym != "null" {
                    parts.append(DexBridgeResult.sanitizeSymbol(sym))
                } else {
                    parts.append(DexBridgeResult.shortAddr(addr))
                }
            }
            self.routeLabel.text = L.lang("swap-route", fallback: "Route") + ": " + parts.joined(separator: " > ")
            self.routeLabel.isHidden = false
        }
    }

    // MARK: - Next -> allowance check -> steps

    /// Desktop onSwapNextClick: post-click validation (the button is
    /// never disabled), then the allowance check decides the plan.
    @objc private func tapNext() {
        let amountIn = text(amountInField)
        guard validateInputs(amountIn) else { return }
        if lastQuotedAmountOut == nil || lastQuotedAmountOut?.isEmpty == true {
            lastQuotedAmountOut = text(amountOutField)
        }
        if flowInFlight { return }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await DexScreenChrome.resolveMeta(self.fromPicker, walletAddress: self.walletAddress)
                try await DexScreenChrome.resolveMeta(self.toPicker, walletAddress: self.walletAddress)
                // Wrap / unwrap talk to the WQ contract directly, and a native
                // from-side travels as tx value through the payable router
                // entry point: neither needs an allowance, so no approve step.
                if self.wrapMode() != nil || self.fromPicker.isNative {
                    await MainActor.run {
                        self.setBusy(false)
                        self.showStepsDialog(needsApproval: false)
                    }
                    return
                }
                var payload = DexPayloads.base()
                payload["fromTokenValue"] = self.fromPicker.tokenValue()
                payload["fromDecimals"] = self.fromPicker.decimals()
                // Exact-out lets the router pull up to amountInMax, so that is
                // the allowance to check (and to approve).
                payload["requiredAmount"] = self.isExactOut() ? self.maxInput() : amountIn
                payload["ownerAddress"] = self.walletAddress
                let json = try await JsBridge.shared.dexCallAsync(method: "swapCheckAllowance", payload: payload)
                let data = try DexBridgeResult.unwrapData(json)
                let sufficient = (data["sufficient"] as? Bool) ?? false
                await MainActor.run {
                    self.setBusy(false)
                    self.showStepsDialog(needsApproval: !sufficient)
                }
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    /// Desktop createSwapWorkflowStepPlan: optional "Approve FROM",
    /// always "Swap FROM -> TO".
    private func showStepsDialog(needsApproval: Bool) {
        let L = Localization.shared
        let fromSym = DexBridgeResult.sanitizeSymbol(fromPicker.symbol())
        let toSym = DexBridgeResult.sanitizeSymbol(toPicker.symbol())
        let amountIn = text(amountInField)
        let amountOut = lastQuotedAmountOut ?? ""
        let exactOut = isExactOut()
        // Exact-out spends at most amountInMax for exactly amountOut: the
        // review, the approval and the native value all use the maximum.
        let amountInMax = exactOut ? maxInput() : amountIn
        let upTo = exactOut ? L.lang("swap-up-to", fallback: "up to") + " " : ""
        let release = ReleaseStore.readActive()
        let fromContract = DexScreenChrome.resolveTokenContract(fromPicker.tokenValue(), release: release)
        let toContract = DexScreenChrome.resolveTokenContract(toPicker.tokenValue(), release: release)
        let fromNative = fromPicker.isNative
        let mode = wrapMode()
        let forWord = L.lang("swap-for", fallback: "for")

        var routeSuffix = ""
        if !routeLabel.isHidden, let route = routeLabel.text, let r = route.range(of: ": "),
           route.contains(" > ") {
            routeSuffix = " (" + route[r.upperBound...].replacingOccurrences(of: " > ", with: " -> ") + ")"
        }
        let base = ReviewSpec()
            .action((mode == nil ? L.lang("swap", fallback: "Swap") : modeLabel(mode))
                    + " " + fromSym + " " + forWord + " " + toSym + routeSuffix)
            .fromTokenContract(fromContract)
            .toTokenContract(toContract)
            .fromAddress(walletAddress)
            .toAddress(mode == nil ? release.router : release.wq)
            .quantityValue(fromNative ? amountInMax : "0")
            .tokenQuantityValue(upTo + amountInMax + " " + fromSym + " " + forWord + " " + amountOut + " " + toSym)
            .networkText(ReviewSpec.networkText())

        let fromValue = fromPicker.tokenValue()
        let fromDecimals = fromPicker.decimals()
        let swapArgs: () -> [String: Any] = { [weak self] in
            guard let self else { return [:] }
            var args: [String: Any] = [
                "fromTokenValue": self.fromPicker.tokenValue(),
                "toTokenValue": self.toPicker.tokenValue(),
                "fromDecimals": self.fromPicker.decimals(),
                "toDecimals": self.toPicker.decimals(),
                "amountIn": amountIn,
                "amountOut": self.text(self.amountOutField),
                "lastChanged": self.isExactOut() ? "to" : "from",
                "slippagePercent": self.slippagePercent(),
                "recipientAddress": self.walletAddress
            ]
            if let path = self.lastQuotedPath, path.count >= 2 { args["path"] = path }
            return args
        }

        var steps: [TxStep] = []
        if let mode {
            // Single WQ.deposit / WQ.withdraw step; no approval, no router.
            let isWrap = mode == "wrap"
            let wrapPayload: () -> [String: Any] = { ["amount": amountIn] }
            steps.append(TxStep(label: L.lang("step-" + mode, fallback: isWrap ? "Wrap" : "Unwrap")
                                    + " " + amountIn + " " + fromSym,
                                kind: isWrap ? .wrap : .unwrap, estimatePayload: wrapPayload,
                                submitMethod: isWrap ? "swapSubmitWrap" : "swapSubmitUnwrap",
                                submitPayload: wrapPayload))
        } else {
        if needsApproval {
            let approveReview = ReviewSpec()
                .action(L.lang("approve", fallback: "Approve") + " " + fromSym)
                .fromTokenContractLabelKey("approval-token-contract")
                .toTokenContract(ReviewSpec.HIDE)
                .toAddress(fromContract)
                .quantityValue("0")
                .tokenQuantityLabelKey("approval-token-quantity")
                .tokenQuantityValue(amountInMax + " " + fromSym)
            let approvePayload: () -> [String: Any] = {
                ["fromTokenValue": fromValue, "fromDecimals": fromDecimals, "amount": amountInMax]
            }
            steps.append(TxStep(label: L.lang("approve", fallback: "Approve") + " " + fromSym,
                                kind: .approve, estimatePayload: approvePayload,
                                submitMethod: "swapSubmitApproval", submitPayload: approvePayload,
                                reviewOverride: approveReview))
        }
        // Exact-out only: the bridge reports an exact-in fallback (listed
        // fee-on-transfer token on the path, or the pre-flight reverted)
        // in the estimate echo; close and restart exact-in.
        let onSwapEstimated: (([String: Any]) -> Void)? = exactOut
            ? { [weak self] extra in self?.onSwapEstimated(extra) } : nil
        steps.append(TxStep(label: L.lang("swap", fallback: "Swap") + " " + fromSym + " -> " + toSym,
                            kind: .swap, estimatePayload: swapArgs,
                            submitMethod: "swapSubmitSwap", submitPayload: swapArgs,
                            onEstimated: onSwapEstimated))
        }

        flowInFlight = true
        let dlg = TxStepsDialogViewController(title: mode == nil ? L.lang("swap", fallback: "Swap") : modeLabel(mode),
                                              walletAddress: walletAddress, steps: steps, baseReview: base)
        dlg.onClose = { [weak self] in
            guard let self else { return }
            self.stepsDialog = nil
            self.flowInFlight = false
            self.lastQuotedAmountOut = nil
            self.lastQuotedAmountIn = nil
            self.lastQuotedAmountInMax = nil
            if self.restartAsExactIn {
                // The estimate reported an exact-in fallback: the From field
                // already holds the quoted input, so explain and re-quote
                // from it; Next then runs exact-in.
                self.restartAsExactIn = false
                self.lastEditedFromSide = true
                DexScreenChrome.presentError(from: self, message: L.lang("swap-exact-output-fallback",
                    fallback: "Exact output is not available for this token; swapping the exact input instead. Review the quote and tap Next again."))
                self.scheduleQuote(fromChanged: true)
                return
            }
            self.setAmountSilently(self.amountInField, "")
            self.setAmountSilently(self.amountOutField, "")
            self.updateBalances()
        }
        stepsDialog = dlg
        dlg.show(from: self)
    }

    private func onSwapEstimated(_ extra: [String: Any]) {
        guard let fallback = extra["fallback"] as? String, !fallback.isEmpty else { return }
        restartAsExactIn = true
        stepsDialog?.dismissSteps()
    }

    /// Either side burns or taxes on transfer: no fee-safe exact-output
    /// form exists, so the pair stays exact-in and the To field is
    /// estimate-only.
    private func exactOutLocked() -> Bool {
        RecognizedTokens.isFeeOnTransfer(fromPicker.tokenValue())
            || RecognizedTokens.isFeeOnTransfer(toPicker.tokenValue())
    }

    /// Web-app isExactOut: the To side was typed last, for a router swap
    /// (wrap / unwrap is always 1:1) on a pair without a listed
    /// fee-on-transfer token.
    private func isExactOut() -> Bool {
        !lastEditedFromSide && wrapMode() == nil && !exactOutLocked()
    }

    /// The most an exact-out swap may spend: the quoted maximum, or the
    /// From field when no exact-out quote has landed yet.
    private func maxInput() -> String {
        if let m = lastQuotedAmountInMax, !m.isEmpty { return m }
        return text(amountInField)
    }

    private func slippageEdited() {
        guard !text(amountInField).isEmpty || !text(amountOutField).isEmpty else { return }
        scheduleQuote(fromChanged: lastEditedFromSide)
    }

    // MARK: - Helpers

    private func validateInputs(_ amountIn: String) -> Bool {
        let L = Localization.shared
        if fromPicker.isEmpty || toPicker.isEmpty {
            DexScreenChrome.presentError(from: self, message: L.lang("select-both-tokens",
                fallback: "Select both tokens."))
            return false
        }
        if fromPicker.tokenValue().caseInsensitiveCompare(toPicker.tokenValue()) == .orderedSame {
            DexScreenChrome.presentError(from: self, message: L.err(
                "identicalTokens", fallback: "From and To tokens must differ."))
            return false
        }
        if !Self.isPositiveAmount(amountIn) {
            DexScreenChrome.presentError(from: self, message: L.err(
                "invalidQuantity", fallback: "Enter a valid quantity."))
            return false
        }
        if isExactOut() {
            // Exact-out may spend up to amountInMax; refuse before the dialog
            // when the cached balance is known and clearly smaller.
            let max = maxInput()
            let bal = fromPicker.balanceText().replacingOccurrences(of: ",", with: "")
            if let m = Decimal(string: max), let b = Decimal(string: bal), b > 0, m > b {
                let symbol = DexBridgeResult.sanitizeSymbol(fromPicker.symbol())
                DexScreenChrome.presentError(from: self, message: L.err("swapMaxSoldExceedsBalance",
                    fallback: "Up to [QUANTITY] could be sold, which exceeds your balance.")
                    .replacingOccurrences(of: "[QUANTITY]", with: max + " " + symbol))
                return false
            }
        }
        return true
    }

    private static func isPositiveAmount(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: #"^\d*\.?\d+$"#, options: .regularExpression) != nil
            && (Double(s) ?? 0) > 0
    }

    /// Web-app swap.ts isWrap / isUnwrap: native Q against the active
    /// release's WQ contract is a 1:1 wrap / unwrap (one WQ.deposit /
    /// WQ.withdraw transaction), never a router swap. "wrap", "unwrap" or nil.
    private func wrapMode() -> String? {
        let from = fromPicker.tokenValue(), to = toPicker.tokenValue()
        let wq = ReleaseStore.readActive().wq
        guard !wq.isEmpty else { return nil }
        if from == "Q", wq.caseInsensitiveCompare(to) == .orderedSame { return "wrap" }
        if to == "Q", wq.caseInsensitiveCompare(from) == .orderedSame { return "unwrap" }
        return nil
    }

    /// Action-button / dialog label for the current pair: Next, Wrap or Unwrap.
    private func modeLabel(_ mode: String?) -> String {
        let L = Localization.shared
        guard let mode else { return L.lang("next", fallback: "Next") }
        return L.lang(mode, fallback: mode == "wrap" ? "Wrap" : "Unwrap")
    }

    private func slippagePercent() -> Double {
        let v = Double(text(slippageField)) ?? 1
        return max(0, min(100, v))
    }

    private func text(_ f: UITextField) -> String {
        f.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func failFlow(_ error: String?) {
        flowInFlight = false
        setBusy(false)
        statusLabel.isHidden = true
        if let error, !error.isEmpty {
            DexScreenChrome.presentError(from: self, message: error)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
