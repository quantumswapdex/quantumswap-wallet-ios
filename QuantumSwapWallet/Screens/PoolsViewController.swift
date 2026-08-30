// PoolsViewController.swift
// Desktop pools screen (src/app/advanced.ts) / Android
// `PoolsFragment.java`:
//   - list panel (default): pool table (scrolling box, symbols link to
//     the explorer) with a "Create Pair" link below;
//   - form panel: Token A / Token B + a screen-level gas chip (desktop
//     #divCreatePairGasIcon, 2 s debounce on token change) + Create Pair;
//   - one-step plan "Create Pair" (review: contract / to = factory,
//     Quantity (Q) "0") through TxStepsDialogViewController.

import UIKit

public final class PoolsViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    private var walletAddress = ""
    private let listPanel = UIStackView()
    private let formPanel = UIStackView()
    private let poolsStack = UIStackView()
    private let poolsScroll = AutoHorizontalScrollView()
    private let emptyLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var tokenAPicker: DexTokenPickerView!
    private var tokenBPicker: DexTokenPickerView!
    private let createButton = GreenPillButton(type: .system)
    private var gasChip: GasChipController?
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
        title.text = L.lang("pools", fallback: "Pools")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        // ---- List panel -------------------------------------------------
        let listTitle = UILabel()
        listTitle.text = L.lang("all-pools", fallback: "All pools")
        listTitle.font = Typography.boldTitle(16)
        listTitle.textColor = UIColor(named: "colorCommon1") ?? .label
        let refresh = UIButton(type: .system)
        refresh.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refresh.tintColor = UIColor(named: "colorCommon6") ?? .label
        refresh.addTarget(self, action: #selector(loadPools), for: .touchUpInside)
        spinner.hidesWhenStopped = true
        // "Create Pair" lives at the top right of the box (next to
        // the refresh icon) so it is reachable without scrolling to
        // the bottom of the pool list.
        let createLink = DexScreenChrome.makeLink(L.lang("create-pair", fallback: "Create Pair"),
                                                  underline: true, target: self, action: #selector(showCreatePanel))
        let header = UIStackView(arrangedSubviews: [listTitle, UIView(), createLink, refresh, spinner])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8

        emptyLabel.text = L.lang("no-pools", fallback: "No pools yet.")
        emptyLabel.font = Typography.body(13)
        emptyLabel.textColor = UIColor(rgbHex: 0x9A9AA6) // Android colorMutedSecondaryText

        poolsStack.axis = .vertical
        poolsStack.spacing = 4
        poolsScroll.install(content: poolsStack)
        // Cap so the card bottom border stays on screen; overflow
        // scrolls vertically inside the box.
        poolsScroll.capToScreen(reserveBelow: 70)

        listPanel.axis = .vertical
        listPanel.spacing = 10
        [header, emptyLabel, poolsScroll].forEach { listPanel.addArrangedSubview($0) }

        // ---- Form panel -------------------------------------------------
        let createTitle = UILabel()
        createTitle.text = L.lang("create-pair", fallback: "Create Pair")
        createTitle.font = Typography.boldTitle(16)
        createTitle.textColor = UIColor(named: "colorCommon1") ?? .label
        createTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let chipView = GasChipView()
        let titleRow = UIStackView(arrangedSubviews: [createTitle, chipView])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 12
        gasChip = GasChipController(host: self, walletAddress: walletAddress, chip: chipView, kind: .createPair)

        let customLabel = L.lang("custom-contract-address", fallback: "Custom...")
        tokenAPicker = DexTokenPickerView(customLabel: customLabel)
        tokenBPicker = DexTokenPickerView(customLabel: customLabel)
        tokenAPicker.onChanged = { [weak self] in self?.scheduleGasEstimate() }
        tokenBPicker.onChanged = { [weak self] in self?.scheduleGasEstimate() }
        createButton.setTitle(L.lang("create-pair", fallback: "Create Pair"), for: .normal)
        createButton.addTarget(self, action: #selector(startCreate), for: .touchUpInside)
        // Same footprint as the Send screen's primary button.
        createButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        createButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let createRow = UIStackView(arrangedSubviews: [UIView(), createButton, UIView()])
        createRow.axis = .horizontal
        createRow.distribution = .equalCentering

        statusLabel.font = Typography.body(12)
        statusLabel.textColor = UIColor(rgbHex: 0xFBBF24) // Android quantumAmber
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        formPanel.axis = .vertical
        formPanel.spacing = 10
        formPanel.isHidden = true
        [titleRow,
         DexScreenChrome.makeLabel(L.lang("token-a", fallback: "Token A")), tokenAPicker,
         DexScreenChrome.makeLabel(L.lang("token-b", fallback: "Token B")), tokenBPicker,
         statusLabel, createRow].forEach { formPanel.addArrangedSubview($0) }

        let content = UIStackView(arrangedSubviews: [title, DexScreenChrome.makeDivider(), listPanel, formPanel])
        content.axis = .vertical
        content.spacing = 10

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
        loadPools()
        view.installPressFeedbackRecursive()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stepsDialog?.dismissSteps()
        stepsDialog = nil
    }

    /// Desktop: back from the create form returns to the pool list;
    /// back from the list leaves the screen.
    @objc private func tapBack() {
        if !formPanel.isHidden {
            showListPanel()
            return
        }
        (parent as? HomeViewController)?.beginTransactionNow(AdvancedViewController())
    }

    // MARK: - Panels

    /// Desktop showPoolsCreatePanel: swap to the form with a clean slate.
    @objc private func showCreatePanel() {
        tokenAPicker.restoreSelection(nil)
        tokenBPicker.restoreSelection(nil)
        statusLabel.isHidden = true
        gasChip?.reset()
        listPanel.isHidden = true
        formPanel.isHidden = false
    }

    private func showListPanel() {
        formPanel.isHidden = true
        listPanel.isHidden = false
        loadPools()
    }

    // MARK: - Pool list

    // Web app poolExplorer: server pages of 20 with a sort toggle and a
    // "Load all pairs" action when the Swap Read API serves the release.
    private var poolsPage = 1
    private var poolsSort = "liquidity"
    private var poolsAll = false

    @objc private func loadPools() {
        loadPoolsPage(page: poolsPage, all: poolsAll)
    }

    private func loadPoolsPage(page: Int, all: Bool) {
        setBusy(true)
        let sort = poolsSort
        Task { [weak self] in
            guard let self else { return }
            do {
                var payload = DexPayloads.base()
                payload["page"] = page
                payload["sort"] = sort
                if all { payload["all"] = true }
                let json = try await JsBridge.shared.dexCallAsync(method: "liquidityListPools", payload: payload)
                let data = try DexBridgeResult.unwrapData(json)
                let pools: [[String: Any]] = {
                    if let arr = data["pools"] as? [[String: Any]] { return arr }
                    if let arr = data["pools"] as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
                    return []
                }()
                await MainActor.run {
                    self.setBusy(false)
                    self.renderPools(pools, meta: data)
                }
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func renderPools(_ pools: [[String: Any]], meta: [String: Any]) {
        let L = Localization.shared
        let api = (meta["source"] as? String) == "api"
        func num(_ key: String, _ fallback: Int) -> Int {
            (meta[key] as? NSNumber)?.intValue ?? fallback
        }
        poolsPage = max(1, num("page", 1))
        let pageCount = num("pageCount", 1)
        let total = num("totalItems", pools.count)
        renderPoolRows(pools)
        emptyLabel.text = api
            ? L.lang("pools-empty-api", fallback: "No pools found yet. Try loading all pairs, or create one.")
            : L.lang("no-pools", fallback: "No pools yet.")
        guard api else { return }
        poolsStack.insertArrangedSubview(buildPoolsToolbar(indexedBlock: num("indexedBlock", 0)), at: 0)
        poolsScroll.isHidden = false
        if !poolsAll, pageCount > 1 {
            poolsStack.addArrangedSubview(buildPager(page: poolsPage, pageCount: pageCount, total: total))
        }
    }

    /// "Indexed at block N" + sort toggle + "Load all pairs".
    private func buildPoolsToolbar(indexedBlock: Int) -> UIView {
        let L = Localization.shared
        let indexed = UILabel()
        indexed.text = L.lang("pools-indexed-at", fallback: "Indexed at block [BLOCK]")
            .replacingOccurrences(of: "[BLOCK]", with: String(indexedBlock))
        indexed.font = Typography.body(12)
        indexed.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel

        let sortToggle = linkButton(poolsSort == "liquidity"
            ? L.lang("pools-sort-liquidity", fallback: "Sort: liquidity")
            : L.lang("pools-sort-newest", fallback: "Sort: newest"))
        sortToggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.poolsSort = self.poolsSort == "liquidity" ? "newest" : "liquidity"
            self.poolsAll = false
            self.loadPoolsPage(page: 1, all: false)
        }, for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [sortToggle])
        if !poolsAll {
            let loadAll = linkButton(L.lang("pools-load-all", fallback: "Load all pairs"))
            loadAll.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.poolsAll = true
                self.loadPoolsPage(page: 1, all: true)
            }, for: .touchUpInside)
            actions.addArrangedSubview(loadAll)
        }
        actions.addArrangedSubview(UIView())
        actions.axis = .horizontal
        actions.spacing = 16
        let bar = UIStackView(arrangedSubviews: [indexed, actions])
        bar.axis = .vertical
        bar.spacing = 4
        return bar
    }

    private func buildPager(page: Int, pageCount: Int, total: Int) -> UIView {
        let L = Localization.shared
        let prev = linkButton("\u{2039} " + L.lang("previous", fallback: "Previous"))
        prev.isEnabled = page > 1
        prev.alpha = page > 1 ? 1 : 0.4
        prev.addAction(UIAction { [weak self] _ in
            guard let self, self.poolsPage > 1 else { return }
            self.loadPoolsPage(page: self.poolsPage - 1, all: false)
        }, for: .touchUpInside)
        let label = UILabel()
        label.text = L.lang("pools-page-of", fallback: "Page [PAGE] of [COUNT] · [TOTAL] pools")
            .replacingOccurrences(of: "[PAGE]", with: String(page))
            .replacingOccurrences(of: "[COUNT]", with: String(pageCount))
            .replacingOccurrences(of: "[TOTAL]", with: String(total))
        label.font = Typography.body(12)
        label.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel
        let next = linkButton(L.lang("next", fallback: "Next") + " \u{203a}")
        next.isEnabled = page < pageCount
        next.alpha = page < pageCount ? 1 : 0.4
        next.addAction(UIAction { [weak self] _ in
            guard let self, self.poolsPage < pageCount else { return }
            self.loadPoolsPage(page: self.poolsPage + 1, all: false)
        }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [prev, label, next, UIView()])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    private func linkButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setAttributedTitle(NSAttributedString(string: title, attributes: [
            .font: Typography.body(13), .foregroundColor: UIColor.quantumTeal,
            .underlineStyle: NSUnderlineStyle.single.rawValue]), for: .normal)
        return b
    }

    private func renderPoolRows(_ pools: [[String: Any]]) {
        poolsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !pools.isEmpty
        poolsScroll.isHidden = pools.isEmpty
        let L = Localization.shared
        for pool in pools {
            let row = UIStackView()
            row.axis = .vertical
            row.spacing = 4
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)

            let sym0 = DexBridgeResult.sanitizeSymbol(pool["symbol0"] as? String)
            let sym1 = DexBridgeResult.sanitizeSymbol(pool["symbol1"] as? String)
            let token0 = (pool["token0"] as? String) ?? ""
            let token1 = (pool["token1"] as? String) ?? ""
            // Symbols link to the token contract on the block explorer.
            let pair = ExplorerLinks.makePairLabel(
                symA: sym0.isEmpty ? DexBridgeResult.shortAddr(token0) : sym0, tokenA: token0,
                symB: sym1.isEmpty ? DexBridgeResult.shortAddr(token1) : sym1, tokenB: token1)

            let addr = UILabel()
            addr.text = DexBridgeResult.shortAddr(pool["pairAddress"] as? String)
            addr.font = Typography.body(12)
            addr.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel

            let dec0 = (pool["decimals0"] as? Int) ?? (pool["decimals0"] as? NSNumber)?.intValue ?? 18
            let dec1 = (pool["decimals1"] as? Int) ?? (pool["decimals1"] as? NSNumber)?.intValue ?? 18
            let reserves = UILabel()
            reserves.text = L.lang("pool-reserves", fallback: "Reserves") + ": "
                + CoinUtils.formatUnits(pool["reserve0"] as? String, decimals: dec0) + " / "
                + CoinUtils.formatUnits(pool["reserve1"] as? String, decimals: dec1)
            reserves.font = Typography.body(13)
            reserves.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel

            [pair, addr, reserves, DexScreenChrome.makeDivider()].forEach { row.addArrangedSubview($0) }
            poolsStack.addArrangedSubview(row)
        }
    }

    // MARK: - Gas chip (desktop scheduleCreatePairGasEstimate)

    private func createPairPayload() -> [String: Any] {
        ["tokenAValue": tokenAPicker.tokenValue(), "tokenBValue": tokenBPicker.tokenValue(),
         "ownerAddress": walletAddress]
    }

    private func scheduleGasEstimate() {
        gasChip?.schedule { [weak self] in
            guard let self else { return nil }
            let a = self.tokenAPicker.tokenValue(), b = self.tokenBPicker.tokenValue()
            guard !a.isEmpty, !b.isEmpty, a.caseInsensitiveCompare(b) != .orderedSame else { return nil }
            return self.createPairPayload()
        }
    }

    // MARK: - Create

    @objc private func startCreate() {
        let L = Localization.shared
        if tokenAPicker.isEmpty || tokenBPicker.isEmpty {
            DexScreenChrome.presentError(from: self, message: L.lang("select-both-tokens", fallback: "Select both tokens."))
            return
        }
        if tokenAPicker.tokenValue().caseInsensitiveCompare(tokenBPicker.tokenValue()) == .orderedSame {
            DexScreenChrome.presentError(from: self, message: L.err("identicalTokens", fallback: "Token A and Token B must differ."))
            return
        }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await DexScreenChrome.resolveMeta(self.tokenAPicker, walletAddress: self.walletAddress)
                try await DexScreenChrome.resolveMeta(self.tokenBPicker, walletAddress: self.walletAddress)
                var payload = DexPayloads.base()
                payload["tokenAValue"] = self.tokenAPicker.tokenValue()
                payload["tokenBValue"] = self.tokenBPicker.tokenValue()
                let json = try await JsBridge.shared.dexCallAsync(method: "liquidityGetPairInfo", payload: payload)
                let data = try DexBridgeResult.unwrapData(json)
                if (data["exists"] as? Bool) == true {
                    await MainActor.run {
                        self.failFlow(L.lang("pair-exists", fallback: "A pool already exists for this pair."))
                    }
                    return
                }
                await MainActor.run {
                    self.setBusy(false)
                    self.showCreateSteps()
                }
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    /// Desktop createPair flow: one "Create Pair" step; review rows
    /// contract/to = factory, Quantity (Q) "0".
    private func showCreateSteps() {
        let L = Localization.shared
        let label = L.lang("create-pair", fallback: "Create Pair")
        let release = ReleaseStore.readActive()
        let symA = DexBridgeResult.sanitizeSymbol(tokenAPicker.symbol())
        let symB = DexBridgeResult.sanitizeSymbol(tokenBPicker.symbol())
        let base = ReviewSpec()
            .action(label + ": " + symA + " / " + symB)
            .contractAddress(release.factory)
            .fromAddress(walletAddress)
            .toAddress(release.factory)
            .quantityValue("0")
            .networkText(ReviewSpec.networkText())
        let a = tokenAPicker.tokenValue(), b = tokenBPicker.tokenValue()
        let owner = walletAddress
        let steps = [TxStep(label: label, kind: .createPair,
                            estimatePayload: { ["tokenAValue": a, "tokenBValue": b, "ownerAddress": owner] },
                            submitMethod: "poolsSubmitCreatePair",
                            submitPayload: { ["tokenAValue": a, "tokenBValue": b] })]
        let dlg = TxStepsDialogViewController(title: label, walletAddress: walletAddress,
                                              steps: steps, baseReview: base)
        dlg.onClose = { [weak self] in
            guard let self else { return }
            self.stepsDialog = nil
            self.showListPanel()
        }
        stepsDialog = dlg
        dlg.show(from: self)
    }

    // MARK: - Helpers

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
}
