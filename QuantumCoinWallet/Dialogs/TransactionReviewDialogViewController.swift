// TransactionReviewDialogViewController.swift
// Read-only review of a pending Send transaction. Presented after
// the user taps Send and the destination address has passed
// `JsBridge.isValidAddressAsync`, BEFORE the unlock-password dialog,
// so the user can sanity-check the From / To / amount / network
// pairing before committing to a strongbox decrypt.
// Layout:
// "Please review your transaction request to be sent:"
// What is being sent?
// <native asset name OR token symbol + contract>
// From Address:
// <wallet 0x... mono, mixed-case checksum, 2 lines, truncating-middle>
// To Address:
// <typed 0x... mono, mixed-case checksum, 2 lines, truncating-middle>
// Send quantity:
// <decimal>
// Network:
// <name in green> (chain <chainId>)
// Type I agree to confirm:
// <text field>
// [ Cancel ] [ OK ]
// Design notes:
// The dialog is the user's last user-comprehensible chance to
// abort a transaction before scrypt unlocks the strongbox and a key
// binds the signature. The hardening that survives in this build:
// * Mixed-case checksum capitalization for both the From
// and To addresses so a single-character typo in either
// changes many letter cases - a strong visual cue. The
// values are computed outside the dialog and passed in
// already-checksummed.
// * Network name + chain-id label so the user can see
// exactly which chain they are signing for. The chain-id
// is the same value pin in the
// NetworkSnapshot and re-assert at submit time, so the
// value displayed here is the value that will actually be
// encoded into the EIP-155 signature.
// * The "I agree" gate: `OK` is only honoured when the
// trimmed lowercase contents of the text field equal the
// localized "I agree" literal (with English fallback per
// ). Otherwise the dialog presents an
// orange-icon `MessageInformationDialogViewController.error`
// warning and stays on screen so the user can either type
// correctly or press Cancel.
// What this dialog deliberately does NOT do:
// The earlier iteration of this dialog asked
// `bridge.estimateFee` for a fee quote, displayed it alongside
// the gas limit, and gated `OK` behind either a successful
// estimate or an explicit "continue without estimate"
// secondary confirmation. That feature was removed: the
// wallet uses a static gas limit (21000 native, 90000 token)
// forwarded directly to the signing call, and the actual fee
// is set by the network at submission time. Trying to estimate
// the fee in offline / RPC-degraded scenarios produced a
// user-blocking "estimate unavailable" branch that did not
// exist in the historical port-from-Android UX. The signing
// path is unchanged - the gas limit constants live in
// `SendViewController.swift` and are still pinned.

import UIKit

public final class TransactionReviewDialogViewController: ModalDialogViewController {

    public var onConfirm: (() -> Void)?
    public var onCancel: (() -> Void)?

    private let assetText: String
    /// Dedicated contract-address row payload. `nil` for
    /// native sends so the dialog suppresses the row entirely.
    /// Held alongside `assetText` (which now carries ONLY the
    /// symbol/name pair) so the user has a clearly-labelled
    /// "Contract address:" row to compare against the
    /// vendor-published address - rather than re-reading a hex
    /// blob appended at the bottom of the asset value field
    /// where it could be mistaken for a continuation of the
    /// token name.
    private let assetContract: String?
    private let fromAddress: String
    private let toAddress: String
    private let amountText: String
    private let networkName: String
    private let chainId: Int

    private let agreeField = UITextField()
    private let cancelButton = GrayPillButton(type: .system)
    private let okButton = GreenPillButton(type: .system)

