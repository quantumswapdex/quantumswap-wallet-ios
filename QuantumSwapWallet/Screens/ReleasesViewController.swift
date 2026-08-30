// ReleasesViewController.swift
// Settings → Releases: builtin Beta2 + custom releases. Port of
// Android `ReleasesFragment.java`.

import UIKit

public final class ReleasesViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    private let listStack = UIStackView()
    private let nameField = DexScreenChrome.makeField(
        placeholder: "", keyboard: .default)
    private let wqField = DexScreenChrome.makeField(
        placeholder: "", keyboard: .asciiCapable)
    private let factoryField = DexScreenChrome.makeField(
        placeholder: "", keyboard: .asciiCapable)
    private let routerField = DexScreenChrome.makeField(
        placeholder: "", keyboard: .asciiCapable)
    // Web app add-release form: the two Swap Read API fields are optional
    // and prefilled with the public defaults; clearing one switches the
    // API off for that release (RPC only).
    private let apiUrlField = DexScreenChrome.makeField(
        placeholder: "", keyboard: .URL)
    private let dexIdField = DexScreenChrome.makeField(
        placeholder: "", keyboard: .asciiCapable)
    private let apiStatusLabel = UILabel()
    private let statusLabel = UILabel()
    private let addButton = GreenPillButton(type: .system)

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
        title.text = L.lang("releases", fallback: "Releases")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        listStack.axis = .vertical
        listStack.spacing = 4

        let addTitle = UILabel()
        addTitle.text = L.lang("add-release", fallback: "Add Release")
        addTitle.font = Typography.boldTitle(16)
        addTitle.textColor = UIColor(named: "colorCommon6") ?? .label

        nameField.placeholder = L.lang("release-name", fallback: "Release Name")
        wqField.placeholder = L.lang("release-wq", fallback: "WQ")
        factoryField.placeholder = L.lang("release-factory", fallback: "Factory")
        routerField.placeholder = L.lang("release-router", fallback: "Router")
        apiUrlField.placeholder = L.lang("release-api-url", fallback: "Swap Read API URL")
        dexIdField.placeholder = L.lang("release-dex-id", fallback: "Swap Read API dexId")
        apiUrlField.text = SwapApiConfig.defaultApiUrl
        dexIdField.text = SwapApiConfig.defaultDexId
        apiStatusLabel.font = Typography.body(12)
        apiStatusLabel.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel
        apiStatusLabel.numberOfLines = 0
        apiStatusLabel.isHidden = true

        addButton.setTitle(L.lang("add-release", fallback: "Add Release"), for: .normal)
        addButton.addTarget(self, action: #selector(startAdd), for: .touchUpInside)
        // Same footprint as the Send screen's primary button.
        addButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        addButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        statusLabel.font = Typography.body(13)
        statusLabel.textColor = UIColor(rgbHex: 0xFBBF24) // Android quantumAmber
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        let form = UIStackView(arrangedSubviews: [
            addTitle, nameField, wqField, factoryField, routerField, apiUrlField, dexIdField,
            addButton, statusLabel
        ])
        form.axis = .vertical
        form.spacing = 10

        let content = UIStackView(arrangedSubviews: [
            title, DexScreenChrome.makeDivider(), listStack, apiStatusLabel, form
        ])
        content.axis = .vertical
        content.spacing = 12

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

        renderList()
        loadApiStatus()
        view.installPressFeedbackRecursive()
    }

    /// Web app releases.ts status line: what the Swap Read API serves for
    /// the active release, or why the screens are on RPC.
    private func loadApiStatus() {
        Task { [weak self] in
            guard let self else { return }
            var data: [String: Any]? = nil
            if let json = try? await JsBridge.shared.dexCallAsync(method: "swapApiStatus", payload: DexPayloads.base()) {
                data = try? DexBridgeResult.unwrapData(json)
            }
            await MainActor.run { self.showApiStatus(data) }
        }
    }

    private func showApiStatus(_ data: [String: Any]?) {
        let L = Localization.shared
        let status = (data?["status"] as? String) ?? "unavailable"
        func num(_ key: String) -> Int64 {
            if let n = data?[key] as? NSNumber { return n.int64Value }
            return 0
        }
        var text: String
        switch status {
        case "ok":
            text = L.lang("swap-api-status-indexed",
                fallback: "Swap Read API: indexed [PAIRS] pools · [TOKENS] tokens · block [BLOCK]")
                .replacingOccurrences(of: "[PAIRS]", with: String(num("pairs")))
                .replacingOccurrences(of: "[TOKENS]", with: String(num("tokens")))
                .replacingOccurrences(of: "[BLOCK]", with: String(num("indexedBlock")))
            let lag = num("lagBlocks")
            if lag > 0 {
                text += " " + L.lang("swap-api-status-behind", fallback: "([LAG] behind)")
                    .replacingOccurrences(of: "[LAG]", with: String(lag))
            }
        case "disabled":
            text = L.lang("swap-api-status-off", fallback: "Swap Read API: off for this release (using RPC).")
        case "no-dex":
            text = L.lang("swap-api-status-not-served",
                fallback: "Swap Read API: this dexId is not served for this factory (using RPC).")
        default:
            text = L.lang("swap-api-status-unavailable", fallback: "Swap Read API unavailable (using RPC).")
        }
        apiStatusLabel.text = text
        apiStatusLabel.isHidden = false
    }

    @objc private func tapBack() {
        (parent as? HomeViewController)?.beginTransactionNow(SettingsViewController())
    }

    private func renderList() {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let L = Localization.shared
        let releases = ReleaseStore.readAll()
        let active = ReleaseStore.readActive()
        for release in releases {
            let row = UIControl()
            row.translatesAutoresizingMaskIntoConstraints = false
            let isActive = release.name == active.name

            let radio = UIImageView(image: UIImage(systemName:
                isActive ? "largecircle.fill.circle" : "circle"))
            radio.tintColor = UIColor(named: "colorAccent") ?? .systemPurple
            radio.translatesAutoresizingMaskIntoConstraints = false

            let name = UILabel()
            var label = release.name
            if release.builtin {
                label += " (" + L.lang("builtin", fallback: "built-in") + ")"
            }
            name.text = label
            name.font = Typography.body(15)
            name.textColor = UIColor(named: "colorCommon6") ?? .label

            // Full addresses, monospace, selectable (Android safeAddr()).
            let detail = UITextView()
            let off = L.lang("release-api-off", fallback: "Off (using RPC)")
            detail.text = "WQ \(release.wq)\n"
                + "Factory \(release.factory)\n"
                + "Router \(release.router)\n"
                + L.lang("release-api-url", fallback: "Swap Read API URL") + " "
                + (release.apiUrl.isEmpty ? off : release.apiUrl) + "\n"
                + L.lang("release-dex-id", fallback: "Swap Read API dexId") + " "
                + (release.dexId.isEmpty ? off : release.dexId)
            detail.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            detail.textColor = UIColor(named: "colorCommon3") ?? .secondaryLabel
            detail.isEditable = false
            detail.isScrollEnabled = false
            detail.backgroundColor = .clear
            detail.textContainerInset = .zero
            detail.textContainer.lineFragmentPadding = 0
            detail.textContainer.lineBreakMode = .byCharWrapping

            let textStack = UIStackView(arrangedSubviews: [name, detail])
            textStack.axis = .vertical
            textStack.spacing = 2
            textStack.translatesAutoresizingMaskIntoConstraints = false

            [radio, textStack].forEach { row.addSubview($0) }
            NSLayoutConstraint.activate([
                radio.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                radio.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
                radio.widthAnchor.constraint(equalToConstant: 22),
                radio.heightAnchor.constraint(equalToConstant: 22),
                textStack.leadingAnchor.constraint(equalTo: radio.trailingAnchor, constant: 10),
                textStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                textStack.topAnchor.constraint(equalTo: row.topAnchor),
                textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10)
            ])
            row.accessibilityIdentifier = release.name
            row.addAction(UIAction { [weak self] _ in
                self?.selectRelease(release)
            }, for: .touchUpInside)
            listStack.addArrangedSubview(row)
        }
    }

    private func selectRelease(_ release: ReleaseStore.Release) {
        let active = ReleaseStore.readActive()
        if release.name == active.name { return }
        let L = Localization.shared
        DexUnlockPrompt.show(from: self) { [weak self] password in
            guard let self else { return }
            do {
                try ReleaseStore.persistActiveRelease(name: release.name, password: password)
                self.statusLabel.text = L.lang("release-active",
                    fallback: "Active release updated.") + " " + release.name
                self.statusLabel.isHidden = false
                self.renderList()
                self.loadApiStatus()
            } catch {
                DexScreenChrome.presentError(from: self, message: "\(error)")
                self.renderList()
            }
        }
    }

    @objc private func startAdd() {
        let L = Localization.shared
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wq = wqField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let factory = factoryField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let router = routerField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ReleaseStore.isValidName(name)
            || !ReleaseStore.isValidAddress(wq)
            || !ReleaseStore.isValidAddress(factory)
            || !ReleaseStore.isValidAddress(router) {
            DexScreenChrome.presentError(from: self, message: L.lang(
                "invalid-release",
                fallback: "Enter a valid name and three 0x… 64-hex addresses."))
            return
        }
        let apiUrlRaw = apiUrlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dexIdRaw = dexIdField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Optional API fields: "" switches the API off; anything else must
        // sanitise cleanly.
        let apiUrl = apiUrlRaw.isEmpty ? "" : SwapApiConfig.sanitizeUrl(apiUrlRaw)
        if !apiUrlRaw.isEmpty, apiUrl.isEmpty {
            DexScreenChrome.presentError(from: self, message: L.lang("release-invalid-api-url",
                fallback: "Enter a valid http(s) URL for the Swap Read API (no credentials, query or fragment; max 200 characters)."))
            return
        }
        if !dexIdRaw.isEmpty, !SwapApiConfig.isValidDexId(dexIdRaw) {
            DexScreenChrome.presentError(from: self, message: L.lang("release-invalid-dex-id",
                fallback: "Swap Read API dexId may only contain letters, digits, - and _ (max 64)."))
            return
        }
        let release = ReleaseStore.Release(name: name, wq: wq, factory: factory,
            router: router, builtin: false, apiUrl: apiUrl, dexId: dexIdRaw)
        DexUnlockPrompt.show(from: self) { [weak self] password in
            guard let self else { return }
            do {
                try ReleaseStore.persistAddRelease(release, password: password)
                self.nameField.text = ""
                self.wqField.text = ""
                self.factoryField.text = ""
                self.routerField.text = ""
                self.apiUrlField.text = SwapApiConfig.defaultApiUrl
                self.dexIdField.text = SwapApiConfig.defaultDexId
                self.statusLabel.text = L.lang("release-added",
                    fallback: "Release added.") + " " + name
                self.statusLabel.isHidden = false
                self.renderList()
            } catch {
                DexScreenChrome.presentError(from: self, message: "\(error)")
                self.renderList()
            }
        }
    }
}
