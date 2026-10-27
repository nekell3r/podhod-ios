import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private struct CloudOAuthConfiguration: Decodable {
    let issuer: String
    let clientID: String
    let scopes: [String]
}

private struct CloudOAuthDiscovery: Decodable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let revocationEndpoint: String?
    let codeChallengeMethodsSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
    }
}

private struct CloudOAuthProvider {
    let configuration: CloudOAuthConfiguration
    let authorizationURL: URL
    let tokenURL: URL
    let revocationURL: URL?
}

private struct CloudOAuthCredentials: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let issuer: String
    let clientID: String
}

private struct CloudOAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

private struct CloudOAuthErrorResponse: Decodable {
    let error: String
}

private enum CloudAuthenticationError: LocalizedError {
    case configuration, callback, state, denied, cancelled, presentation, token, expired, storage, network

    var errorDescription: String? {
        switch self {
        case .configuration: "Сервер входа настроен некорректно. Попробуй позже."
        case .callback: "Не удалось подтвердить ответ сервера входа. Начни вход заново."
        case .state: "Ответ входа не относится к этому запросу. Начни вход заново."
        case .denied: "Сервер не разрешил вход. Проверь учётную запись."
        case .cancelled: "Вход отменён."
        case .presentation: "Не удалось открыть системное окно входа. Попробуй ещё раз."
        case .token: "Сервер не выдал действующий токен. Попробуй войти заново."
        case .expired: "Срок входа истёк. Войди заново."
        case .storage: "Не удалось открыть защищённое хранилище авторизации. Разблокируй устройство и повтори действие."
        case .network: "Не удалось связаться с сервером входа. Локальные записи сохранены."
        }
    }
}

final class CloudHTTPSRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let redirected = request.url,
              redirected.scheme?.lowercased() == "https",
              redirected.host?.lowercased() == original.host?.lowercased(),
              redirected.port == original.port,
              redirected.user == nil, redirected.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor @Observable
