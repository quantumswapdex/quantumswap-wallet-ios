// LiquidityViewController.swift
// Port of Android `LiquidityFragment.java`: positions list + add form.

import UIKit

public final class LiquidityViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    private static let pollMax = 24
    private static let pollIntervalNs: UInt64 = 5_000_000_000

    private var walletAddress = ""
    private let positionsStack = UIStackView()
    private let noPositionsLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var tokenAPicker: DexTokenPickerView!
    private var tokenBPicker: DexTokenPickerView!
    private let amountAField = DexScreenChrome.makeField(placeholder: "", keyboard: .decimalPad)
    private let amountBField = DexScreenChrome.makeField(placeholder: "", keyboard: .decimalPad)
    private let slippageField = DexScreenChrome.makeField(placeholder: "1", keyboard: .decimalPad)
    private let addButton = GreenPillButton(type: .system)

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "colorBackground") ?? .systemBackground
        let L = Localization.shared
        walletAddress = DexScreenChrome.currentWalletAddress()

        let backBar = makeBackBar(action: #selector(tapBack))
        let title = UILabel()
        title.text = L.lang("liquidity", fallback: "Liquidity")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        let positionsTitle = UILabel()
        positionsTitle.text = L.lang("your-positions", fallback: "Your positions")
        positionsTitle.font = Typography.boldTitle(16)
        positionsTitle.textColor = UIColor(named: "colorCommon6") ?? .label

        let refresh = UIButton(type: .system)
        refresh.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refresh.tintColor = UIColor(named: "colorCommon6") ?? .label
        refresh.addTarget(self, action: #selector(loadPositions), for: .touchUpInside)

        let headerRow = UIStackView(arrangedSubviews: [positionsTitle, UIView(), refresh, spinner])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 8
        spinner.hidesWhenStopped = true

        positionsStack.axis = .vertical
        positionsStack.spacing = 4
        noPositionsLabel.text = L.lang("no-positions",
            fallback: "You have no liquidity positions.")
        noPositionsLabel.font = Typography.body(13)
        noPositionsLabel.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel
        noPositionsLabel.numberOfLines = 0

        let addTitle = UILabel()
        addTitle.text = L.lang("add-liquidity", fallback: "Add Liquidity")
        addTitle.font = Typography.boldTitle(16)
        addTitle.textColor = UIColor(named: "colorCommon6") ?? .label

        let customLabel = L.lang("custom-contract-address", fallback: "Custom...")
        tokenAPicker = DexTokenPickerView(customLabel: customLabel)
        tokenBPicker = DexTokenPickerView(customLabel: customLabel)
        amountAField.placeholder = L.lang("amount", fallback: "Amount")
        amountBField.placeholder = L.lang("amount", fallback: "Amount")
        slippageField.text = "1"
        addButton.setTitle(L.lang("add-liquidity", fallback: "Add Liquidity"), for: .normal)
        addButton.addTarget(self, action: #selector(startAdd), for: .touchUpInside)

        statusLabel.font = Typography.body(12)
        statusLabel.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        let content = UIStackView(arrangedSubviews: [
            backBar, title, DexScreenChrome.makeDivider(),
            headerRow, noPositionsLabel, positionsStack,
            DexScreenChrome.makeDivider(),
            addTitle,
            DexScreenChrome.makeLabel(L.lang("token-a", fallback: "Token A")),
            tokenAPicker, amountAField,
            DexScreenChrome.makeLabel(L.lang("token-b", fallback: "Token B")),
            tokenBPicker, amountBField,
            DexScreenChrome.makeLabel(L.lang("slippage", fallback: "Slippage")),
            slippageField, addButton, statusLabel
        ])
        content.axis = .vertical
        content.spacing = 10
        content.setCustomSpacing(8, after: backBar)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24)
        ])

        Task { [weak self] in
            guard let self else { return }
            let tokens = await DexScreenChrome.loadRecognizedTokens(for: self.walletAddress)
            await MainActor.run {
                self.tokenAPicker.setTokens(tokens)
                self.tokenBPicker.setTokens(tokens)
            }
        }
        loadPositions()
        view.installPressFeedbackRecursive()
    }

    @objc private func tapBack() {
        (parent as? HomeViewController)?.beginTransactionNow(AdvancedViewController())
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
                let json = try await JsBridge.shared.dexCallAsync(
                    method: "liquidityListPositions", payload: payload)
                let data = try DexBridgeResult.unwrapData(json)
                let positions = Self.dictArray(data["positions"])
                await MainActor.run {
                    self.setBusy(false)
                    self.renderPositions(positions)
                }
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func renderPositions(_ positions: [[String: Any]]) {
        positionsStack.arrangedSubviews.forEach {
            positionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        noPositionsLabel.isHidden = !positions.isEmpty
        let L = Localization.shared
        for pos in positions {
            let row = UIStackView()
            row.axis = .vertical
            row.spacing = 4

            let sym0 = DexBridgeResult.sanitizeSymbol(pos["symbol0"] as? String)
            let sym1 = DexBridgeResult.sanitizeSymbol(pos["symbol1"] as? String)
            let token0 = (pos["token0"] as? String) ?? ""
            let token1 = (pos["token1"] as? String) ?? ""
            let pairLabel = (sym0.isEmpty ? DexBridgeResult.shortAddr(token0) : sym0)
                + " / " + (sym1.isEmpty ? DexBridgeResult.shortAddr(token1) : sym1)

            let pair = UILabel()
            pair.text = pairLabel
            pair.font = Typography.boldTitle(15)
            pair.textColor = UIColor(named: "colorCommon6") ?? .label

            let lp = UILabel()
            lp.text = L.lang("lp-tokens", fallback: "LP tokens") + ": "
                + CoinUtils.formatUnits(pos["lpBalance"] as? String, decimals: 18)
            lp.font = Typography.body(13)
            lp.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel

            let dec0 = (pos["decimals0"] as? Int)
                ?? (pos["decimals0"] as? NSNumber)?.intValue ?? 18
            let dec1 = (pos["decimals1"] as? Int)
                ?? (pos["decimals1"] as? NSNumber)?.intValue ?? 18
            let reserves = UILabel()
            reserves.text = L.lang("pool-reserves", fallback: "Reserves") + ": "
                + CoinUtils.formatUnits(pos["reserve0"] as? String, decimals: dec0)
                + " / "
                + CoinUtils.formatUnits(pos["reserve1"] as? String, decimals: dec1)
            reserves.font = Typography.body(13)
            reserves.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel

            let remove = GreenPillButton(type: .system)
            remove.setTitle(L.lang("remove-liquidity", fallback: "Remove Liquidity"), for: .normal)
            remove.addAction(UIAction { [weak self] _ in
                self?.promptRemove(pos)
            }, for: .touchUpInside)

            row.addArrangedSubview(pair)
            row.addArrangedSubview(lp)
            row.addArrangedSubview(reserves)
            row.addArrangedSubview(remove)
            row.addArrangedSubview(DexScreenChrome.makeDivider())
            positionsStack.addArrangedSubview(row)
        }
    }

    private func promptRemove(_ pos: [String: Any]) {
        let L = Localization.shared
        let alert = UIAlertController(
            title: L.lang("remove-liquidity", fallback: "Remove Liquidity"),
            message: L.lang("remove-percent", fallback: "Amount to remove"),
            preferredStyle: .alert)
        alert.addTextField { tf in
            tf.keyboardType = .numberPad
            tf.text = "100"
            tf.textAlignment = .center
        }
        alert.addAction(UIAlertAction(title: L.getCancelByLangValues(), style: .cancel))
        alert.addAction(UIAlertAction(title: L.getOkByLangValues(), style: .default) { [weak self] _ in
            guard let self else { return }
            let pct = Int(alert.textFields?.first?.text?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? "") ?? 0
            if pct <= 0 || pct > 100 {
                DexScreenChrome.presentError(from: self, message: L.err(
                    "invalidQuantity", fallback: "Enter a valid quantity."))
                return
            }
            DexUnlockPrompt.show(from: self) { [weak self] _ in
                self?.runRemoveFlow(pos, percent: pct)
            }
        })
        present(alert, animated: true)
    }

    private func runRemoveFlow(_ pos: [String: Any], percent: Int) {
        setBusy(true)
        let owner = walletAddress
        let slip = slippagePercent()
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try DexUnlockPrompt.loadWalletKeys(walletAddress: owner)
                var priv = loaded.0
                var pub = loaded.1
                defer {
                    priv.resetBytes(in: 0..<priv.count)
                    pub.resetBytes(in: 0..<pub.count)
                }
                let lpBalance = (pos["lpBalance"] as? String) ?? "0"
                let liquidity = DexBigInt.divSmall(
                    DexBigInt.mulSmall(lpBalance, percent), 100)
                guard DexBigInt.isPositive(liquidity) else {
                    throw JsEngineError.callFailed("Nothing to remove")
                }
                var totalSupply = (pos["totalSupply"] as? String) ?? "1"
                if !DexBigInt.isPositive(totalSupply) { totalSupply = "1" }
                let reserve0 = (pos["reserve0"] as? String) ?? "0"
                let reserve1 = (pos["reserve1"] as? String) ?? "0"
                let slipBps = Int((slip * 100).rounded())
                let keep = String(10_000 - slipBps)
                let amountAMin = DexBigInt.mulDiv(
                    DexBigInt.mulDiv(reserve0, liquidity, totalSupply), keep, "10000")
                let amountBMin = DexBigInt.mulDiv(
                    DexBigInt.mulDiv(reserve1, liquidity, totalSupply), keep, "10000")
                let pairAddress = (pos["pairAddress"] as? String) ?? ""

                var keyed = DexPayloads.withKeys(privKey: priv, pubKey: pub)
                keyed.payload["tokenAAddress"] = (pos["token0"] as? String) ?? ""
                keyed.payload["tokenBAddress"] = (pos["token1"] as? String) ?? ""
                keyed.payload["liquidityWei"] = liquidity
                keyed.payload["amountAMinWei"] = amountAMin
                keyed.payload["amountBMinWei"] = amountBMin
                keyed.payload["ownerAddress"] = owner
                keyed.payload["gasLimit"] = 300_000

                try await self.ensureAllowanceThen(
                    priv: priv, pub: pub,
                    tokenAddress: pairAddress,
                    requiredWei: liquidity) {
                    try await self.submitDex(
                        method: "liquiditySubmitRemove",
                        keyed: keyed,
                        title: Localization.shared.lang(
                            "remove-liquidity", fallback: "Remove Liquidity"))
                }
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    // MARK: - Add

    @objc private func startAdd() {
        let L = Localization.shared
        let amountA = text(amountAField)
        let amountB = text(amountBField)
        if tokenAPicker.tokenValue().caseInsensitiveCompare(tokenBPicker.tokenValue())
            == .orderedSame {
            DexScreenChrome.presentError(from: self, message: L.err(
                "identicalTokens", fallback: "Token A and Token B must differ."))
            return
        }
        if !isPositiveDecimal(amountA) || !isPositiveDecimal(amountB) {
            DexScreenChrome.presentError(from: self, message: L.err(
                "invalidQuantity", fallback: "Enter a valid quantity."))
            return
        }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.resolveMeta(self.tokenAPicker)
                try await self.resolveMeta(self.tokenBPicker)
                try await self.checkPairThenAdd()
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func resolveMeta(_ picker: DexTokenPickerView) async throws {
        guard picker.needsMetadata() else { return }
        let addr = picker.tokenValue()
        var payload = DexPayloads.base()
        payload["contractAddress"] = addr
        payload["ownerAddress"] = walletAddress
        let json = try await JsBridge.shared.dexCallAsync(
            method: "swapGetTokenMetadata", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        await MainActor.run {
            picker.setResolvedMeta(
                address: (data["contractAddress"] as? String) ?? addr,
                symbol: (data["symbol"] as? String) ?? "",
                decimals: (data["decimals"] as? Int)
                    ?? (data["decimals"] as? NSNumber)?.intValue ?? 18)
        }
    }

    private func checkPairThenAdd() async throws {
        var payload = DexPayloads.base()
        payload["tokenAValue"] = tokenAPicker.tokenValue()
        payload["tokenBValue"] = tokenBPicker.tokenValue()
        payload["ownerAddress"] = walletAddress
        let json = try await JsBridge.shared.dexCallAsync(
            method: "liquidityGetPairInfo", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        let exists = (data["exists"] as? Bool) ?? false
        let pair = data["pair"] as? [String: Any]
        let emptyPool = exists
            && (pair?["reserve0"] as? String) == "0"
            && (pair?["reserve1"] as? String) == "0"
        if !exists || emptyPool {
            let ok: Bool = await withCheckedContinuation { cont in
                Task { @MainActor in
                    let L = Localization.shared
                    let dlg = ConfirmDialogViewController(
                        title: L.lang("add-liquidity", fallback: "Add Liquidity"),
                        message: L.lang("first-provider-warn",
                            fallback: "This pool is empty. You are the first liquidity provider: the ratio of the amounts you add sets the initial price of this pair."))
                    dlg.onConfirm = { cont.resume(returning: true) }
                    dlg.onCancel = { cont.resume(returning: false) }
                    self.present(dlg, animated: true)
                }
            }
            if !ok {
                await MainActor.run { self.failFlow(nil) }
                return
            }
        }
        try await unlockThenAdd()
    }

    private func unlockThenAdd() async throws {
        let keys: (Data, Data)
        do {
            keys = try await DexUnlockPrompt.unlockAndLoadKeys(
                from: self, walletAddress: walletAddress)
        } catch is CancellationError {
            await MainActor.run { self.failFlow(nil) }
            return
        }
        var priv = keys.0
        var pub = keys.1
        defer {
            priv.resetBytes(in: 0..<priv.count)
            pub.resetBytes(in: 0..<pub.count)
        }
        try await approveSideAThen(priv: priv, pub: pub)
    }

    private func approveSideAThen(priv: Data, pub: Data) async throws {
        let tokenA = tokenAPicker.tokenValue()
        if tokenA == "Q" {
            try await approveSideBThen(priv: priv, pub: pub)
            return
        }
        let required = CoinUtils.parseUnits(text(amountAField),
            decimals: tokenAPicker.decimals())
        try await ensureAllowanceThen(priv: priv, pub: pub,
            tokenAddress: tokenA, requiredWei: required) {
            try await self.approveSideBThen(priv: priv, pub: pub)
        }
    }

    private func approveSideBThen(priv: Data, pub: Data) async throws {
        let tokenB = tokenBPicker.tokenValue()
        if tokenB == "Q" {
            try await submitAdd(priv: priv, pub: pub)
            return
        }
        let required = CoinUtils.parseUnits(text(amountBField),
            decimals: tokenBPicker.decimals())
        try await ensureAllowanceThen(priv: priv, pub: pub,
            tokenAddress: tokenB, requiredWei: required) {
            try await self.submitAdd(priv: priv, pub: pub)
        }
    }

    private func submitAdd(priv: Data, pub: Data) async throws {
        var keyed = DexPayloads.withKeys(privKey: priv, pubKey: pub)
        keyed.payload["tokenAValue"] = tokenAPicker.tokenValue()
        keyed.payload["tokenBValue"] = tokenBPicker.tokenValue()
        keyed.payload["amountA"] = text(amountAField)
        keyed.payload["amountB"] = text(amountBField)
        keyed.payload["decimalsA"] = tokenAPicker.decimals()
        keyed.payload["decimalsB"] = tokenBPicker.decimals()
        keyed.payload["slippagePercent"] = slippagePercent()
        keyed.payload["ownerAddress"] = walletAddress
        keyed.payload["gasLimit"] = 300_000
        try await submitDex(method: "liquiditySubmitAdd", keyed: keyed,
            title: Localization.shared.lang("add-liquidity", fallback: "Add Liquidity"))
    }

    // MARK: - Shared approve/poll

    private func ensureAllowanceThen(priv: Data, pub: Data,
        tokenAddress: String, requiredWei: String,
        onReady: @escaping () async throws -> Void) async throws {
        var payload = DexPayloads.base()
        payload["tokenAddress"] = tokenAddress
        payload["requiredAmountWei"] = requiredWei
        payload["ownerAddress"] = walletAddress
        let json = try await JsBridge.shared.dexCallAsync(
            method: "liquidityCheckAllowance", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        if (data["sufficient"] as? Bool) == true {
            try await onReady()
            return
        }
        await MainActor.run {
            self.setStatus(Localization.shared.lang("step-approve", fallback: "Approve")
                + ": " + DexBridgeResult.shortAddr(tokenAddress))
        }
        var approve = DexPayloads.withKeys(privKey: priv, pubKey: pub)
        approve.payload["tokenAddress"] = tokenAddress
        approve.payload["gasLimit"] = 84_000
        _ = try await JsBridge.shared.dexCallAsync(
            method: "liquiditySubmitApprove", payload: approve.payload,
            privKey: approve.privKey, pubKey: approve.pubKey)
        await MainActor.run {
            self.setStatus(Localization.shared.lang("swap-approval-status-pending",
                fallback: "Transaction is still pending..."))
        }
        try await pollAllowance(tokenAddress: tokenAddress, requiredWei: requiredWei,
            attempt: 0, onReady: onReady)
    }

    private func pollAllowance(tokenAddress: String, requiredWei: String,
        attempt: Int, onReady: @escaping () async throws -> Void) async throws {
        if attempt >= Self.pollMax {
            await MainActor.run {
                self.failFlow(Localization.shared.lang("swap-approval-may-close",
                    fallback: "You may close this dialog, the transaction for approval has already been submitted."))
            }
            return
        }
        try await Task.sleep(nanoseconds: Self.pollIntervalNs)
        var payload = DexPayloads.base()
        payload["tokenAddress"] = tokenAddress
        payload["requiredAmountWei"] = requiredWei
        payload["ownerAddress"] = walletAddress
        do {
            let json = try await JsBridge.shared.dexCallAsync(
                method: "liquidityCheckAllowance", payload: payload)
            let data = try DexBridgeResult.unwrapData(json)
            if (data["sufficient"] as? Bool) == true {
                try await onReady()
            } else {
                try await pollAllowance(tokenAddress: tokenAddress,
                    requiredWei: requiredWei, attempt: attempt + 1, onReady: onReady)
            }
        } catch {
            try await pollAllowance(tokenAddress: tokenAddress,
                requiredWei: requiredWei, attempt: attempt + 1, onReady: onReady)
        }
    }

    private func submitDex(method: String, keyed: DexPayloads.Keyed,
        title: String) async throws {
        await MainActor.run {
            self.setStatus(Localization.shared.getSubmittingTransactionByLangValues())
        }
        let json = try await JsBridge.shared.dexCallAsync(
            method: method, payload: keyed.payload,
            privKey: keyed.privKey, pubKey: keyed.pubKey)
        let data = try DexBridgeResult.unwrapData(json)
        let txHash = (data["txHash"] as? String) ?? ""
        await MainActor.run {
            self.setBusy(false)
            self.clearStatus()
            let dlg = MessageInformationDialogViewController(
                title: title,
                message: Localization.shared.lang("transaction-submitted",
                    fallback: "Transaction submitted.") + "\n\n" + txHash)
            dlg.onClose = { [weak self] in self?.loadPositions() }
            self.present(dlg, animated: true)
        }
    }

    // MARK: - Helpers

    private func slippagePercent() -> Double {
        let v = Double(text(slippageField)) ?? 1
        return max(0, min(100, v))
    }

    private func isPositiveDecimal(_ s: String) -> Bool {
        guard !s.isEmpty,
        s.range(of: #"^\d*\.?\d+$"#, options: .regularExpression) != nil,
        let d = Double(s) else { return false }
        return d > 0
    }

    private func text(_ f: UITextField) -> String {
        f.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        addButton.isEnabled = !busy
    }

    private func setStatus(_ message: String) {
        statusLabel.text = message
        statusLabel.isHidden = false
    }

    private func clearStatus() { statusLabel.isHidden = true }

    private func failFlow(_ error: String?) {
        setBusy(false)
        clearStatus()
        if let error, !error.isEmpty {
            DexScreenChrome.presentError(from: self, message: error)
        }
    }

    private static func dictArray(_ any: Any?) -> [[String: Any]] {
        if let arr = any as? [[String: Any]] { return arr }
        if let arr = any as? [Any] {
            return arr.compactMap { $0 as? [String: Any] }
        }
        return []
    }
}
