// ModalDialogViewController.swift
// Base class for every rounded-card modal dialog. Android uses
// `DialogFragment` + `custom_alert_dialog.xml`-style; on iOS we compose
// this as a `UIViewController` presented with
// `.overFullScreen + .crossDissolve`.

import UIKit

open class ModalDialogViewController: UIViewController {

    public let card: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(named: "colorBackgroundCard") ?? .systemBackground
        v.layer.cornerRadius = 14
        // Keep the layer un-masked so primary / secondary `PillButton`
        // drop shadows (and any other elevated content) can bleed past
        // the rounded card edge instead of being chopped flat. The
        // card's contents are inset with constraints so nothing visually
        // overlaps the rounded corners; only shadows extend past the
        // bounds.
        v.layer.masksToBounds = false
        return v
    }()

    private let dim: UIView = {
        let v = UIView()
        // Soft 30% black so the underlying screen (e.g. the quiz card)
        // remains readable behind the dialog. Android dialogs use a
        // similarly light scrim by default.
        v.backgroundColor = UIColor.black.withAlphaComponent(0.30)
        return v
    }()

    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        // CRITICAL: UIKit reads `modalPresentationStyle` at `present(_:)`
        // time, which fires BEFORE `viewDidLoad`. Setting these here
        // (the designated initializer) guarantees `.overFullScreen` is
        // honored - otherwise UIKit treats the dialog as `.automatic`
        // (full-screen on iPhone) and detaches the presenter from the
        // window, "hiding" the screen behind the dialog.
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        dim.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dim)
        view.addSubview(card)

        // Keyboard-aware vertical placement:
        //   - `centerY` keeps the card vertically centered when no
        //     keyboard is on screen (the legacy behavior every
        //     ConfirmDialog / MessageInformationDialog caller still
        //     expects). Lowered to `.defaultHigh - 1` so autolayout
        //     can break it in favor of `kbCap` once the keyboard
        //     docks.
        //   - `kbCap` (required) pulls the card up so its bottom
        //     edge stays at least 12pt above the on-screen keyboard
        //     top via `view.keyboardLayoutGuide.topAnchor`. When
        //     the keyboard is offscreen the guide anchors to the
        //     bottom of the view, so the cap is trivially satisfied
        //     and `centerY` wins. When a child dialog auto-focuses
        //     a text field on present (`UnlockDialogViewController`
        //     and `BackupPasswordDialog` both do so via
        //     `focusAndShowKeyboard`), the cap binds and the card
        //     slides up to keep the password field + primary action
        //     button visible.
        let centerY = card.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        centerY.priority = .defaultHigh - 1
        let kbCap = card.bottomAnchor.constraint(
            lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor,
            constant: -12)
        kbCap.priority = .required
        NSLayoutConstraint.activate([
                dim.topAnchor.constraint(equalTo: view.topAnchor),
                dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),

                card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                centerY,
                kbCap,
                card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
                card.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
            ])
    }

    /// Android `GlobalMethods.focusAndShowKeyboard` equivalent.
    /// Call on the password / input field to auto-focus on present.
    public static func focusAndShowKeyboard(_ textField: UITextField) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            textField.becomeFirstResponder()
        }
    }
}
