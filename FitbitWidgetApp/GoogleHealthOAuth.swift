#if !WIDGET_EXTENSION
import AppKit
#endif
import CryptoKit
import Foundation
import Network
import Security

struct GoogleHealthConfiguration: Sendable {
    static let clientIDInfoKey = "GoogleHealthOAuthClientID"
    static let clientSecretInfoKey = "GoogleHealthOAuthClientSecret"
    static let callbackPath = "/oauth2/callback"

    let clientID: String
    let clientSecret: String?
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let healthAPIBaseURL: URL

    init(
        clientID: String,
        clientSecret: String? = nil,
        authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        healthAPIBaseURL: URL = URL(string: "https://health.googleapis.com/v4/")!
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.healthAPIBaseURL = healthAPIBaseURL
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        try load(
            clientID: bundle.object(forInfoDictionaryKey: clientIDInfoKey) as? String,
            clientSecret: bundle.object(forInfoDictionaryKey: clientSecretInfoKey) as? String
        )
    }

    static func load(clientID: String?, clientSecret: String?) throws -> Self {
        guard let clientID = configuredValue(clientID) else {
            throw GoogleHealthOAuthError.missingConfiguration
        }
        guard let clientSecret = configuredValue(clientSecret) else {
            throw GoogleHealthOAuthError.missingClientSecret
        }
        return Self(clientID: clientID, clientSecret: clientSecret)
    }

    private static func configuredValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

}
enum GoogleHealthScope {
    static let activity = "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly"
    static let sleep = "https://www.googleapis.com/auth/googlehealth.sleep.readonly"
    static let healthMetrics = "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly"
    static let requested = [activity, sleep, healthMetrics]

    static func permissions(from scopes: Set<String>) -> MetricPermissions {
        var metrics = Set<MetricKind>()
        if scopes.contains(activity) { metrics.insert(.steps) }
        if scopes.contains(sleep) { metrics.insert(.sleep) }
        if scopes.contains(healthMetrics) {
            metrics.insert(.restingHeartRate)
            metrics.insert(.hrv)
        }
        return MetricPermissions(metrics)
    }

    static func metrics(for metric: MetricKind) -> Set<MetricKind> {
        switch metric {
        case .steps: [.steps]
        case .sleep: [.sleep]
        case .restingHeartRate, .hrv: [.restingHeartRate, .hrv]
        }
    }
}
struct PKCEPair: Equatable, Sendable {
    let verifier: String
    let challenge: String

    static func generate(randomByteCount: Int = 64) throws -> Self {
        guard (32...96).contains(randomByteCount) else { throw GoogleHealthOAuthError.randomGenerationFailed }
        var bytes = [UInt8](repeating: 0, count: randomByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GoogleHealthOAuthError.randomGenerationFailed
        }

        let verifier = Data(bytes).base64URLEncodedString()
        return Self(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

enum OAuthCallbackResult: Equatable, Sendable {
    case code(String, scopes: Set<String>? = nil)
    case cancelled
}

enum OAuthCallbackValidator {
    static func validate(
        _ url: URL,
        expectedPath: String,
        expectedState: String,
        expectedPort: UInt16
    ) throws -> OAuthCallbackResult {
        guard url.scheme == "http",
              url.host == "127.0.0.1",
              url.port == Int(expectedPort),
              url.path == expectedPath,
              url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GoogleHealthOAuthError.invalidCallback
        }

        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              !items.contains(where: { $0.value == nil }),
              !(items.contains(where: { $0.name == "code" })
                && items.contains(where: { $0.name == "error" })) else {
            throw GoogleHealthOAuthError.invalidCallback
        }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })

        guard values["state"] == expectedState else {
            throw GoogleHealthOAuthError.stateMismatch
        }

        if values["error"] == "access_denied" {
            return .cancelled
        }
        if values["error"] != nil {
            throw GoogleHealthOAuthError.authorizationDenied
        }
        guard let code = values["code"], !code.isEmpty else {
            throw GoogleHealthOAuthError.invalidCallback
        }
        return .code(code, scopes: values["scope"].map { Set($0.split(separator: " ").map(String.init)) })
    }
}