final class CloudAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let defaultServerURL: URL = {
        let address = Bundle.main.object(forInfoDictionaryKey: "PodhodServerURL") as? String
            ?? "https://api.example.com"
        return URL(string: address) ?? URL(string: "https://api.example.com")!
    }()
    let serverURL: URL
    private(set) var signedIn = false
    private(set) var sessionID = UUID()
    private(set) var isBusy = false
    private(set) var status = "Вход не выполнен"
    var errorMessage: String?

    @ObservationIgnored private var credentials: CloudOAuthCredentials?
    @ObservationIgnored private var browserSession: ASWebAuthenticationSession?
    @ObservationIgnored private var browserContinuation: CheckedContinuation<URL, any Error>?
    @ObservationIgnored private var browserAnchor: ASPresentationAnchor?
    @ObservationIgnored private var browserAttemptID: UUID?
    @ObservationIgnored private var refreshTask: Task<String, any Error>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let http: URLSession
    private let redirectURI = "podhod://oauth/callback"

    init(serverURL: URL = CloudAuthentication.defaultServerURL) {
        self.serverURL = serverURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        http = URLSession(configuration: configuration, delegate: CloudHTTPSRedirectPolicy(), delegateQueue: nil)
        super.init()
        do {
            credentials = try readCredentials()
            signedIn = credentials != nil
            if signedIn { status = "Вход выполнен" }
        } catch {
            errorMessage = CloudAuthenticationError.storage.localizedDescription
        }
    }

    func signIn() async { await signIn(identityProvider: nil) }

    func signInWithTelegram() async { await signIn(identityProvider: "telegram") }

    func accountManagementURL() async -> URL? {
        do {
            let provider = try await loadProvider()
            let issuer = try Self.httpsURL(provider.configuration.issuer)
            var components = URLComponents(url: issuer.appending(path: "account/"), resolvingAgainstBaseURL: false)
            components?.fragment = "/linked-accounts"
            return components?.url
        } catch {
            errorMessage = "Не удалось открыть управление аккаунтом. Проверь соединение."
            return nil
        }
    }

    private func signIn(identityProvider: String?) async {
        guard !isBusy, !signedIn else { return }
        isBusy = true
        errorMessage = nil
        status = "Открываем вход…"
        let operation = generation
        defer { if operation == generation { isBusy = false } }
        do {
            let provider = try await loadProvider()
            let verifier = try Self.randomOAuthValue()
            let state = try Self.randomOAuthValue()
            let challenge = Self.codeChallenge(for: verifier)
            guard var components = URLComponents(url: provider.authorizationURL, resolvingAgainstBaseURL: false) else {
                throw CloudAuthenticationError.configuration
            }
            let queryItems = components.queryItems ?? []
            components.queryItems = queryItems + [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: provider.configuration.clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: provider.configuration.scopes.joined(separator: " ")),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "prompt", value: "login")
            ]
            if let identityProvider {
                components.queryItems?.append(URLQueryItem(name: "kc_idp_hint", value: identityProvider))
            }
            guard let authorizationURL = components.url else { throw CloudAuthenticationError.configuration }
            try checkOperation(operation)
            let callback = try await authenticate(at: authorizationURL)
            try checkOperation(operation)
            let code = try Self.authorizationCode(from: callback, state: state, issuer: provider.configuration.issuer)
            let response = try await requestToken(provider: provider, values: [
                "grant_type": "authorization_code", "client_id": provider.configuration.clientID,
                "redirect_uri": redirectURI, "code": code, "code_verifier": verifier
            ])
            try checkOperation(operation)
            let saved = try Self.tokenCredentials(response, provider: provider, previousRefreshToken: nil)
            try storeCredentials(saved)
            credentials = saved
            sessionID = UUID()
            signedIn = true
            status = "Вход выполнен"
        } catch {
            guard operation == generation else { return }
            if (error as? CloudAuthenticationError) == .cancelled || error is CancellationError {
                status = "Вход отменён"
            } else {
                status = "Вход не выполнен"
                errorMessage = authenticationMessage(error)
            }
        }
    }

    func accessToken() async throws -> String {
        guard let saved = credentials else { throw CloudAuthenticationError.expired }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = saved.refreshToken, !refreshToken.isEmpty else {
            credentials = nil
            signedIn = false
            try? deleteCredentials()
            status = "Нужно войти заново"
            throw CloudAuthenticationError.expired
        }
        let operation = generation
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let provider = try await self.loadProvider()
            guard provider.configuration.issuer == saved.issuer,
                  provider.configuration.clientID == saved.clientID else {
                throw CloudAuthenticationError.configuration
            }
            let response = try await self.requestToken(provider: provider, values: [
                "grant_type": "refresh_token", "client_id": saved.clientID, "refresh_token": refreshToken
            ])
            try self.checkOperation(operation)
            let renewed = try Self.tokenCredentials(response, provider: provider, previousRefreshToken: refreshToken)
            try self.storeCredentials(renewed)
            self.credentials = renewed
            self.status = "Вход выполнен"
            self.errorMessage = nil
            return renewed.accessToken
        }
        refreshTask = task
        defer { if operation == generation { refreshTask = nil } }
        do {
            return try await task.value
        } catch {
            if operation == generation {
                if (error as? CloudAuthenticationError) == .expired {
                    credentials = nil
                    signedIn = false
                    try? deleteCredentials()
                }
                status = "Нужно обновить вход"
                errorMessage = authenticationMessage(error)
            }
            throw error
        }
    }

    func signOut() async {
        let saved = credentials
        generation = UUID()
        sessionID = UUID()
        let operation = generation
        cancelBrowser()
        refreshTask?.cancel()
        refreshTask = nil
        credentials = nil
        signedIn = false
        isBusy = true
        errorMessage = nil
        status = "Выходим…"
        do { try deleteCredentials() }
        catch { errorMessage = CloudAuthenticationError.storage.localizedDescription }
        if let saved {
            do {
                let provider = try await loadProvider()
                if provider.configuration.issuer == saved.issuer,
                   provider.configuration.clientID == saved.clientID,
                   let endpoint = provider.revocationURL {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = Self.oauthForm([
                        "client_id": saved.clientID, "token": saved.refreshToken ?? saved.accessToken,
                        "token_type_hint": saved.refreshToken == nil ? "access_token" : "refresh_token"
                    ])
                    _ = try await http.data(for: request)
                }
            } catch { }
        }
        if operation == generation {
            isBusy = false
            status = "Выполнен выход на этом устройстве"
        }
    }

    private func loadProvider() async throws -> CloudOAuthProvider {
        _ = try Self.httpsURL(serverURL.absoluteString)
        let (configurationData, configurationResponse) = try await http.data(from: serverURL.appending(path: "v1/config"))
        try checkHTTP(configurationResponse)
        let configuration = try JSONDecoder().decode(CloudOAuthConfiguration.self, from: configurationData)
        let issuerURL = try Self.httpsURL(configuration.issuer)
        let (discoveryData, discoveryResponse) = try await http.data(from: issuerURL.appending(path: ".well-known/openid-configuration"))
        try checkHTTP(discoveryResponse)
        let discovery = try JSONDecoder().decode(CloudOAuthDiscovery.self, from: discoveryData)
        return try Self.validatedProvider(configuration: configuration, discovery: discovery)
    }

    private static func validatedProvider(configuration: CloudOAuthConfiguration,
                                          discovery: CloudOAuthDiscovery) throws -> CloudOAuthProvider {
        _ = try httpsURL(configuration.issuer)
        guard configuration.clientID == "podhod-ios", configuration.scopes.contains("openid"),
              configuration.scopes.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }),
              discovery.issuer == configuration.issuer,
              discovery.codeChallengeMethodsSupported?.contains("S256") == true else {
            throw CloudAuthenticationError.configuration
        }
        return try CloudOAuthProvider(configuration: configuration,
                                      authorizationURL: Self.httpsURL(discovery.authorizationEndpoint),
                                      tokenURL: Self.httpsURL(discovery.tokenEndpoint),
                                      revocationURL: discovery.revocationEndpoint.map { try Self.httpsURL($0) })
    }

    private func requestToken(provider: CloudOAuthProvider, values: [String: String]) async throws -> CloudOAuthTokenResponse {
        var request = URLRequest(url: provider.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.oauthForm(values)
        let (data, response) = try await http.data(for: request)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            if (try? JSONDecoder().decode(CloudOAuthErrorResponse.self, from: data).error) == "invalid_grant" {
                throw CloudAuthenticationError.expired
            }
            throw CloudAuthenticationError.token
        }
        try checkHTTP(response)
        return try JSONDecoder().decode(CloudOAuthTokenResponse.self, from: data)
    }

    private static func tokenCredentials(_ response: CloudOAuthTokenResponse, provider: CloudOAuthProvider,
                                  previousRefreshToken: String?) throws -> CloudOAuthCredentials {
        guard !response.accessToken.isEmpty, response.tokenType.lowercased() == "bearer",
              response.expiresIn.isFinite, response.expiresIn > 0 else { throw CloudAuthenticationError.token }
        return CloudOAuthCredentials(accessToken: response.accessToken,
                                     refreshToken: response.refreshToken ?? previousRefreshToken,
                                     expiresAt: Date().addingTimeInterval(response.expiresIn),
                                     issuer: provider.configuration.issuer, clientID: provider.configuration.clientID)
    }

    private static func authorizationCode(from callback: URL, state: String, issuer: String) throws -> String {
        guard callback.scheme == "podhod", callback.host == "oauth", callback.path == "/callback",
              callback.user == nil, callback.password == nil, callback.port == nil, callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw CloudAuthenticationError.callback
        }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == state else { throw CloudAuthenticationError.state }
        let issuers = items.filter { $0.name == "iss" }
        guard issuers.isEmpty || (issuers.count == 1 && issuers[0].value == issuer) else {
            throw CloudAuthenticationError.callback
        }
        guard !items.contains(where: { $0.name == "error" }) else { throw CloudAuthenticationError.denied }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty else { throw CloudAuthenticationError.callback }
        return code
    }

    private func authenticate(at url: URL) async throws -> URL {
        #if canImport(UIKit)
        browserAnchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
        #elseif canImport(AppKit)
        browserAnchor = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
        #endif
        guard browserAnchor != nil else { throw CloudAuthenticationError.presentation }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let attempt = UUID()
                browserAttemptID = attempt
                browserContinuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "podhod") { [weak self] callback, error in
                    Task { @MainActor in
                        guard let self, self.browserAttemptID == attempt,
                              let pending = self.browserContinuation else { return }
                        self.browserContinuation = nil
                        self.browserAttemptID = nil
                        self.browserSession = nil
                        self.browserAnchor = nil
                        if let error {
                            let cancelled = (error as NSError).domain == ASWebAuthenticationSessionError.errorDomain &&
                                (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                            pending.resume(throwing: cancelled ? CloudAuthenticationError.cancelled : .presentation)
                        } else if let callback { pending.resume(returning: callback) }
                        else { pending.resume(throwing: CloudAuthenticationError.callback) }
                    }
                }
                session.presentationContextProvider = self
                browserSession = session
                if !session.start() {
                    browserContinuation = nil
                    browserAttemptID = nil
                    browserSession = nil
                    browserAnchor = nil
                    continuation.resume(throwing: CloudAuthenticationError.presentation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelBrowser() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        browserAnchor ?? ASPresentationAnchor()
    }

    private func cancelBrowser() {
        let pending = browserContinuation
        browserContinuation = nil
        browserAttemptID = nil
        browserSession?.cancel()
        browserSession = nil
        browserAnchor = nil
        pending?.resume(throwing: CloudAuthenticationError.cancelled)
    }

    private func checkOperation(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard operation == generation else { throw CancellationError() }
    }

    private static func httpsURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil, url.query == nil else { throw CloudAuthenticationError.configuration }
        return url
    }

    private func checkHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", (200...299).contains(response.statusCode) else {
            throw CloudAuthenticationError.network
        }
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomOAuthValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CloudAuthenticationError.token
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func oauthForm(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let form = values.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(form.utf8)
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.podhod.training.oauth",
         kSecAttrAccount as String: serverURL.absoluteString]
    }

    private func readCredentials() throws -> CloudOAuthCredentials? {
        var query = keychainQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let resultCode = SecItemCopyMatching(query as CFDictionary, &result)
        if resultCode == errSecItemNotFound { return nil }
        guard resultCode == errSecSuccess, let data = result as? Data else { throw CloudAuthenticationError.storage }
        return try JSONDecoder().decode(CloudOAuthCredentials.self, from: data)
    }

    private func storeCredentials(_ value: CloudOAuthCredentials) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var query = keychainQuery
            for (key, value) in attributes { query[key] = value }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CloudAuthenticationError.storage }
        } else if result != errSecSuccess { throw CloudAuthenticationError.storage }
    }

    private func deleteCredentials() throws {
        let result = SecItemDelete(keychainQuery as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CloudAuthenticationError.storage }
    }

    private func authenticationMessage(_ error: Error) -> String {
        if let error = error as? CloudAuthenticationError { return error.localizedDescription }
        if error is DecodingError { return CloudAuthenticationError.configuration.localizedDescription }
        return CloudAuthenticationError.network.localizedDescription
    }
}
