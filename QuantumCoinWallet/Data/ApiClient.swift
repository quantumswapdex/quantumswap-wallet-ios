// ApiClient.swift
// Port of `ApiClient.java` + `AccountsApi.java`. `URLSession`-based,
// async/await. `OfflineOrExceptionError` equivalent is represented by
// throwing `ApiError.offline` / `.http(status:)` / `.decode(error:)`.
// Android reference:
// app/src/main/java/com/quantumcoinwallet/app/api/read/ApiClient.java
// app/src/main/java/com/quantumcoinwallet/app/api/read/api/AccountsApi.java

import Foundation

public enum ApiError: Error, CustomStringConvertible {

    /// Detail string returned by the scan API (and used for client-side
    /// throttle short-circuits) on HTTP 429.
    public static let scanApiRateLimitDetail =
        "Request exceeded limit. Please retry after some time"

    /// User-facing copy for scan-API rate limiting (HTTP 429 or global
    /// backoff). Callers prefix with context, e.g. "Unable to fetch balance: ".
    public static func rateLimitUserMessage(detail: String? = scanApiRateLimitDetail) -> String {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return "the server is temporarily rate-limiting requests (\(trimmed)). Please wait a minute and try again."
        }
        return "the server is temporarily rate-limiting requests. Please wait a minute and try again."
    }

    case offline
    case http(status: Int, body: String?)
    case decode(Error)
    case other(Error)

    public var description: String {
        switch self {
            case .offline:
            return "network connection unavailable."
            case .http(let status, let body):
            if status == 429 {
                return Self.rateLimitUserMessage(detail: body)
            }
            if let body, !body.isEmpty {
                return "server returned HTTP \(status): \(body)"
            }
            return "server returned HTTP \(status)."
            case .decode:
            return "unexpected response from the server."
            case .other(let err):
            return err.localizedDescription
        }
    }
}

public final class ApiClient: @unchecked Sendable {

    public static let shared = ApiClient()

    // ------------------------------------------------------------------
    // What it closes:
    //   The previous `public var basePath: String = ""` was readable
    //   AND writable from any thread without synchronisation. Real
    //   readers come from URLSession's cooperative pool (the `get`
    //   method below reads `basePath` on whichever queue the await
    //   resumes on); real writers come from the BlockchainNetworkManager
    //   on the main queue. Concurrent read+write on a Swift `String` is
    //   undefined behaviour at the language level - the read can tear
    //   and produce a malformed URL, and on rare scheduling can crash
    //   inside CFString's COW machinery. This is the prior race-condition gap's
    //   ApiClient facet.
    // Why this shape (NSLock + private storage + computed accessor):
    //   Identical to the discipline in `Utilities/Constants.swift`'s
    //   network mirrors and the new `_stateLock` in
    //   `BlockchainNetworkManager`. Reads + writes hop through a
    //   tiny lock window (microseconds) so concurrent observers see
    //   well-defined values.
    // Tradeoffs:
    //   Adds a lock acquisition to every URL composition in `get(...)`.
    //   The lock is uncontended in practice (one writer, intermittent
    //   readers); cost is ~10 ns per acquire on modern iPhones.
    // Cross-references:
    //   - a prior race condition (data race; ApiClient facet).
    //   - `QuantumCoinWallet/Utilities/Constants.swift` for the matching
    //     `_networkLock` pattern this code mirrors.
    //   - `QuantumCoinWallet/Data/BlockchainNetwork.swift`'s
    //     `applyActiveLocked()` which is the only writer in production.
    // ------------------------------------------------------------------
    private let _basePathLock = NSLock()
    nonisolated(unsafe) private var _basePath: String = ""

    /// Current scan API base URL. Updated by `BlockchainNetworkManager`.
    /// Lock-protected accessor: reads and writes are serialised so
    /// concurrent URL-composition readers cannot observe a torn String.
    public var basePath: String {
        get {
            _basePathLock.lock(); defer { _basePathLock.unlock() }
            return _basePath
        }
        set {
            _basePathLock.lock(); defer { _basePathLock.unlock() }
            _basePath = newValue
        }
    }

