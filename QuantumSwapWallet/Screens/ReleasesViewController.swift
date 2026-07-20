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
    private let statusLabel = UILabel()
    private let addButton = GreenPillButton(type: .system)

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "colorBackground") ?? .systemBackground
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

        addButton.setTitle(L.lang("add-release", fallback: "Add Release"), for: .normal)
        addButton.addTarget(self, action: #selector(startAdd), for: .touchUpInside)

        statusLabel.font = Typography.body(13)
        statusLabel.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        let form = UIStackView(arrangedSubviews: [
            addTitle, nameField, wqField, factoryField, routerField, addButton, statusLabel
        ])
        form.axis = .vertical
        form.spacing = 10

        let content = UIStackView(arrangedSubviews: [
            backBar, title, DexScreenChrome.makeDivider(), listStack, form
        ])
        content.axis = .vertical
        content.spacing = 12
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

        renderList()
        view.installPressFeedbackRecursive()
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

            let detail = UILabel()
            detail.text = "WQ \(DexBridgeResult.shortAddr(release.wq))\n"
                + "Factory \(DexBridgeResult.shortAddr(release.factory))\n"
                + "Router \(DexBridgeResult.shortAddr(release.router))"
            detail.font = Typography.body(11)
            detail.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel
            detail.numberOfLines = 0

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
        let release = ReleaseStore.Release(name: name, wq: wq, factory: factory,
            router: router, builtin: false)
        DexUnlockPrompt.show(from: self) { [weak self] password in
            guard let self else { return }
            do {
                try ReleaseStore.persistAddRelease(release, password: password)
                self.nameField.text = ""
                self.wqField.text = ""
                self.factoryField.text = ""
                self.routerField.text = ""
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
