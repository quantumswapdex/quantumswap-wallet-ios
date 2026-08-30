// LiquidityViewController.swift
// Desktop liquidity screen (src/app/advanced.ts) / Android
// `LiquidityFragment.java`:
//   - list panel (default): My Positions (scrolling box) with a
//     "Remove Liquidity" link per card and an "Add Liquidity" link below;
//   - form panel: Token A / amount, Token B / amount, slippage, Add;
//   - add plan  [Approve A]? [Approve B]? Add Liquidity A / B
//     (4.5M default gas when the pair does not exist yet);
//   - remove plan [Approve LP]? Remove Liquidity A / B after a percent
//     prompt (default 100).
// Every step estimates its own gas, reviews ("i agree" -> unlock) and
// confirms through the scan-API poll inside TxStepsDialogViewController.

import UIKit

public final class LiquidityViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    private var walletAddress = ""
    private let listPanel = UIStackView()
    private let formPanel = UIStackView()
    private let positionsStack = UIStackView()
    private let positionsScroll = AutoHorizontalScrollView()
    private let noPositionsLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var tokenAPicker: DexTokenPickerView!
    private var tokenBPicker: DexTokenPickerView!
    private let amountAField = DexScreenChrome.makeField(placeholder: "", keyboard: .decimalPad)
    private let amountBField = DexScreenChrome.makeField(placeholder: "", keyboard: .decimalPad)
    private let slippageField = DexScreenChrome.makeField(placeholder: "1", keyboard: .decimalPad)
    private let addButton = GreenPillButton(type: .system)
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
        title.text = L.lang("liquidity", fallback: "Liquidity")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        // ---- List panel -------------------------------------------------
        let positionsTitle = UILabel()
        positionsTitle.text = L.lang("my-positions", fallback: "My Positions")
        positionsTitle.font = Typography.boldTitle(16)
        positionsTitle.textColor = UIColor(named: "colorCommon1") ?? .label
        let refresh = UIButton(type: .system)
        refresh.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refresh.tintColor = UIColor(named: "colorCommon6") ?? .label
        refresh.addTarget(self, action: #selector(loadPositions), for: .touchUpInside)
        // "Add Liquidity" lives at the top right of the box, left of
        // the refresh icon (same pattern as Pools' Create Pair).
        let addLink = DexScreenChrome.makeLink(L.lang("add-liquidity", fallback: "Add Liquidity"),
                                               underline: true, target: self, action: #selector(showAddPanel))
        let headerRow = UIStackView(arrangedSubviews: [positionsTitle, UIView(), addLink, refresh, spinner])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8
        spinner.hidesWhenStopped = true

        noPositionsLabel.text = L.lang("no-positions", fallback: "You have no liquidity positions.")
        noPositionsLabel.font = Typography.body(13)
        noPositionsLabel.textColor = UIColor(rgbHex: 0x9A9AA6) // Android colorMutedSecondaryText
        noPositionsLabel.numberOfLines = 0

        positionsStack.axis = .vertical
        positionsStack.spacing = 4
        positionsScroll.install(content: positionsStack)
        // Cap so the card bottom border stays on screen; overflow
        // scrolls vertically inside the box.
        positionsScroll.capToScreen(reserveBelow: 70)

        listPanel.axis = .vertical
        listPanel.spacing = 10
        [headerRow, noPositionsLabel, positionsScroll].forEach { listPanel.addArrangedSubview($0) }

        // ---- Form panel -------------------------------------------------
        let addTitle = UILabel()
        addTitle.text = L.lang("add-liquidity", fallback: "Add Liquidity")
        addTitle.font = Typography.boldTitle(16)
        addTitle.textColor = UIColor(named: "colorCommon1") ?? .label

        let customLabel = L.lang("custom-contract-address", fallback: "Custom...")
        tokenAPicker = DexTokenPickerView(customLabel: customLabel)
        tokenBPicker = DexTokenPickerView(customLabel: customLabel)
        amountAField.placeholder = L.lang("quantity", fallback: "Quantity")
        amountBField.placeholder = L.lang("quantity", fallback: "Quantity")
        slippageField.text = "1"
        addButton.setTitle(L.lang("add-liquidity", fallback: "Add Liquidity"), for: .normal)
        addButton.addTarget(self, action: #selector(startAdd), for: .touchUpInside)
        // Same footprint as the Send screen's primary button.
        addButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        addButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let addRow = UIStackView(arrangedSubviews: [UIView(), addButton, UIView()])
        addRow.axis = .horizontal
        addRow.distribution = .equalCentering

        statusLabel.font = Typography.body(12)
        statusLabel.textColor = UIColor(rgbHex: 0xFBBF24) // Android quantumAmber
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        formPanel.axis = .vertical
        formPanel.spacing = 10
        formPanel.isHidden = true
        [addTitle,
         DexScreenChrome.makeLabel(L.lang("token-a", fallback: "Token A")), tokenAPicker, amountAField,
         DexScreenChrome.makeLabel(L.lang("token-b", fallback: "Token B")), tokenBPicker, amountBField,
         DexScreenChrome.makeLabel(L.lang("slippage", fallback: "Slippage")), slippageField,
         statusLabel, addRow].forEach { formPanel.addArrangedSubview($0) }

        let content = UIStackView(arrangedSubviews: [title, DexScreenChrome.makeDivider(), listPanel, formPanel])
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

        Task { [weak self] in
            guard let self else { return }
            let tokens = await DexScreenChrome.loadAccountTokens(for: self.walletAddress)
            await MainActor.run {
                self.tokenAPicker.setTokens(tokens, walletAddress: self.walletAddress)
                self.tokenBPicker.setTokens(tokens, walletAddress: self.walletAddress)
            }
        }
        loadPositions()
        view.installPressFeedbackRecursive()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stepsDialog?.dismissSteps()
        stepsDialog = nil
    }

    /// Desktop: back from the add form returns to My Positions; back
    /// from the positions list leaves the screen.
    @objc private func tapBack() {
        if !formPanel.isHidden {
            showPositionsPanel()
            return
        }
        (parent as? HomeViewController)?.beginTransactionNow(AdvancedViewController())
    }

    // MARK: - Panels

    /// Desktop showLiquidityAddPanel: swap to the form with a clean slate.
    @objc private func showAddPanel() {
        tokenAPicker.restoreSelection(nil)
        tokenBPicker.restoreSelection(nil)
        amountAField.text = ""
        amountBField.text = ""
        statusLabel.isHidden = true
        listPanel.isHidden = true
        formPanel.isHidden = false
    }

    /// Desktop showLiquidityPositionsPanel.
    private func showPositionsPanel() {
        formPanel.isHidden = true
        listPanel.isHidden = false
        loadPositions()
    }

    // MARK: - Positions

    @objc private func loadPositions() {
        setBusy(true)
        let owner = walletAddress
        Task { [weak self] in
            guard let self else { return }
            do {
                var payload = DexPayloads.base()
                payload["ownerAddress"] = owner
                let json = try await JsBridge.shared.dexCallAsync(method: "liquidityListPositions", payload: payload)
                let data = try DexBridgeResult.unwrapData(json)
                let positions = Self.dictArray(data["positions"])
                await MainActor.run {
                    self.setBusy(false)
                    self.renderPositions(positions, meta: data)
                }
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func renderPositions(_ positions: [[String: Any]], meta: [String: Any]) {
        let L = Localization.shared
        let api = (meta["source"] as? String) == "api"
        renderPositionRows(positions)
        noPositionsLabel.text = api
            ? L.lang("positions-empty-api",
                     fallback: "No liquidity positions found for this account on the active release.")
            : L.lang("no-positions", fallback: "You have no liquidity positions.")
        guard api else { return }
        positionsScroll.isHidden = false
        let indexed = (meta["indexedBlock"] as? NSNumber)?.intValue ?? 0
        positionsStack.insertArrangedSubview(noteLabel(L.lang("pools-indexed-at", fallback: "Indexed at block [BLOCK]")
            .replacingOccurrences(of: "[BLOCK]", with: String(indexed))), at: 0)
        if (meta["capped"] as? Bool) == true {
            positionsStack.insertArrangedSubview(noteLabel(L.lang("positions-capped",
                fallback: "Showing the first 1000 positions tracked for this account.")), at: 1)
        }
        loadPairsCreated()
    }

    /// Web app positions.ts "Pools you created (N)" card (API only).
    private func loadPairsCreated() {
        let owner = walletAddress
        Task { [weak self] in
            guard let self else { return }
            var payload = DexPayloads.base()
            payload["ownerAddress"] = owner
            payload["page"] = 1
            guard let json = try? await JsBridge.shared.dexCallAsync(method: "liquidityListPairsCreated", payload: payload),
                  let data = try? DexBridgeResult.unwrapData(json) else { return }
            let pools = Self.dictArray(data["pools"])
            guard !pools.isEmpty else { return }
            let total = (data["totalItems"] as? NSNumber)?.intValue ?? pools.count
            await MainActor.run {
                let L = Localization.shared
                let title = UILabel()
                title.text = L.lang("positions-pools-created", fallback: "Pools you created") + " (\(total))"
                title.font = Typography.boldTitle(14)
                title.textColor = UIColor(named: "colorCommon6") ?? .label
                self.positionsStack.addArrangedSubview(title)
                for pool in pools {
                    let sym0 = DexBridgeResult.sanitizeSymbol(pool["symbol0"] as? String)
                    let sym1 = DexBridgeResult.sanitizeSymbol(pool["symbol1"] as? String)
                    let token0 = (pool["token0"] as? String) ?? ""
                    let token1 = (pool["token1"] as? String) ?? ""
                    let pair = ExplorerLinks.makePairLabel(
                        symA: sym0.isEmpty ? DexBridgeResult.shortAddr(token0) : sym0, tokenA: token0,
                        symB: sym1.isEmpty ? DexBridgeResult.shortAddr(token1) : sym1, tokenB: token1)
                    let addr = UILabel()
                    addr.text = DexBridgeResult.shortAddr(pool["pairAddress"] as? String)
                    addr.font = Typography.body(12)
                    addr.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel
                    let row = UIStackView(arrangedSubviews: [pair, addr])
                    row.axis = .vertical
                    row.spacing = 2
                    self.positionsStack.addArrangedSubview(row)
                }
            }
        }
    }

    private func noteLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = Typography.body(12)
        l.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel
        l.numberOfLines = 0
        return l
    }

    private func renderPositionRows(_ positions: [[String: Any]]) {
        positionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        noPositionsLabel.isHidden = !positions.isEmpty
        positionsScroll.isHidden = positions.isEmpty
        let L = Localization.shared
        for pos in positions {
            let row = UIStackView()
            row.axis = .vertical
            row.spacing = 4
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

            let sym0 = DexBridgeResult.sanitizeSymbol(pos["symbol0"] as? String)
            let sym1 = DexBridgeResult.sanitizeSymbol(pos["symbol1"] as? String)
            let token0 = (pos["token0"] as? String) ?? ""
            let token1 = (pos["token1"] as? String) ?? ""
            // Symbols link to the token contract on the block explorer.
            let pair = ExplorerLinks.makePairLabel(
                symA: sym0.isEmpty ? DexBridgeResult.shortAddr(token0) : sym0, tokenA: token0,
                symB: sym1.isEmpty ? DexBridgeResult.shortAddr(token1) : sym1, tokenB: token1)

            // Web-app positions.ts stat rows: the user's own numbers
            // (LP balance, pool share, the pooled amount of each
            // token) instead of the raw LP figure + POOL-TOTAL
            // reserves, which read as unexplained numbers.
            let dec0 = (pos["decimals0"] as? Int) ?? (pos["decimals0"] as? NSNumber)?.intValue ?? 18
            let dec1 = (pos["decimals1"] as? Int) ?? (pos["decimals1"] as? NSNumber)?.intValue ?? 18
            let lpUnits = Double(CoinUtils.formatUnits(pos["lpBalance"] as? String, decimals: 18)) ?? 0
            let supplyUnits = Double(CoinUtils.formatUnits(pos["totalSupply"] as? String, decimals: 18)) ?? 0
            let share = supplyUnits > 0 ? lpUnits / supplyUnits : 0
            let r0 = Double(CoinUtils.formatUnits(pos["reserve0"] as? String, decimals: dec0)) ?? 0
            let r1 = Double(CoinUtils.formatUnits(pos["reserve1"] as? String, decimals: dec1)) ?? 0
            let name0 = sym0.isEmpty ? DexBridgeResult.shortAddr(token0) : sym0
            let name1 = sym1.isEmpty ? DexBridgeResult.shortAddr(token1) : sym1
            func stat(_ text: String) -> UILabel {
                let l = UILabel()
                l.text = text
                l.font = Typography.body(13)
                l.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel
                return l
            }
            let stats: [UILabel] = [
                stat(L.lang("lp-balance", fallback: "LP balance") + ": "
                     + String(format: "%.6f", lpUnits)),
                stat(L.lang("pool-share", fallback: "Pool share") + ": "
                     + String(format: "%.4f", share * 100) + "%"),
                stat(L.lang("pooled-token", fallback: "Pooled [SYM]")
                     .replacingOccurrences(of: "[SYM]", with: name0)
                     + ": " + String(format: "%.6f", r0 * share)),
                stat(L.lang("pooled-token", fallback: "Pooled [SYM]")
                     .replacingOccurrences(of: "[SYM]", with: name1)
                     + ": " + String(format: "%.6f", r1 * share))
            ]

            // Desktop position card: "Remove Liquidity" is a link.
            let remove = UIButton(type: .system)
            remove.setAttributedTitle(NSAttributedString(
                string: L.lang("remove-liquidity", fallback: "Remove Liquidity"),
                attributes: [.font: Typography.body(14), .foregroundColor: UIColor.quantumTeal,
                             .underlineStyle: NSUnderlineStyle.single.rawValue]), for: .normal)
            remove.contentHorizontalAlignment = .leading
            remove.contentEdgeInsets = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 8)
            remove.addAction(UIAction { [weak self] _ in self?.promptRemove(pos) }, for: .touchUpInside)

            ([pair] + stats + [remove, DexScreenChrome.makeDivider()]).forEach { row.addArrangedSubview($0) }
            positionsStack.addArrangedSubview(row)
        }
    }

    // MARK: - Remove

    private func promptRemove(_ pos: [String: Any]) {
        // Web-app removeLiquidity.ts form: percent readout + slider +
        // preset chips + live "what you get" stats, replacing the old
        // bare "100" number box that explained nothing.
        let dec0 = (pos["decimals0"] as? Int) ?? (pos["decimals0"] as? NSNumber)?.intValue ?? 18
        let dec1 = (pos["decimals1"] as? Int) ?? (pos["decimals1"] as? NSNumber)?.intValue ?? 18
        let sym0 = DexBridgeResult.sanitizeSymbol(pos["symbol0"] as? String)
        let sym1 = DexBridgeResult.sanitizeSymbol(pos["symbol1"] as? String)
        let dialog = RemoveLiquidityDialogViewController(
            lpUnits: Double(CoinUtils.formatUnits(pos["lpBalance"] as? String, decimals: 18)) ?? 0,
            supplyUnits: Double(CoinUtils.formatUnits(pos["totalSupply"] as? String, decimals: 18)) ?? 0,
            reserve0Units: Double(CoinUtils.formatUnits(pos["reserve0"] as? String, decimals: dec0)) ?? 0,
            reserve1Units: Double(CoinUtils.formatUnits(pos["reserve1"] as? String, decimals: dec1)) ?? 0,
            sym0: sym0.isEmpty ? DexBridgeResult.shortAddr(pos["token0"] as? String) : sym0,
            sym1: sym1.isEmpty ? DexBridgeResult.shortAddr(pos["token1"] as? String) : sym1)
        dialog.onConfirm = { [weak self] pct in
            self?.runRemoveFlow(pos, percent: pct)
        }
        present(dialog, animated: true)
    }

    /// Desktop tx-steps model for Remove: compute the burn amounts (no
    /// keys needed), pre-check the LP-token allowance, then run
    /// [Approve LP?] [Remove Liquidity] through the steps dialog.
    private func runRemoveFlow(_ pos: [String: Any], percent: Int) {
        setBusy(true)
        let owner = walletAddress
        let slip = slippagePercent()
        Task { [weak self] in
            guard let self else { return }
            do {
                let lpBalance = (pos["lpBalance"] as? String) ?? "0"
                let liquidity = DexBigInt.divSmall(DexBigInt.mulSmall(lpBalance, percent), 100)
                guard DexBigInt.isPositive(liquidity) else {
                    throw JsEngineError.callFailed("Nothing to remove")
                }
                var totalSupply = (pos["totalSupply"] as? String) ?? "1"
                if !DexBigInt.isPositive(totalSupply) { totalSupply = "1" }
                let reserve0 = (pos["reserve0"] as? String) ?? "0"
                let reserve1 = (pos["reserve1"] as? String) ?? "0"
                let slipBps = Int((slip * 100).rounded())
                let keep = String(10_000 - slipBps)
                let amountAMin = DexBigInt.mulDiv(DexBigInt.mulDiv(reserve0, liquidity, totalSupply), keep, "10000")
                let amountBMin = DexBigInt.mulDiv(DexBigInt.mulDiv(reserve1, liquidity, totalSupply), keep, "10000")
                let pairAddress = (pos["pairAddress"] as? String) ?? ""
                let needsApprove = try await self.needsRouterApproval(tokenAddress: pairAddress, requiredWei: liquidity)
                await MainActor.run {
                    self.setBusy(false)
                    self.showRemoveSteps(pos, pairAddress: pairAddress, liquidity: liquidity,
                                         amountAMin: amountAMin, amountBMin: amountBMin,
                                         needsApprove: needsApprove, percent: percent, owner: owner)
                }
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func showRemoveSteps(_ pos: [String: Any], pairAddress: String, liquidity: String,
                                 amountAMin: String, amountBMin: String, needsApprove: Bool,
                                 percent: Int, owner: String) {
        let L = Localization.shared
        let removeLabel = L.lang("remove-liquidity", fallback: "Remove Liquidity")
        let release = ReleaseStore.readActive()
        let sym0 = DexBridgeResult.sanitizeSymbol(pos["symbol0"] as? String)
        let sym1 = DexBridgeResult.sanitizeSymbol(pos["symbol1"] as? String)
        let token0 = (pos["token0"] as? String) ?? ""
        let token1 = (pos["token1"] as? String) ?? ""
        let a = sym0.isEmpty ? DexBridgeResult.shortAddr(token0) : sym0
        let b = sym1.isEmpty ? DexBridgeResult.shortAddr(token1) : sym1
        let lpAmount = CoinUtils.formatUnits(liquidity, decimals: 18)

        let base = ReviewSpec()
            .action(removeLabel + " " + a + " / " + b)
            .contractAddress(release.router)
            .fromAddress(owner)
            .toAddress(release.router)
            .quantityLabelKey("lp-to-burn")
            .quantityValue(lpAmount + " LP (" + String(percent) + "%)")
            .networkText(ReviewSpec.networkText())

        var steps: [TxStep] = []
        if needsApprove {
            let approveReview = ReviewSpec()
                .action(L.lang("step-approve", fallback: "Approve") + " " + a + "/" + b + " LP")
                .contractAddress(pairAddress)
                .contractIsToken(true)
                .toAddress(pairAddress)
                .quantityLabelKey("send-quantity")
                .quantityValue(lpAmount + " LP")
            steps.append(approveTokenStep(label: L.lang("step-approve", fallback: "Approve") + " LP",
                                          tokenAddress: pairAddress, review: approveReview))
        }
        let removeArgs: [String: Any] = [
            "tokenAAddress": token0, "tokenBAddress": token1,
            "liquidityWei": liquidity, "amountAMinWei": amountAMin, "amountBMinWei": amountBMin,
            "ownerAddress": owner
        ]
        steps.append(TxStep(label: removeLabel, kind: .removeLiquidity,
                            estimatePayload: { removeArgs },
                            submitMethod: "liquiditySubmitRemove", submitPayload: { removeArgs }))
        openSteps(title: removeLabel, base: base, steps: steps)
    }

    // MARK: - Add

    @objc private func startAdd() {
        let L = Localization.shared
        let amountA = text(amountAField)
        let amountB = text(amountBField)
        if tokenAPicker.isEmpty || tokenBPicker.isEmpty {
            DexScreenChrome.presentError(from: self, message: L.lang("select-both-tokens", fallback: "Select both tokens."))
            return
        }
        if tokenAPicker.tokenValue().caseInsensitiveCompare(tokenBPicker.tokenValue()) == .orderedSame {
            DexScreenChrome.presentError(from: self, message: L.err("identicalTokens", fallback: "Token A and Token B must differ."))
            return
        }
        if !isPositiveDecimal(amountA) || !isPositiveDecimal(amountB) {
            DexScreenChrome.presentError(from: self, message: L.err("invalidQuantity", fallback: "Enter a valid quantity."))
            return
        }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await DexScreenChrome.resolveMeta(self.tokenAPicker, walletAddress: self.walletAddress)
                try await DexScreenChrome.resolveMeta(self.tokenBPicker, walletAddress: self.walletAddress)
                try await self.checkPairThenAdd()
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func checkPairThenAdd() async throws {
        var payload = DexPayloads.base()
        payload["tokenAValue"] = tokenAPicker.tokenValue()
        payload["tokenBValue"] = tokenBPicker.tokenValue()
        payload["ownerAddress"] = walletAddress
        let json = try await JsBridge.shared.dexCallAsync(method: "liquidityGetPairInfo", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        let exists = (data["exists"] as? Bool) ?? false
        let pair = data["pair"] as? [String: Any]
        let emptyPool = exists && (pair?["reserve0"] as? String) == "0" && (pair?["reserve1"] as? String) == "0"
        if !exists || emptyPool {
            // Desktop first-provider warning: the ratio sets the initial price.
            let ok: Bool = await withCheckedContinuation { cont in
                Task { @MainActor in
                    let dlg = YesNoDialogViewController(message: Localization.shared.lang("first-provider-warn",
                        fallback: "This pool is empty. You are the first liquidity provider: the ratio of the amounts you add sets the initial price of this pair."))
                    dlg.onYes = { cont.resume(returning: true) }
                    dlg.onNo = { cont.resume(returning: false) }
                    self.present(dlg, animated: true)
                }
            }
            if !ok {
                await MainActor.run { self.failFlow(nil) }
                return
            }
        }
        try await planAdd(pairExists: exists)
    }

    /// Desktop tx-steps model: pre-check both ERC20 sides' allowances to
    /// build the plan ([Approve A?] [Approve B?] [Add]). Native "Q"
    /// sides need no approval.
    private func planAdd(pairExists: Bool) async throws {
        let tokenA = tokenAPicker.tokenValue()
        let tokenB = tokenBPicker.tokenValue()
        let requiredA = tokenA == "Q" ? nil : CoinUtils.parseUnits(text(amountAField), decimals: tokenAPicker.decimals())
        let requiredB = tokenB == "Q" ? nil : CoinUtils.parseUnits(text(amountBField), decimals: tokenBPicker.decimals())
        var needsA = false, needsB = false
        if let r = requiredA { needsA = try await needsRouterApproval(tokenAddress: tokenA, requiredWei: r) }
        if let r = requiredB { needsB = try await needsRouterApproval(tokenAddress: tokenB, requiredWei: r) }
        await MainActor.run {
            self.setBusy(false)
            self.showAddSteps(needsA: needsA, needsB: needsB, tokenA: tokenA, tokenB: tokenB, pairExists: pairExists)
        }
    }

    private func needsRouterApproval(tokenAddress: String, requiredWei: String) async throws -> Bool {
        var payload = DexPayloads.base()
        payload["tokenAddress"] = tokenAddress
        payload["requiredAmountWei"] = requiredWei
        payload["ownerAddress"] = walletAddress
        let json = try await JsBridge.shared.dexCallAsync(method: "liquidityCheckAllowance", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        return (data["sufficient"] as? Bool) != true
    }

    private func showAddSteps(needsA: Bool, needsB: Bool, tokenA: String, tokenB: String, pairExists: Bool) {
        let L = Localization.shared
        let approveLabel = L.lang("step-approve", fallback: "Approve")
        let addLabel = L.lang("add-liquidity", fallback: "Add Liquidity")
        let symA = DexBridgeResult.sanitizeSymbol(tokenAPicker.symbol())
        let symB = DexBridgeResult.sanitizeSymbol(tokenBPicker.symbol())
        let amountA = text(amountAField)
        let amountB = text(amountBField)
        let release = ReleaseStore.readActive()
        let nativeLeg = tokenA == "Q" ? amountA : (tokenB == "Q" ? amountB : "0")

        let base = ReviewSpec()
            .action(addLabel + " " + symA + " / " + symB)
            .contractAddress(release.router)
            .fromAddress(walletAddress)
            .toAddress(release.router)
            .quantityValue(nativeLeg)
            .tokenQuantityValue(amountA + " " + symA + " + " + amountB + " " + symB)
            .networkText(ReviewSpec.networkText())

        var steps: [TxStep] = []
        if needsA {
            steps.append(approveTokenStep(label: approveLabel + " " + symA, tokenAddress: tokenA,
                review: liquidityApproveReview(action: approveLabel + " " + symA, tokenAddress: tokenA,
                                               tokenQuantity: amountA + " " + symA)))
        }
        if needsB {
            steps.append(approveTokenStep(label: approveLabel + " " + symB, tokenAddress: tokenB,
                review: liquidityApproveReview(action: approveLabel + " " + symB, tokenAddress: tokenB,
                                               tokenQuantity: amountB + " " + symB)))
        }
        let addArgs: () -> [String: Any] = { [weak self] in
            guard let self else { return [:] }
            return [
                "tokenAValue": self.tokenAPicker.tokenValue(),
                "tokenBValue": self.tokenBPicker.tokenValue(),
                "amountA": amountA, "amountB": amountB,
                "decimalsA": self.tokenAPicker.decimals(),
                "decimalsB": self.tokenBPicker.decimals(),
                "slippagePercent": self.slippagePercent(),
                "ownerAddress": self.walletAddress
            ]
        }
        steps.append(TxStep(label: addLabel + " " + symA + " / " + symB, kind: .addLiquidity,
                            pairExists: pairExists, estimatePayload: addArgs,
                            submitMethod: "liquiditySubmitAdd", submitPayload: addArgs))
        openSteps(title: addLabel, base: base, steps: steps)
    }

    /// Desktop approveStep(..., showAsTokenQuantity=true): contract/to =
    /// token, Quantity (Q) "0", "Approval token quantity" = amount.
    private func liquidityApproveReview(action: String, tokenAddress: String, tokenQuantity: String) -> ReviewSpec {
        ReviewSpec()
            .action(action)
            .contractAddress(tokenAddress)
            .contractIsToken(true)
            .toAddress(tokenAddress)
            .quantityLabelKey("send-quantity")
            .quantityValue("0")
            .tokenQuantityLabelKey("approval-token-quantity")
            .tokenQuantityValue(tokenQuantity)
    }

    /// Shared ERC20 approve-toward-router step (liquidity token or LP
    /// token); desktop txKind "approveToken".
    private func approveTokenStep(label: String, tokenAddress: String, review: ReviewSpec) -> TxStep {
        let owner = walletAddress
        let args: [String: Any] = ["tokenAddress": tokenAddress, "ownerAddress": owner]
        return TxStep(label: label, kind: .approveToken, estimatePayload: { args },
                      submitMethod: "liquiditySubmitApprove", submitPayload: { ["tokenAddress": tokenAddress] },
                      reviewOverride: review)
    }

    private func openSteps(title: String, base: ReviewSpec, steps: [TxStep]) {
        let dlg = TxStepsDialogViewController(title: title, walletAddress: walletAddress,
                                              steps: steps, baseReview: base)
        dlg.onClose = { [weak self] in
            guard let self else { return }
            self.stepsDialog = nil
            self.showPositionsPanel()
        }
        stepsDialog = dlg
        dlg.show(from: self)
    }

    // MARK: - Helpers

    private func slippagePercent() -> Double {
        let v = Double(text(slippageField)) ?? 1
        return max(0, min(100, v))
    }

    private func isPositiveDecimal(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: #"^\d*\.?\d+$"#, options: .regularExpression) != nil && (Double(s) ?? 0) > 0
    }

    private func text(_ f: UITextField) -> String {
        f.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func failFlow(_ error: String?) {
        setBusy(false)
        statusLabel.isHidden = true
        if let error, !error.isEmpty {
            DexScreenChrome.presentError(from: self, message: error)
        }
    }

    private static func dictArray(_ any: Any?) -> [[String: Any]] {
        (any as? [[String: Any]]) ?? []
    }
}


// MARK: - Remove-liquidity form (web removeLiquidity.ts)

/// Percent slider + 25/50/75/100 preset chips + live stats (LP tokens
/// burned, the amount of each token received, the LP balance) + the
/// one-time-approval note + Cancel / "Approve & remove". Display math
/// runs on unit-formatted doubles; the exact BigInteger amounts are
/// recomputed by `runRemoveFlow` when the user confirms.
fileprivate final class RemoveLiquidityDialogViewController: ModalDialogViewController {

    var onConfirm: ((Int) -> Void)?

    private let lpUnits: Double
    private let supplyUnits: Double
    private let reserve0Units: Double
    private let reserve1Units: Double
    private let sym0: String
    private let sym1: String

    private var percent = 50
    private let pctLabel = UILabel()
    private let slider = UISlider()
    private var chips: [UIButton] = []
    private let chipValues = [25, 50, 75, 100]
    private var statValues: [UILabel] = []

    init(lpUnits: Double, supplyUnits: Double, reserve0Units: Double,
         reserve1Units: Double, sym0: String, sym1: String) {
        self.lpUnits = lpUnits
        self.supplyUnits = supplyUnits
        self.reserve0Units = reserve0Units
        self.reserve1Units = reserve1Units
        self.sym0 = sym0
        self.sym1 = sym1
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let L = Localization.shared

        let title = UILabel()
        title.text = L.lang("remove-liquidity", fallback: "Remove Liquidity")
        title.font = Typography.boldTitle(17)
        title.textColor = UIColor(named: "colorCommon6") ?? .label
        title.textAlignment = .center

        pctLabel.font = Typography.boldTitle(28)
        pctLabel.textColor = UIColor(named: "colorCommon6") ?? .label
        pctLabel.textAlignment = .center

        slider.minimumValue = 1
        slider.maximumValue = 100
        slider.minimumTrackTintColor = .quantumTeal
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.percent = Int(self.slider.value.rounded())
            self.refresh()
        }, for: .valueChanged)

        for v in chipValues {
            let chip = UIButton(type: .system)
            chip.setTitle("\(v)%", for: .normal)
            chip.titleLabel?.font = Typography.body(13)
            chip.layer.cornerRadius = 6
            chip.layer.borderWidth = 1
            chip.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
            chip.addAction(UIAction { [weak self] _ in
                self?.percent = v
                self?.refresh()
            }, for: .touchUpInside)
            chips.append(chip)
        }
        let chipRow = UIStackView(arrangedSubviews: chips + [UIView()])
        chipRow.axis = .horizontal
        chipRow.spacing = 8

        // Stat rows: label left, live value right (web statRow).
        var statRows: [UIView] = []
        let statNames = [
            L.lang("remove-lp-burned", fallback: "LP tokens burned"),
            L.lang("remove-you-receive", fallback: "You receive [SYM]")
                .replacingOccurrences(of: "[SYM]", with: sym0),
            L.lang("remove-you-receive", fallback: "You receive [SYM]")
                .replacingOccurrences(of: "[SYM]", with: sym1),
            L.lang("remove-your-lp-balance", fallback: "Your LP balance")
        ]
        for name in statNames {
            let n = UILabel()
            n.text = name
            n.font = Typography.body(13)
            n.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel
            let v = UILabel()
            v.font = Typography.body(13)
            v.textColor = UIColor(named: "colorCommon6") ?? .label
            v.textAlignment = .right
            statValues.append(v)
            let row = UIStackView(arrangedSubviews: [n, v])
            row.axis = .horizontal
            row.spacing = 8
            statRows.append(row)
        }

        let note = UILabel()
        note.text = L.lang("remove-approval-note",
            fallback: "The router needs a one-time approval to spend your LP tokens before removing.")
        note.font = Typography.body(12)
        note.textColor = UIColor(rgbHex: 0x9A9AA6)
        note.numberOfLines = 0

        let cancel = GrayPillButton(type: .system)
        cancel.setTitle(L.getCancelByLangValues(), for: .normal)
        cancel.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        let confirm = GreenPillButton(type: .system)
        confirm.setTitle(L.lang("remove-approve-cta", fallback: "Approve & remove"), for: .normal)
        confirm.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let pct = self.percent
            self.dismiss(animated: true) { [onConfirm] in onConfirm?(pct) }
        }, for: .touchUpInside)
        for b in [cancel, confirm] {
            b.heightAnchor.constraint(equalToConstant: 43).isActive = true
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = UIStackView(arrangedSubviews: [spacer, cancel, confirm])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .center

        let statsStack = UIStackView(arrangedSubviews: statRows)
        statsStack.axis = .vertical
        statsStack.spacing = 6

        let stack = UIStackView(arrangedSubviews: [
            title, pctLabel, slider, chipRow, statsStack, note, buttonRow
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(6, after: pctLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            card.widthAnchor.constraint(equalToConstant: 340)
        ])
        view.installPressFeedbackRecursive()
        refresh()
    }

    private func refresh() {
        pctLabel.text = "\(percent)%"
        slider.value = Float(percent)
        for (chip, v) in zip(chips, chipValues) {
            let active = v == percent
            chip.layer.borderColor = (active ? UIColor.quantumTeal
                : UIColor(rgbHex: 0x9A9AA6).withAlphaComponent(0.5)).cgColor
            chip.setTitleColor(active ? .quantumTeal
                : UIColor(rgbHex: 0x9A9AA6), for: .normal)
        }
        let burned = lpUnits * Double(percent) / 100
        let share = supplyUnits > 0 ? burned / supplyUnits : 0
        let values = [burned, reserve0Units * share, reserve1Units * share, lpUnits]
        for (label, value) in zip(statValues, values) {
            label.text = String(format: "%.6f", value)
        }
    }
}