    /// Strong reference to the TLS-pinning
    /// delegate. `URLSession(configuration:delegate:delegateQueue:)`
    /// retains its delegate weakly inside the session object's
    /// lifetime, but that lifetime is tied to the session being
    /// kept alive; we keep both around for the lifetime of the
    /// `ApiClient` singleton (= the process), so an explicit
    /// reference here makes the ownership obvious to a future
    /// reader and immune to a change in URLSession's retention
    /// rules.
    private let pinningDelegate = TlsPinningSessionDelegate()

    /// TLS-pinning enabled URLSession. Hosts
    /// listed in `TlsPinning.kSpkiPinsByHost` (today: the bundled
    /// `MAINNET` scan API, RPC, and explorer hostnames) require
    /// the server-presented SPKI to match a pinned SHA-256 hash;
    /// any other host falls through to standard system trust.
    /// User-defined networks therefore continue to work, but with
    /// the same baseline trust ceiling iOS would have applied
    /// without this delegate. See `Networking/TlsPinning.swift`
    /// for the full coverage map and rotation procedure.
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        // TLS-version floor for every host this session ever talks
        // to. Refuses sub-TLS-1.3 handshakes; a server that only
        // speaks TLS 1.2 fails with an `errSSLPeerProtocolVersion`
        // / `URLError.secureConnectionFailed` at connect time
        // rather than silently downgrading. iOS 13 introduced the
        // `tls_protocol_version_t` enum used here; the project's
        // deployment target is iOS 15, so no `#available` guard is
        // needed.
        //
        // `tlsMaximumSupportedProtocolVersion` is deliberately left
        // at its default sentinel so a future TLS 1.4 (or any
        // future TLS 1.3 profile Apple ships) can be negotiated
        // transparently. We also intentionally do NOT call any
        // cipher-suite restriction API: cipher curation is the
        // system's job, and freezing the suite list here would
        // risk excluding future PQC-bundled AEADs. Cipher suites
        // are decoupled from key exchange in TLS 1.3, so the PQ
        // hybrid group `X25519MLKEM768` (FIPS 203 ML-KEM-768 +
        // X25519) is negotiated independently by the OS whenever
        // both peers advertise it; nothing on this client either
        // enables or inhibits that negotiation. Sibling reference:
        // Android `TlsPinning.java`'s `TLS_1_3_ONLY` ConnectionSpec.
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv13
        self.session = URLSession(configuration: cfg,
            delegate: pinningDelegate,
            delegateQueue: nil)
    }

    /// Test-only accessor for the configured `URLSession`. Lets
    /// `SecurityFixesTests` assert the TLS-version floor without
    /// going through reflection. NOT for production use; the
    /// session is otherwise reachable only via `get(...)`.
    internal var urlSessionForTests: URLSession { session }

    public func get<T: Decodable>(path: String, as type: T.Type) async throws -> T {
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        let trimmedPath = path.hasPrefix("/") ? path : "/" + path
        // Route the composition through URLComponents
        // so any path / query / fragment characters present in the
        // caller-supplied path are interpreted by the URL spec rather
        // than smuggled into the wrong URL component. AccountsApi
        // pre-validates the address segment via UrlBuilder.apiPath
        // (returns nil and the call short-circuits on validation
        // failure), but URLComponents is the defense-in-depth layer
        // that catches any future caller that forgets to pre-validate.
        guard
        var comps = URLComponents(string: trimmedBase),
        let scheme = comps.scheme?.lowercased(), scheme == "https"
        else {
            throw ApiError.other(URLError(.badURL))
        }
        // Append the path. URLComponents merges paths via simple
        // string concat too, but storing into `.path` lets it
        // re-encode any reserved characters that survived caller
        // validation.
        let basePath = comps.path
        comps.path = (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)
        + trimmedPath
        guard let url = comps.url else {
            throw ApiError.other(URLError(.badURL))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if ScanApiRateLimiter.shared.isThrottled() {
            throw ApiError.http(
                status: 429,
                body: ApiError.scanApiRateLimitDetail)
        }

        await ScanApiRateLimiter.shared.acquireRequestSlot()
        defer { ScanApiRateLimiter.shared.releaseRequestSlot() }

        if ScanApiRateLimiter.shared.isThrottled() {
            throw ApiError.http(
                status: 429,
                body: ApiError.scanApiRateLimitDetail)
        }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw ApiError.other(URLError(.badServerResponse))
            }
            let bodyText = String(data: data, encoding: .utf8)
            if ScanApiRateLimiter.looksLikeRateLimit(
                body: bodyText, status: http.statusCode) {
                ScanApiRateLimiter.shared.recordRateLimit(
                    retryAfter: ScanApiRateLimiter.retryAfterSeconds(from: http))
                throw ApiError.http(
                    status: 429,
                    body: bodyText ?? ApiError.scanApiRateLimitDetail)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ApiError.http(status: http.statusCode, body: bodyText)
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw ApiError.decode(error)
            }
        } catch let urlError as URLError where Self.isOffline(urlError) {
            throw ApiError.offline
        } catch let apiError as ApiError {
            throw apiError
        } catch {
            throw ApiError.other(error)
        }
    }

    private static func isOffline(_ e: URLError) -> Bool {
        switch e.code {
            case .notConnectedToInternet, .networkConnectionLost,
            .cannotFindHost, .cannotConnectToHost, .timedOut,
            .dataNotAllowed: return true
            default: return false
        }
    }
}

