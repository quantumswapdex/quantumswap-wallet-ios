// PoolsViewController.swift
// Port of Android `PoolsFragment.java`: factory pool list + create pair.

import UIKit

public final class PoolsViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    private var walletAddress = ""
    private let poolsStack = UIStackView()
    private let emptyLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var tokenAPicker: DexTokenPickerView!
    private var tokenBPicker: DexTokenPickerView!
    private let createButton = GreenPillButton(type: .system)

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "colorBackground") ?? .systemBackground
        let L = Localization.shared
        walletAddress = DexScreenChrome.currentWalletAddress()

        let backBar = makeBackBar(action: #selector(tapBack))
        let title = UILabel()
        title.text = L.lang("pools", fallback: "Pools")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        let listTitle = UILabel()
        listTitle.text = L.lang("all-pools", fallback: "All pools")
        listTitle.font = Typography.boldTitle(16)
        listTitle.textColor = UIColor(named: "colorCommon6") ?? .label

        let refresh = UIButton(type: .system)
        refresh.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refresh.tintColor = UIColor(named: "colorCommon6") ?? .label
        refresh.addTarget(self, action: #selector(loadPools), for: .touchUpInside)
        spinner.hidesWhenStopped = true

        let header = UIStackView(arrangedSubviews: [listTitle, UIView(), refresh, spinner])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8

        poolsStack.axis = .vertical
        poolsStack.spacing = 4
        emptyLabel.text = L.lang("no-pools", fallback: "No pools yet.")
        emptyLabel.font = Typography.body(13)
        emptyLabel.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel

        let createTitle = UILabel()
        createTitle.text = L.lang("create-pair", fallback: "Create Pair")
        createTitle.font = Typography.boldTitle(16)
        createTitle.textColor = UIColor(named: "colorCommon6") ?? .label

        let customLabel = L.lang("custom-contract-address", fallback: "Custom...")
        tokenAPicker = DexTokenPickerView(customLabel: customLabel)
        tokenBPicker = DexTokenPickerView(customLabel: customLabel)
        createButton.setTitle(L.lang("create-pair", fallback: "Create Pair"), for: .normal)
        createButton.addTarget(self, action: #selector(startCreate), for: .touchUpInside)

        statusLabel.font = Typography.body(12)
        statusLabel.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        let content = UIStackView(arrangedSubviews: [
            backBar, title, DexScreenChrome.makeDivider(),
            header, emptyLabel, poolsStack,
            DexScreenChrome.makeDivider(),
            createTitle,
            DexScreenChrome.makeLabel(L.lang("token-a", fallback: "Token A")),
            tokenAPicker,
            DexScreenChrome.makeLabel(L.lang("token-b", fallback: "Token B")),
            tokenBPicker, createButton, statusLabel
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
        loadPools()
        view.installPressFeedbackRecursive()
    }

    @objc private func tapBack() {
        (parent as? HomeViewController)?.beginTransactionNow(AdvancedViewController())
    }

    @objc private func loadPools() {
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let json = try await JsBridge.shared.dexCallAsync(
                    method: "liquidityListPools", payload: DexPayloads.base())
                let data = try DexBridgeResult.unwrapData(json)
                let pools: [[String: Any]] = {
                    if let arr = data["pools"] as? [[String: Any]] { return arr }
                    if let arr = data["pools"] as? [Any] {
                        return arr.compactMap { $0 as? [String: Any] }
                    }
                    return []
                }()
                await MainActor.run {
                    self.setBusy(false)
                    self.renderPools(pools)
                }
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func renderPools(_ pools: [[String: Any]]) {
        poolsStack.arrangedSubviews.forEach {
            poolsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        emptyLabel.isHidden = !pools.isEmpty
        let L = Localization.shared
        for pool in pools {
            let row = UIStackView()
            row.axis = .vertical
            row.spacing = 4

            let sym0 = DexBridgeResult.sanitizeSymbol(pool["symbol0"] as? String)
            let sym1 = DexBridgeResult.sanitizeSymbol(pool["symbol1"] as? String)
            let token0 = (pool["token0"] as? String) ?? ""
            let token1 = (pool["token1"] as? String) ?? ""
            let pair = UILabel()
            pair.text = (sym0.isEmpty ? DexBridgeResult.shortAddr(token0) : sym0)
                + " / " + (sym1.isEmpty ? DexBridgeResult.shortAddr(token1) : sym1)
            pair.font = Typography.boldTitle(15)
            pair.textColor = UIColor(named: "colorCommon6") ?? .label

            let addr = UILabel()
            addr.text = DexBridgeResult.shortAddr(pool["pairAddress"] as? String)
            addr.font = Typography.body(12)
            addr.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel

            let dec0 = (pool["decimals0"] as? Int)
                ?? (pool["decimals0"] as? NSNumber)?.intValue ?? 18
            let dec1 = (pool["decimals1"] as? Int)
                ?? (pool["decimals1"] as? NSNumber)?.intValue ?? 18
            let reserves = UILabel()
            reserves.text = L.lang("pool-reserves", fallback: "Reserves") + ": "
                + CoinUtils.formatUnits(pool["reserve0"] as? String, decimals: dec0)
                + " / "
                + CoinUtils.formatUnits(pool["reserve1"] as? String, decimals: dec1)
            reserves.font = Typography.body(13)
            reserves.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel

            row.addArrangedSubview(pair)
            row.addArrangedSubview(addr)
            row.addArrangedSubview(reserves)
            row.addArrangedSubview(DexScreenChrome.makeDivider())
            poolsStack.addArrangedSubview(row)
        }
    }

    @objc private func startCreate() {
        let L = Localization.shared
        if tokenAPicker.tokenValue().caseInsensitiveCompare(tokenBPicker.tokenValue())
            == .orderedSame {
            DexScreenChrome.presentError(from: self, message: L.err(
                "identicalTokens", fallback: "Token A and Token B must differ."))
            return
        }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.resolveMeta(self.tokenAPicker)
                try await self.resolveMeta(self.tokenBPicker)
                try await self.checkPairThenCreate()
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

    private func checkPairThenCreate() async throws {
        var payload = DexPayloads.base()
        payload["tokenAValue"] = tokenAPicker.tokenValue()
        payload["tokenBValue"] = tokenBPicker.tokenValue()
        let json = try await JsBridge.shared.dexCallAsync(
            method: "liquidityGetPairInfo", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        if (data["exists"] as? Bool) == true {
            await MainActor.run {
                self.failFlow(Localization.shared.lang("pair-exists",
                    fallback: "A pool already exists for this pair."))
            }
            return
        }
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
        try await submitCreate(priv: priv, pub: pub)
    }

    private func submitCreate(priv: Data, pub: Data) async throws {
        await MainActor.run {
            self.setStatus(Localization.shared.getSubmittingTransactionByLangValues())
        }
        var keyed = DexPayloads.withKeys(privKey: priv, pubKey: pub)
        keyed.payload["tokenAValue"] = tokenAPicker.tokenValue()
        keyed.payload["tokenBValue"] = tokenBPicker.tokenValue()
        keyed.payload["gasLimit"] = 3_000_000
        let json = try await JsBridge.shared.dexCallAsync(
            method: "poolsSubmitCreatePair", payload: keyed.payload,
            privKey: keyed.privKey, pubKey: keyed.pubKey)
        let data = try DexBridgeResult.unwrapData(json)
        let txHash = (data["txHash"] as? String) ?? ""
        await MainActor.run {
            self.setBusy(false)
            self.clearStatus()
            let L = Localization.shared
            let dlg = MessageInformationDialogViewController(
                title: L.lang("create-pair", fallback: "Create Pair"),
                message: L.lang("transaction-submitted",
                    fallback: "Transaction submitted.") + "\n\n" + txHash)
            dlg.onClose = { [weak self] in self?.loadPools() }
            self.present(dlg, animated: true)
        }
    }

    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        createButton.isEnabled = !busy
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
}
