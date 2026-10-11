import Foundation

/// What the user typed for one security scheme. Which fields matter depends on the scheme kind.
public struct Credential: Codable, Sendable, Hashable {
    /// API key, bearer token or OAuth access token.
    public var secret: String = ""
    public var username: String = ""
    public var password: String = ""
    public var clientID: String = ""
    public var clientSecret: String = ""

    public init(secret: String = "", username: String = "", password: String = "", clientID: String = "", clientSecret: String = "") {
        self.secret = secret
        self.username = username
        self.password = password
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public var isEmpty: Bool {
        secret.isEmpty && username.isEmpty && password.isEmpty && clientID.isEmpty && clientSecret.isEmpty
    }
}

public struct ResolvedAuth: Sendable, Equatable {
    public var headers: [String: String] = [:]
    public var queryItems: [(String, String)] = []
    public var cookies: [(String, String)] = []
    /// Schemes the operation needs but the user hasn't configured.
    public var missingSchemes: [String] = []

    public init() {}

    public static func == (lhs: ResolvedAuth, rhs: ResolvedAuth) -> Bool {
        lhs.headers == rhs.headers && lhs.missingSchemes == rhs.missingSchemes
            && lhs.queryItems.map { "\($0)=\($1)" } == rhs.queryItems.map { "\($0)=\($1)" }
            && lhs.cookies.map { "\($0)=\($1)" } == rhs.cookies.map { "\($0)=\($1)" }
    }
}

public extension SecurityScheme {
    /// Whether the given credential is enough to authenticate with this scheme.
    func canAuthenticate(with credential: Credential?) -> Bool {
        guard let credential else { return false }
        switch kind {
        case .apiKey, .httpBearer, .openIdConnect:
            return !credential.secret.isEmpty
        case .httpBasic:
            return !credential.username.isEmpty
        case .oauth2(let flows):
            if !credential.secret.isEmpty { return true }
            if flows.clientCredentialsTokenURL != nil, !credential.clientID.isEmpty { return true }
            if flows.passwordTokenURL != nil, !credential.username.isEmpty { return true }
            return false
        case .unsupported:
            return false
        }
    }
}

/// Picks the first satisfiable security requirement and turns it into headers/query/cookies.
public struct AuthResolver: Sendable {
    public var schemes: [SecurityScheme]
    public var credentials: [String: Credential]
    public var tokens: OAuthTokenCache

    public init(schemes: [SecurityScheme], credentials: [String: Credential], tokens: OAuthTokenCache = OAuthTokenCache()) {
        self.schemes = schemes
        self.credentials = credentials
        self.tokens = tokens
    }

    public func resolve(_ requirements: [SecurityRequirement]) async throws -> ResolvedAuth {
        guard !requirements.isEmpty else { return ResolvedAuth() }
        let byID = Dictionary(uniqueKeysWithValues: schemes.map { ($0.id, $0) })

        let satisfiable = requirements.first { requirement in
            requirement.keys.allSatisfy { byID[$0]?.canAuthenticate(with: credentials[$0]) == true }
        }
        guard let requirement = satisfiable else {
            var auth = ResolvedAuth()
            auth.missingSchemes = requirements.first.map { $0.keys.sorted() } ?? []
            return auth
        }

        var auth = ResolvedAuth()
        for (name, scopes) in requirement.sorted(by: { $0.key < $1.key }) {
            guard let scheme = byID[name], let credential = credentials[name] else { continue }
            switch scheme.kind {
            case .apiKey(let keyName, let location):
                switch location {
                case .header, .path: auth.headers[keyName] = credential.secret
                case .query: auth.queryItems.append((keyName, credential.secret))
                case .cookie: auth.cookies.append((keyName, credential.secret))
                }
            case .httpBearer, .openIdConnect:
                auth.headers["Authorization"] = "Bearer \(credential.secret)"
            case .httpBasic:
                let token = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
                auth.headers["Authorization"] = "Basic \(token)"
            case .oauth2(let flows):
                let token = credential.secret.isEmpty
                    ? try await tokens.token(scheme: name, flows: flows, credential: credential, scopes: scopes)
                    : credential.secret
                auth.headers["Authorization"] = "Bearer \(token)"
            case .unsupported:
                break
            }
        }
        return auth
    }
}

public enum OAuthError: LocalizedError {
    case tokenRequestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .tokenRequestFailed(let detail): "Could not obtain an OAuth token: \(detail)"
        }
    }
}

/// Fetches and caches OAuth 2 tokens for the client-credentials and password grants.
public actor OAuthTokenCache {
    private struct Entry {
        var token: String
        var expires: Date
    }

    private var cache: [String: Entry] = [:]
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    func token(scheme: String, flows: SecurityScheme.OAuthFlows, credential: Credential, scopes: [String]) async throws -> String {
        let key = "\(scheme)|\(credential.clientID)|\(credential.username)|\(scopes.joined(separator: " "))"
        if let entry = cache[key], entry.expires > .now { return entry.token }

        var form: [String: String] = [:]
        let tokenURL: String
        if let url = flows.clientCredentialsTokenURL, !credential.clientID.isEmpty, credential.username.isEmpty {
            tokenURL = url
            form["grant_type"] = "client_credentials"
        } else if let url = flows.passwordTokenURL {
            tokenURL = url
            form["grant_type"] = "password"
            form["username"] = credential.username
            form["password"] = credential.password
        } else {
            throw OAuthError.tokenRequestFailed("no supported OAuth flow")
        }
        if !scopes.isEmpty { form["scope"] = scopes.joined(separator: " ") }

        guard let url = URL(string: tokenURL) else { throw OAuthError.tokenRequestFailed("invalid token URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !credential.clientID.isEmpty {
            let basic = Data("\(credential.clientID):\(credential.clientSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = RequestBuilder.encodeBody(.object(form.mapValues(JSONValue.string)), contentType: "application/x-www-form-urlencoded").0

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONValue.parse(data)
        guard (200..<300).contains(status), let token = json?["access_token"]?.stringValue else {
            throw OAuthError.tokenRequestFailed("HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let lifetime = json?["expires_in"]?.numberValue ?? 3600
        cache[key] = Entry(token: token, expires: .now.addingTimeInterval(max(lifetime - 30, 30)))
        return token
    }
}