struct OAuthTokenResponse: Decodable, Equatable, Sendable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let refreshTokenExpiresIn: Int?
    let scope: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case scope
        case tokenType = "token_type"
    }
}

struct OAuthTokenSet: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accessTokenExpiration: Date
    let refreshTokenExpiration: Date?
    let grantedScopes: Set<String>
    let healthUserID: String?

    init(
        accessToken: String,
        refreshToken: String,
        accessTokenExpiration: Date,
        refreshTokenExpiration: Date?,
        grantedScopes: Set<String>,
        healthUserID: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiration = accessTokenExpiration
        self.refreshTokenExpiration = refreshTokenExpiration
        self.grantedScopes = grantedScopes
        self.healthUserID = healthUserID
    }

    func verified(for healthUserID: String) -> Self {
        Self(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiration: accessTokenExpiration,
            refreshTokenExpiration: refreshTokenExpiration,
            grantedScopes: grantedScopes,
            healthUserID: healthUserID
        )
    }
}

struct OAuthTokenStore {
    static let key = "google-health-oauth-tokens"

    // Only opaque Data crosses the existing Keychain boundary. Tests inject memory closures.
    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    private let delete: () throws -> Void

    init(keychain: SharedKeychain) {
        self.init(
            read: { try keychain.data(forKey: Self.key) },
            write: { try keychain.store($0, forKey: Self.key) },
            delete: { try keychain.deleteData(forKey: Self.key) }
        )
    }

    init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void,
         delete: @escaping () throws -> Void) {
        self.read = read
        self.write = write
        self.delete = delete
    }

    func load() throws -> OAuthTokenSet? {
        guard let data = try read() else { return nil }
        return try JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    func save(_ tokens: OAuthTokenSet) throws {
        try write(JSONEncoder().encode(tokens))
    }

    func clear() throws { try delete() }
}

enum GoogleHealthOAuthError: Error, Equatable {
    case missingConfiguration
    case missingClientSecret
    case randomGenerationFailed
    case listenerFailed
    case timedOut
    case invalidCallback
    case stateMismatch
    case authorizationDenied
    case browserOpenFailed
    case invalidTokenResponse
    case tokenExchangeFailed
    case tokenRequestRejected(status: Int, reason: String)
    case clientSecretRequired
    case refreshUnavailable
    case retryable(retryAfter: TimeInterval?)
}

struct GoogleHealthAuthorizer: Sendable {
    let configuration: GoogleHealthConfiguration
    let session: URLSession

    init(configuration: GoogleHealthConfiguration, session: URLSession = GoogleHealthHTTP.makeSession()) {
        self.configuration = configuration
        self.session = session
    }

    #if !WIDGET_EXTENSION
    func authorize() async throws -> OAuthTokenSet? {
        let pkce = try PKCEPair.generate()
        let state = try secureRandomString(byteCount: 32)
        let listener = OAuthLoopbackListener(
            callbackPath: GoogleHealthConfiguration.callbackPath,
            expectedState: state
        )
        defer { listener.cancel() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await authorize(pkce: pkce, state: state, listener: listener)
        } onCancel: {
            listener.cancel()
        }
    }

    private func authorize(pkce: PKCEPair, state: String, listener: OAuthLoopbackListener) async throws -> OAuthTokenSet? {
        let redirectURI = try await listener.start()
        try Task.checkCancellation()
        let authorizationURL = try makeAuthorizationURL(
            redirectURI: redirectURI,
            state: state,
            challenge: pkce.challenge
        )

        let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        guard opened else { throw GoogleHealthOAuthError.browserOpenFailed }

        let callback = try await withTaskCancellationHandler {
            try await listener.waitForCallback()
        } onCancel: {
            listener.cancel()
        }

        guard case let .code(code, callbackScopes) = callback else { return nil }
        let response = try await exchangeAuthorizationCode(
            code,
            verifier: pkce.verifier,
            redirectURI: redirectURI
        )
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw GoogleHealthOAuthError.invalidTokenResponse
        }

