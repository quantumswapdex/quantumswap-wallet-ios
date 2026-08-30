//
//  FirstTimeRestoreUnlockGateTests.swift
//
//  First-time restores must end at the unlock screen, and the two
//  already-fixed password-substitution hazards must never return.
//
//  Background. The create and restore-from-seed onboarding paths end at
//  `tapBackupDone`, which forces the user to retype the app password
//  before routing home (the iOS mirror of Android's
//  `requirePasswordReentryThenNavigate`). The restore-from-file and
//  restore-from-folder paths historically skipped that gate: their
//  `RestoreFlow.shared.onComplete` closures called `finishAndRouteHome()`
//  directly, so a user who mistyped or misremembered the password chosen
//  on the Set-Password screen only discovered it on the next cold launch,
//  when the wallet would no longer open.
//
//  This suite is a grep-style source lint (same shape as
//  `StrongboxLayerTests.testNoV1KeyStoreReferencesRemain`): it walks the
//  production sources via the `#filePath` seam and pins:
//
//   1. Both restore completions route through the post-restore unlock
//      gate helper instead of calling `finishAndRouteHome()` directly.
//   2. The gate helper validates with the verify-only path
//      (`verifyOnlyIfPresent`) and NEVER the create-capable
//      `bootstrapOrUnlock` -- the strongbox definitively exists after a
//      restore, and a gate backed by a create-capable call would let a
//      typo silently define a new password on any state regression.
//   3. (Regression pin) `RestoreFlow` keeps preferring the onboarding
//      `strongboxPassword` over the per-file backup password when
//      creating the strongbox. Falling back to the backup password
//      would silently swap the unlock password -- the exact bug the
//      Android `FirstTimeRestorePasswordTest` closes on that platform.
//   4. (Regression pin) `tapBackupDone` keeps its re-entry prompt, so
//      the create / restore-from-seed gate cannot be silently removed.
//

import XCTest
@testable import QuantumSwapWallet

final class FirstTimeRestoreUnlockGateTests: XCTestCase {

    // MARK: - 1. Restore completions route through the unlock gate

    func testRestoreCompletionsRouteThroughUnlockGate() throws {
        let src = try strippedSource(of: "Screens/HomeWalletViewController.swift")
        let anchors = ranges(of: "RestoreFlow.shared.onComplete", in: src)
        XCTAssertGreaterThanOrEqual(anchors.count, 2,
            "Expected the file-restore and folder-restore paths to each install "
            + "a RestoreFlow.shared.onComplete closure; found \(anchors.count). "
            + "The restore wiring changed shape and this test needs updating "
            + "alongside it.")
        for (i, r) in anchors.enumerated() {
            let window = windowAfter(r, in: src, length: 400)
            XCTAssertTrue(
                window.contains("presentPostRestoreUnlockGateThenRouteHome"),
                "onComplete closure #\(i + 1) must route through "
                + "presentPostRestoreUnlockGateThenRouteHome so a FIRST-TIME "
                + "restore ends at the unlock screen (mirroring tapBackupDone "
                + "on the create/seed paths) before the main wallet screen. "
                + "Window: \(window.prefix(220))")
            XCTAssertFalse(
                window.contains("self.finishAndRouteHome()"),
                "onComplete closure #\(i + 1) must not call finishAndRouteHome() "
                + "directly -- direct routing bypasses the first-time unlock "
                + "gate. Window: \(window.prefix(220))")
        }
    }

    // MARK: - 2. The gate validates, it never creates

