import Foundation

/// Hard-suppression filter for tokens whose name or symbol mimics
/// a known stablecoin denomination ("USDT", "USDC", "Tether",
/// "DAI", etc.) but whose contract address is NOT explicitly
/// recognized by `RecognizedTokens`.
///
/// What it closes
/// --------------
/// On chains where there is no native USD-pegged stablecoin (the
/// case for this network at time of writing), an attacker can
/// deploy a worthless contract and name it "USDT" / "Tether USD"
/// / "USDC". A naive wallet will surface that token in the user's
/// account view simply because the indexer reports it, and the
/// user - trained by years of seeing "USDT" mean "1 dollar" -
/// will believe they have received real value. The wallet vendor
/// has no way to confirm or deny the legitimacy of any third-party
/// contract, so the safest stance is: any token whose label
/// IMPLIES a fiat peg gets hard-suppressed unless the vendor has
/// explicitly recognized its contract address.
///
/// Concretely, this filter is a defense against:
///   - Phishing / value-confusion attacks where the attacker
///     gifts the user a worthless "USDT" token and then asks for
///     a swap.
///   - User mis-clicks in the Send picker; if "USDT" is in the
///     dropdown the user may pick it and send a fake stablecoin
///     thinking they sent a real one.
///
/// Why this shape
/// --------------
/// - Substring match (case-insensitive) instead of exact-equality:
///   real-world impersonators typically pad the symbol ("USDT.e",
///   "USD-Tether", "USDT_v2") to slip exact-match filters.
///   Substring matching defeats those padded variants at the cost
///   of accepting some false positives (see Tradeoffs).
/// - Match against BOTH `symbol` AND `name`: an attacker who only
///   sets `name = "Tether USD"` while leaving `symbol = "XXX"`
///   would still confuse the user inside any UI that renders the
///   name. Both surfaces are checked.
/// - Single chokepoint exposed via `filter(_:)`. Every consumer
///   (`HomeMainViewController`, `SendViewController`) calls this
///   ONE function before partitioning into recognized /
///   unrecognized buckets. There is no "show impersonators"
///   toggle anywhere in the UI - the suppression is total.
/// - The escape hatch is `RecognizedTokens.all`: if a future
///   chain DOES launch a real "USDT" with a known contract, the
///   wallet vendor adds that contract to the recognized list and
///   the filter steps aside for that specific contract.
///
/// Tradeoffs
/// ---------
/// - False positives: a legitimate gaming token literally named
///   "USD-Acres" or a meme token with "stable" in its name will
///   be silently hidden until added to `RecognizedTokens`. We
///   accept this: the wallet user has no immediate way to tell a
///   real "USD-Acres" apart from a phishing "USD-Acres" anyway,
///   so withholding both is strictly safer than surfacing both.
/// - Pattern list is hard-coded in the binary, not loaded from
///   the network. A new fiat denomination (say "MXN-pegged
///   token") would require a binary update to start matching,
///   but that's the same trust boundary as `RecognizedTokens`.
/// - Substring matching against very short fragments (e.g.
///   "usd" inside "Crusader") will produce false positives. The
///   chosen patterns are biased toward fiat-currency
///   abbreviations and known stablecoin brand names so the
///   collision surface is small but non-zero. False positives
///   degrade to the same outcome as a recognized-only display
///   (the user does not see the token), which is an
///   inconvenience, not a value loss.
///
/// Cross-references
/// ----------------
/// - `RecognizedTokens.isRecognized`: the only escape hatch.
/// - `HomeMainViewController.applyFilteredItems`: pre-filters
///   the home tab partition through this enum.
/// - `SendViewController.loadTokens`: pre-filters the picker
///   list through this enum.
enum StablecoinImpersonatorFilter {
    /// Lower-case substring patterns matched against `symbol`
    /// AND `name`. Any match suppresses the token unless its
    /// contract address is in `RecognizedTokens.all`. Patterns
    /// fall into three buckets:
    ///
    /// - Generic stablecoin nouns: `usd`, `dai`, `tether`,
    ///   `stable`, `stablecoin`, `dollar`, `euro`, `yen`,
    ///   `rupee`.
    /// - Specific stablecoin product symbols / brand names:
    ///   `frax`, `fdusd`, `lusd`, `tusd`, `gusd`, `pyusd`, `eurt`,
    ///   `eurc`, `eurs`, `gbpt`, `cny`, `inr`.
    /// - Spelled-out fiat-denomination words used as a
    ///   conservative stand-in for short tickers that would
    ///   otherwise collide with legitimate tokens: `rupiah`
    ///   (Indonesian rupiah; the ticker `idr` is intentionally
    ///   NOT in the list because it would false-positive against
    ///   real tokens like `Hidro` / `Idris`).
    ///
    /// The list is intentionally small. Adding a pattern is
    /// cheap; removing one risks surfacing impersonator tokens.
    /// Stays byte-for-byte aligned with the Android counterpart at
    /// `app/src/main/java/com/quantumcoinwallet/app/tokens/StablecoinImpersonatorFilter.java`.
    static let patterns: [String] = [
        "usd", "dai", "tether", "stable", "stablecoin",
        "frax", "fdusd", "lusd", "tusd", "gusd", "pyusd",
        "eurt", "eurc", "eurs",
        "dollar", "euro", "yen", "gbpt", "cny",
        "inr", "rupee", "rupiah"
    ]

    /// Returns `true` iff the supplied symbol or name contains
    /// any pattern in `patterns` (case-insensitive substring
    /// match). `nil` and empty strings are treated as
    /// non-matching.
    static func impersonatesStablecoin(symbol: String?, name: String?) -> Bool {
        let s = (symbol ?? "").lowercased()
        let n = (name ?? "").lowercased()
        if s.isEmpty && n.isEmpty { return false }
        for p in patterns {
            if !s.isEmpty && s.contains(p) { return true }
            if !n.isEmpty && n.contains(p) { return true }
        }
        return false
    }

    /// Single chokepoint used by every consumer. Returns the
    /// input list with stablecoin-impersonator tokens removed,
    /// EXCEPT for tokens whose contract address is in
    /// `RecognizedTokens.all` (those pass through unchanged
    /// even if their name happens to match a pattern).
    static func filter(_ tokens: [AccountTokenSummary]) -> [AccountTokenSummary] {
        tokens.filter { tok in
            if RecognizedTokens.isRecognized(tok.contractAddress) { return true }
            return !impersonatesStablecoin(symbol: tok.symbol, name: tok.name)
        }
    }
}