        let now = Date()
        return OAuthTokenSet(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            accessTokenExpiration: now.addingTimeInterval(TimeInterval(response.expiresIn)),
            refreshTokenExpiration: response.refreshTokenExpiresIn.map {
                now.addingTimeInterval(TimeInterval($0))
            },
            grantedScopes: response.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? callbackScopes ?? [],
            healthUserID: nil
        )
    }

    #endif

    func refresh(_ tokens: OAuthTokenSet) async throws -> OAuthTokenSet {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = tokenRequestBody([
            "client_id": configuration.clientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token"
        ])

        let response = try await performTokenRequest(request)
        let now = Date()
        let scopes = response.scope.map {
            Set($0.split(separator: " ").map(String.init))
        } ?? tokens.grantedScopes

        return OAuthTokenSet(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? tokens.refreshToken,
            accessTokenExpiration: now.addingTimeInterval(TimeInterval(response.expiresIn)),
            refreshTokenExpiration: response.refreshTokenExpiresIn.map {
                now.addingTimeInterval(TimeInterval($0))
            } ?? tokens.refreshTokenExpiration,
            grantedScopes: scopes,
            healthUserID: tokens.healthUserID
        )
    }

    func makeAuthorizationURL(
        redirectURI: URL,
        state: String,
        challenge: String
    ) throws -> URL {
        guard var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw GoogleHealthOAuthError.missingConfiguration
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "scope", value: GoogleHealthScope.requested.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components.url else { throw GoogleHealthOAuthError.missingConfiguration }
        return url
    }

    func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        redirectURI: URL
    ) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = tokenRequestBody([
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI.absoluteString
        ])
        return try await performTokenRequest(request)
    }

    private func tokenRequestBody(_ fields: [String: String]) -> Data {
        var fields = fields
        if let clientSecret = configuration.clientSecret, !clientSecret.isEmpty {
            fields["client_secret"] = clientSecret
        }
        return formBody(fields)
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> OAuthTokenResponse {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                throw GoogleHealthOAuthError.retryable(retryAfter: http.statusCode == 429 ? max(30, HTTPRetryDelay.parse(http.value(forHTTPHeaderField: "Retry-After")) ?? 30) : HTTPRetryDelay.parse(http.value(forHTTPHeaderField: "Retry-After")))
            }
            let rejection = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            // Classify only; never show or persist Google's free-form description.
            if let description = rejection?.description?.lowercased(),
               description.contains("client_secret"), description.contains("missing") {
                throw GoogleHealthOAuthError.clientSecretRequired
            }
            if rejection?.error == "invalid_grant",
               String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("grant_type=refresh_token") == true {
                throw GoogleHealthOAuthError.refreshUnavailable
            }
            let allowed = ["invalid_client", "invalid_grant", "invalid_request", "unauthorized_client",
                           "access_denied", "unsupported_grant_type", "invalid_scope"]
            let reason = rejection.flatMap { allowed.contains($0.error) ? $0.error : nil } ?? "unclassified"
            throw GoogleHealthOAuthError.tokenRequestRejected(status: http.statusCode, reason: reason)
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let tokenResponse = try? JSONDecoder().decode(OAuthTokenResponse.self, from: data),
              !tokenResponse.accessToken.isEmpty,
              tokenResponse.expiresIn > 0,
              tokenResponse.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw GoogleHealthOAuthError.tokenExchangeFailed
        }
        return tokenResponse
    }
}