    func testUnlockGateVerifiesAndNeverCreates() throws {
        let src = try strippedSource(of: "Screens/HomeWalletViewController.swift")
        guard let body = functionBody(
                named: "presentPostRestoreUnlockGateThenRouteHome", in: src) else {
            XCTFail("presentPostRestoreUnlockGateThenRouteHome not found in "
                + "HomeWalletViewController.swift. The post-restore unlock gate "
                + "helper is missing, so restore-from-file/folder can route to "
                + "the main wallet screen without the user ever re-entering the "
                + "app password they chose during onboarding.")
            return
        }
        XCTAssertTrue(body.contains("verifyOnlyIfPresent"),
            "The post-restore unlock gate must validate via verifyOnlyIfPresent: "
            + "the strongbox definitively exists after a restore, so the gate "
            + "is a pure password check.")
        XCTAssertFalse(body.contains("bootstrapOrUnlock"),
            "The post-restore unlock gate must NEVER use the create-capable "
            + "bootstrapOrUnlock: on any state regression where the strongbox "
            + "is missing, a typo typed into the gate would silently become "
            + "the app unlock password.")
    }

    // MARK: - 3. Regression pin: RestoreFlow password preference

    func testRestoreFlowPrefersOnboardingPasswordForStrongboxCreate() throws {
        let src = try strippedSource(of: "Backup/RestoreFlow.swift")
        XCTAssertTrue(src.contains("strongboxWritePw = chosen"),
            "RestoreFlow must keep preferring the onboarding strongboxPassword "
            + "over the per-file backup password when deciding the strongbox "
            + "write password. Falling back to the backup password on "
            + "first-time restore silently swaps the app unlock password.")
        XCTAssertTrue(src.contains("password: strongboxWritePw"),
            "RestoreFlow's strongbox create/write calls must consume "
            + "strongboxWritePw, not the raw backup password.")
    }

    // MARK: - 4. Regression pin: the create/seed gate stays

    func testBackupDoneKeepsPasswordReentryGate() throws {
        let src = try strippedSource(of: "Screens/HomeWalletViewController.swift")
        guard let body = functionBody(named: "tapBackupDone", in: src) else {
            XCTFail("tapBackupDone not found in HomeWalletViewController.swift.")
            return
        }
        XCTAssertTrue(body.contains("UnlockDialogViewController"),
            "tapBackupDone must keep presenting the unlock dialog: it is the "
            + "password re-entry gate for the create and restore-from-seed "
            + "paths (mirror of Android requirePasswordReentryThenNavigate).")
        XCTAssertTrue(body.contains("bootstrapOrUnlock"),
            "tapBackupDone must keep validating the retyped password through "
            + "bootstrapOrUnlock before routing home.")
    }

    // MARK: - Helpers

    /// Locate the production source tree from the test file location.
    /// Same seam as `StrongboxLayerTests.sourceRoot(file:)`.
    private func sourceRoot(file: StaticString = #filePath) -> URL {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let testsDir = testFileURL.deletingLastPathComponent()
        let projectRoot = testsDir.deletingLastPathComponent()
        return projectRoot.appendingPathComponent("QuantumSwapWallet")
    }

    /// Read a production source file with line and block comments stripped,
    /// so rationale prose can never satisfy (or trip) a check.
    private func strippedSource(of relativePath: String) throws -> String {
        let url = sourceRoot().appendingPathComponent(relativePath)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "//[^\n]*", with: "", options: .regularExpression)
        return text
    }

    private func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var search = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: search) {
            result.append(r)
            search = r.upperBound..<haystack.endIndex
        }
        return result
    }

    private func windowAfter(_ r: Range<String.Index>, in s: String, length: Int) -> String {
        let end = s.index(r.lowerBound, offsetBy: length,
                          limitedBy: s.endIndex) ?? s.endIndex
        return String(s[r.lowerBound..<end])
    }

    /// Brace-matched body of `func <name>` (a fixed-byte window is fragile;
    /// the brace walk survives edits inside the function).
    private func functionBody(named name: String, in src: String) -> String? {
        guard let fr = src.range(of: "func \(name)") else { return nil }
        guard let openIdx = src[fr.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = openIdx
        while i < src.endIndex {
            let c = src[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return String(src[openIdx...i]) }
            }
            i = src.index(after: i)
        }
        return nil
    }
}