// MARK: - AccountsApi
// every public method here takes an `address` argument
// and uses it as a URL path segment. The address is supposed to be
// the wallet's own address (which goes through validation in the
// onboarding / restore flow before being persisted), but because
// the JSON-pref read path can in principle return any string, this
// layer must NOT trust its inputs. Each method validates `address`
// via `QuantumCoinAddress.isValid` and throws `.other(URLError(.badURL))`
// on failure rather than letting an attacker-controlled path segment
// reach `URL(string:)`. The pageIndex is a Swift `Int` so injection
// via that channel is impossible by type.

public enum AccountsApi {

    public static func accountBalance(address: String) async throws -> BalanceResponse {
        guard QuantumCoinAddress.isValid(address) else {
            throw ApiError.other(URLError(.badURL))
        }
        return try await ApiClient.shared.get(
            path: "/account/\(address)",
            as: BalanceResponse.self)
    }

    public static func accountTransactions(address: String, pageIndex: Int)
    async throws -> AccountTransactionSummaryResponse {
        guard QuantumCoinAddress.isValid(address) else {
            throw ApiError.other(URLError(.badURL))
        }
        return try await ApiClient.shared.get(
            path: "/account/\(address)/transactions/\(pageIndex)",
            as: AccountTransactionSummaryResponse.self)
    }

    public static func accountPendingTransactions(address: String, pageIndex: Int)
    async throws -> AccountPendingTransactionSummaryResponse {
        guard QuantumCoinAddress.isValid(address) else {
            throw ApiError.other(URLError(.badURL))
        }
        return try await ApiClient.shared.get(
            path: "/account/\(address)/transactions/pending/\(pageIndex)",
            as: AccountPendingTransactionSummaryResponse.self)
    }

    public static func accountTokens(address: String, pageIndex: Int)
    async throws -> AccountTokenListResponse {
        guard QuantumCoinAddress.isValid(address) else {
            throw ApiError.other(URLError(.badURL))
        }
        return try await ApiClient.shared.get(
            path: "/account/\(address)/tokens/\(pageIndex)",
            as: AccountTokenListResponse.self)
    }
}
