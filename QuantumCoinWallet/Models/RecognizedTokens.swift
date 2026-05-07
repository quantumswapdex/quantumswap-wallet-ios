import Foundation

/// Allow-list of token contract addresses that this wallet build
/// will mark as "recognized" (anti-impersonation / anti-phishing
/// gate).
///
/// What it closes
/// --------------
/// The scan API (`AccountsApi.getAccountTokenList`) returns every
/// ERC-20-style token the indexer has ever seen credited to the
/// account. Without an allow-list, an attacker who deploys a
/// contract named "Heisen" or symbol "HSN" on the same chain would
/// surface alongside the genuine token in the home screen and the
/// Send picker, and the user would have no easy way to tell them
/// apart at the icon / row level.
///
/// We mitigate that by:
///   1. Splitting the home-screen token list into two tabs
///      ("Tokens" vs "Unrecognized Tokens") - see
///      `HomeMainViewController.tokensSegmentedControl`.
///   2. Hiding the "Unrecognized Tokens" surface from the Send
///      picker by default - see
///      `SendViewController.showUnrecognizedTokens`.
///   3. Surfacing the contract address explicitly inside the
///      transaction-confirmation dialog so the user sees the bytes
///      they are signing about - see
///      `TransactionReviewDialogViewController` Contract address
///      section.
///
/// Recognition is keyed strictly by contract address (not by name
/// or symbol) because the contract address is the only field a
/// MitM-able RPC indexer cannot mint copies of.
///
/// Why this shape
/// --------------
/// - Hard-coded `static` constants in the app binary. The set of
///   recognized contracts is part of the trust boundary of this
///   release; it must not be rewritable from disk, from the
///   network, or from the JS bundle.
/// - Lower-cased once at type-init time. Hex-string contract
///   addresses are case-insensitive on chain; lower-casing the
///   constants once means every `isRecognized(_:)` call is a
///   single lower-case + set-membership test.
/// - `Set<String>` lookup is O(1) and avoids any iteration cost
///   even if the recognized list grows to dozens of contracts.
///
/// Tradeoffs
/// ---------
/// - This list ships in the binary and can only change with a new
///   app release; if a new genuine token launches on this chain
///   between releases, users will see it in the "Unrecognized
///   Tokens" tab until the next update. This is the safer
///   default: silent inclusion of an attacker-controlled contract
///   would be far worse than a one-release delay for a real new
///   token.
/// - Recognition does NOT mean "this token has been independently reviewed" -
///   the wallet still has no way to enforce solvency, redemption,
///   or honest balance reporting on a third-party contract. It
///   means only "the wallet vendor vouches that this contract
///   address is the real one for the listed name/symbol".
///
/// Cross-references
/// ----------------
/// - `StablecoinImpersonatorFilter`: hard-suppresses tokens whose
///   name/symbol mimic stablecoins UNLESS their contract address
///   is in this allow-list. Combined with the allow-list, an
///   attacker cannot squat the symbol "USDT" on this chain and
///   appear in the wallet UI at all.
/// - `HomeMainViewController.partitionTokens`: uses
///   `isRecognized(_:)` to split the surviving (non-impersonator)
///   list into recognized vs unrecognized tabs.
/// - `SendViewController.rebuildAssetMenu`: uses `isRecognized(_:)`
///   to decide which entries appear in the asset picker before
///   the "Show Unrecognized Tokens" toggle is consulted.
enum RecognizedTokens {
    /// Heisen (HSN). Hard-coded contract address for the genuine
    /// Heisen token on this chain. Any other contract that
    /// happens to use the name "Heisen" or symbol "HSN" will be
    /// classified as Unrecognized.
    static let heisen = "0xe8ea8beb86e714ef2bde0afac17d6e45d1c35e48f312d6dc12c4fdb90d9e8a3d"

    /// Y2Q (Year-2-Quantum). Hard-coded contract address for the
    /// genuine Y2Q token on this chain. Any other contract that
    /// happens to use the name "Y2Q" or symbol "Y2Q" will be
    /// classified as Unrecognized.
    static let y2q = "0xa8036870874fbed790ed4d3bbd41b2f390b9858ff021f2993e90c6d1cbb167c7"

    /// Lower-cased set of all recognized contract addresses;
    /// computed once at type-init time so each `isRecognized`
    /// call is a single Set lookup. New entries here MUST be
    /// added in lower-case form (or wrapped in `.lowercased()`)
    /// so the membership test stays case-insensitive.
    static let all: Set<String> = [heisen.lowercased(), y2q.lowercased()]

    /// `true` iff the given contract address is in the recognized
    /// allow-list. `nil` and empty inputs return `false` (native
    /// coin sends carry `nil` contract; the native coin row is
    /// surfaced via a separate "QC native" affordance, NOT
    /// through this allow-list).
    static func isRecognized(_ contract: String?) -> Bool {
        guard let raw = contract, !raw.isEmpty else { return false }
        return all.contains(raw.lowercased())
    }
}