// All mutable listener state is confined to queue, including cancellation and continuations.
final class OAuthLoopbackListener: @unchecked Sendable {
    private let callbackPath: String
    private let expectedState: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.yahsiu.FitbitWidget.oauth-loopback")
    private var listener: NWListener?
    private var port: UInt16?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<OAuthCallbackResult, Error>?
    private var result: Result<OAuthCallbackResult, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(callbackPath: String, expectedState: String, timeout: TimeInterval = 180) {
        self.callbackPath = callbackPath
        self.expectedState = expectedState
        self.timeout = timeout
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard result == nil else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                startContinuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(GoogleHealthOAuthError.timedOut))
                    }
                } catch {
                    finish(.failure(GoogleHealthOAuthError.listenerFailed))
                }
            }
        }
    }

    func waitForCallback() async throws -> OAuthCallbackResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let result { continuation.resume(with: result) }
                else { callbackContinuation = continuation }
            }
        }
    }

    func cancel() {
        queue.async { [self] in finish(.failure(CancellationError())) }
    }

    private func handle(_ state: NWListener.State) {
        guard result == nil else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue,
                  let url = URL(string: "http://127.0.0.1:\(port)\(callbackPath)") else {
                finish(.failure(GoogleHealthOAuthError.listenerFailed))
                return
            }
            self.port = port
            startContinuation?.resume(returning: url)
            startContinuation = nil
        case .failed:
            finish(.failure(GoogleHealthOAuthError.listenerFailed))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            connection?.cancel()
            self?.connections.removeValue(forKey: id)
        }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, result == nil else { connection.cancel(); return }
            var buffer = buffer
            buffer.append(data ?? Data())
            guard buffer.count <= 16_384 else {
                respond("400 Bad Request", body: "Invalid callback.", on: connection)
                return
            }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() }
                else { receive(connection, buffer: buffer) }
                return
            }
            guard let request = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first,
                  let port else { connection.cancel(); return }
            let parts = firstLine.split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
                  parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
                  let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])") else {
                respond("400 Bad Request", body: "Invalid callback.", on: connection)
                return
            }
            do {
                let callback = try OAuthCallbackValidator.validate(
                    url, expectedPath: callbackPath, expectedState: expectedState, expectedPort: port
                )
                respond("200 OK", body: "You can close this window and return to Fitbit Widget.", on: connection)
                finish(.success(callback), keeping: connection)
            } catch GoogleHealthOAuthError.invalidCallback, GoogleHealthOAuthError.stateMismatch {
                respond("400 Bad Request", body: "Invalid callback.", on: connection)
            } catch {
                respond("400 Bad Request", body: "Authorization did not complete.", on: connection)
                finish(.failure(error), keeping: connection)
            }
        }
    }

    private func respond(_ status: String, body: String, on connection: NWConnection) {
        let html = "<html><body><p>\(body)</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
        })
    }

    private func finish(_ result: Result<OAuthCallbackResult, Error>, keeping: NWConnection? = nil) {
        guard self.result == nil else { return }
        self.result = result
        listener?.cancel()
        listener = nil
        for connection in connections.values where connection !== keeping { connection.cancel() }
        connections.removeAll()
        startContinuation?.resume(throwing: result.failure ?? CancellationError())
        startContinuation = nil
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
    }
}

private extension Result {
    var failure: Failure? { if case let .failure(error) = self { error } else { nil } }
}

private struct TokenErrorResponse: Decodable {
    let error: String
    let description: String?
    enum CodingKeys: String, CodingKey { case error; case description = "error_description" }
}

// No URL cache, cookies, credential store, or redirects for token/health requests.
enum GoogleHealthHTTP {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

private func secureRandomString(byteCount: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw GoogleHealthOAuthError.randomGenerationFailed
    }
    return Data(bytes).base64URLEncodedString()
}

private func formBody(_ parameters: [String: String]) -> Data {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let text = parameters.sorted(by: { $0.key < $1.key }).map {
        "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&")
    return Data(text.utf8)
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