    public init(asset: String,
        assetContract: String? = nil,
        fromAddress: String,
        toAddress: String,
        amount: String,
        networkName: String,
        chainId: Int) {
        self.assetText = asset
        self.assetContract = assetContract
        self.fromAddress = fromAddress
        self.toAddress = toAddress
        self.amountText = amount
        self.networkName = networkName
        self.chainId = chainId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let L = Localization.shared

        let prompt = makeBody(L.getReviewTransactionPromptByLangValues())
        prompt.font = Typography.boldTitle(15)

        let assetSection = makeSection(
            header: L.getWhatIsBeingSentByLangValues(),
            value: assetText,
            mono: false)
        // Dedicated contract row: rendered ONLY when the
        // user is sending a token (native sends carry `nil` here).
        // Mono-spaced + char-wrapping so the full 64+2 hex is
        // visible without truncation, the same chrome the
        // From/To address rows use. The label is distinct from
        // the asset symbol/name row above so the user can do a
        // bytewise compare against the vendor-published address.
        let contractSection: UIStackView? = {
            guard let contract = assetContract, !contract.isEmpty else {
                return nil
            }
            return makeSection(
                header: L.getContractAddressByLangValues(),
                value: contract,
                mono: true)
        }()
        let fromSection = makeSection(
            header: L.getFromAddressByLangValues() + ":",
            value: fromAddress,
            mono: true)
        let toSection = makeSection(
            header: L.getToAddressByLangValues() + ":",
            value: toAddress,
            mono: true)
        let amountSection = makeSection(
            header: L.getSendQuantityByLangValues() + ":",
            value: amountText,
            mono: false)
        // Chain-id is concatenated to the human-readable network
        // name so a user with two networks that happen to share a
        // display name (or a typo'd custom network) sees the
        // chain-id their transaction will be bound to. The
        // chain-id is the same value pin in the
        // NetworkSnapshot and re-assert at submit time; the value
        // displayed here is therefore the value that will actually
        // be encoded into the EIP-155 signature.
        let networkValue = networkName.isEmpty
        ? "(\(L.getChainIdSuffixByLangValues()) \(chainId))"
        : "\(networkName) (\(L.getChainIdSuffixByLangValues()) \(chainId))"
        let networkSection = makeSection(
            header: L.getNetworkByLangValues() + ":",
            value: networkValue,
            mono: false,
            valueColor: .systemGreen)

        // Agreement row. The header is an attributed string with the
        // literal "I agree" rendered in blue so the user can clearly
        // see the exact text they need to type into the field.
        let agreeHeader = UILabel()
        agreeHeader.numberOfLines = 0
        agreeHeader.attributedText = makeAgreementAttributed(
            prefix: L.getTypeIAgreeToConfirmPrefixByLangValues(),
            literal: L.getIAgreeLiteralByLangValues(),
            suffix: L.getTypeIAgreeToConfirmSuffixByLangValues())

        agreeField.borderStyle = .roundedRect
        agreeField.placeholder = L.getIAgreeLiteralByLangValues()
        agreeField.autocapitalizationType = .none
        agreeField.autocorrectionType = .no
        agreeField.font = Typography.body(15)
        agreeField.translatesAutoresizingMaskIntoConstraints = false
        agreeField.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let agreeStack = UIStackView(arrangedSubviews: [agreeHeader, agreeField])
        agreeStack.axis = .vertical
        agreeStack.spacing = 6
        agreeStack.alignment = .fill

        // Buttons: same Cancel + OK pill row pattern as ConfirmDialog
        // (paired-pill variant) so the visual rhythm matches every
        // other commit-style dialog in the app.
        cancelButton.setTitle(L.getCancelByLangValues(), for: .normal)
        okButton.setTitle(L.getOkByLangValues(), for: .normal)
        cancelButton.addTarget(self, action: #selector(tapCancel), for: .touchUpInside)
        okButton.addTarget(self, action: #selector(tapOk), for: .touchUpInside)
        cancelButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        okButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        okButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        let leadingSpacer = UIView()
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leadingSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttonRow = UIStackView(arrangedSubviews: [leadingSpacer, cancelButton, okButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .center
        buttonRow.distribution = .fill

        // Insert the contract row immediately after the
        // asset row so the user reads symbol/name first, then the
        // exact contract bytes, and only then moves on to the
        // From/To/amount rows. Sections nil-coalesce to an empty
        // hidden view so the layout stays stable for native sends.
        var sections: [UIView] = [prompt, assetSection]
        if let contractSection = contractSection {
            sections.append(contractSection)
        }
        sections.append(contentsOf: [fromSection,
            toSection, amountSection, networkSection,
            agreeStack, buttonRow])
        let stack = UIStackView(arrangedSubviews: sections)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Wrap the section stack in an inner `UIScrollView` so the
        // dialog body can scroll independently of the card. The
        // base `ModalDialogViewController` caps `card.bottomAnchor`
        // to `view.keyboardLayoutGuide.topAnchor - 12`, which means
        // on tall confirmations (asset / contract / from / to /
        // amount / network / "I agree" / Cancel + OK) the card
        // height is bounded by the available space above the
        // keyboard. The cap below + the inner scroll let the user
        // reach `agreeField` and the OK button on iPhone SE /
        // iPhone 13 mini even with the on-screen keyboard docked.
        let bodyScroll = UIScrollView()
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.alwaysBounceVertical = true
        bodyScroll.keyboardDismissMode = .interactive
        card.addSubview(bodyScroll)
        bodyScroll.addSubview(stack)
        // Cap the card height so it never exceeds the safe-area
        // height; combined with the inherited centerY pull-up and
        // keyboard-cap from `ModalDialogViewController`, the card
        // now stays inside the safe area on every device while the
        // inner scroll handles overflow.
        let cardHeightCap = card.heightAnchor.constraint(
            lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor,
            constant: -32)
        cardHeightCap.priority = .required

        // Make the scroll view (and therefore the card) grow to
        // fit the stack's intrinsic height when there is room. A
        // `UIScrollView`'s `contentLayoutGuide` does NOT drive the
        // scroll view's own height, so without this pair the card
        // would collapse to whatever ambient height autolayout
        // can find (which here is zero, producing a thin white
        // stripe). The `.defaultHigh` priority lets the required
        // `cardHeightCap` win on small screens, at which point the
        // bodyScroll becomes shorter than the stack and the inner
        // scroll engages.
        let bodyScrollFitsContent = bodyScroll.heightAnchor.constraint(
            equalTo: bodyScroll.contentLayoutGuide.heightAnchor)
        bodyScrollFitsContent.priority = .defaultHigh

        NSLayoutConstraint.activate([
                bodyScroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
                bodyScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
                bodyScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
                bodyScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
                bodyScrollFitsContent,

                stack.topAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.topAnchor),
                stack.bottomAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: bodyScroll.contentLayoutGuide.trailingAnchor),
                stack.widthAnchor.constraint(equalTo: bodyScroll.frameLayoutGuide.widthAnchor),

                card.widthAnchor.constraint(equalToConstant: 340),
                cardHeightCap
            ])

        view.installPressFeedbackRecursive()
    }

    /// Drop the keyboard caret into the agreement field as soon as
    /// the dialog finishes presenting. Doing this in `viewDidAppear`
    /// (rather than `viewDidLoad`) lets the keyboard animate in
    /// alongside the dialog instead of fighting the present
    /// transition.
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        agreeField.becomeFirstResponder()
    }

    // MARK: - Section helpers

    private func makeBody(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = Typography.body(14)
        l.numberOfLines = 0
        l.textColor = UIColor(named: "colorCommon6") ?? .label
        return l
    }

    private func makeSection(header: String,
        value: String,
        mono: Bool,
        valueColor: UIColor? = nil) -> UIStackView {
        let h = UILabel()
        h.text = header
        h.font = Typography.boldTitle(13)
        h.textColor = UIColor(named: "colorCommon6") ?? .label
        h.numberOfLines = 1

        let v = UILabel()
        v.text = value
        v.font = mono
        ? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        : Typography.body(14)
// mono branch renders the destination address in
        // a transaction-review confirmation dialog. Previously this
        // was capped at `numberOfLines = 2` with `.byTruncatingMiddle`,
        // so at large Dynamic Type sizes (Accessibility XXL) and on
        // 4-inch devices the address would render with the middle
        // 12-16 characters replaced by `…`. The user could not
        // verify the bytes they were signing for - which directly
        // defeats the purpose of the confirmation dialog. Setting
        // `numberOfLines = 0` lets the address grow as tall as
        // needed; `byCharWrapping` keeps the wrap clean (otherwise
        // `byWordWrapping` would never break a 64-hex-char string
        // and would clip horizontally instead). Non-mono branch
        // (header / counterparty name etc.) is unchanged. Tradeoff:
        // the dialog is slightly taller at large text sizes, which
        // is an acceptable cost for full address visibility.
        v.numberOfLines = 0
        v.lineBreakMode = mono ? .byCharWrapping : .byWordWrapping
        v.textColor = valueColor ?? (UIColor(named: "colorCommon6") ?? .label)

        let stack = UIStackView(arrangedSubviews: [h, v])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        return stack
    }

    /// "Type [I agree] to confirm:" with the literal in iOS-system blue
    /// so the user has a visual anchor for the exact phrase the field
    /// expects.
    private func makeAgreementAttributed(prefix: String,
        literal: String,
        suffix: String) -> NSAttributedString {
        let baseFont = Typography.boldTitle(13)
        let baseColor = UIColor(named: "colorCommon6") ?? .label
        let result = NSMutableAttributedString(
            string: prefix,
            attributes: [.font: baseFont, .foregroundColor: baseColor])
        result.append(NSAttributedString(
                string: literal,
                attributes: [.font: baseFont,
                    .foregroundColor: UIColor.systemBlue]))
        result.append(NSAttributedString(
                string: suffix,
                attributes: [.font: baseFont, .foregroundColor: baseColor]))
        return result
    }

    // MARK: - Actions

    @objc private func tapCancel() {
        dismiss(animated: true) { [onCancel] in onCancel?() }
    }

    // Hard-coded English fallback for the "I agree"
    // literal. The dialog's whole security guarantee is that the user
    // physically types this exact phrase before a transaction is
    // signed; if the localized literal is empty (missing translation
    // key, malformed strings file, mis-merged localization branch),
    // the equality test `typed == expected` collapses to `"" == ""`
    // and the gate fails OPEN - the user submits a transaction without
    // typing anything at all.
    // The fix has two parts:
    // 1. If the localized expected literal trims to empty, substitute
    // this English constant. The user then sees the gate behave
    // correctly even on a broken translation, at the cost of one
    // English phrase appearing in a non-English UI - a strictly
    // better failure mode than silent bypass.
    // 2. Reject empty user input independently. With (1) in place a
    // non-empty expected literal already makes empty input fail
    // the equality test, but checking the input length explicitly
    // makes the gate's intent obvious to future reviewers and
    // defends against a hypothetical future regression where
    // `lowercased`/`trimmingCharacters` semantics change.
    // Tradeoff: the user briefly sees an English phrase in a localized
    // UI when the strings file is broken. This was deliberately chosen
    // over a "show a confirmation that's silently empty" mode because
    // for a wallet that signs high-value transactions the only safe
    // failure mode for a confirmation gate is "ask harder", never
    // "ask less".
    private static let iAgreeLiteralFallback = "i agree"

    @objc private func tapOk() {
        let typed = (agreeField.text ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        let localized = Localization.shared
        .getIAgreeLiteralByLangValues()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        let expected = localized.isEmpty
        ? Self.iAgreeLiteralFallback
        : localized
        guard !typed.isEmpty, typed == expected else {
            presentMustAgreeError()
            return
        }
        dismiss(animated: true) { [onConfirm] in onConfirm?() }
    }

    private func presentMustAgreeError() {
        let L = Localization.shared
        let dlg = MessageInformationDialogViewController.error(
            title: L.getErrorTitleByLangValues(),
            message: L.getMustAgreeToSubmitByLangValues())
        present(dlg, animated: true)
    }
}
