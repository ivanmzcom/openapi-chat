import Foundation
import Observation
import OpenAPIChatKit
import Security

/// An API the user added. The spec itself is stored next to the index as a separate file.
struct SavedAPI: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var sourceURL: URL?
    var baseURL: String
    var model: ModelChoice = .onDevice
    var disabledOperationIDs: Set<String> = []
    var requiresConfirmation = true
    var addedAt = Date.now
}

@Observable
final class APILibrary {
    private(set) var apis: [SavedAPI] = []
    private var specs: [UUID: APISpec] = [:]
    private var engines: [UUID: ChatEngine] = [:]

    private let directory: URL
    private var indexURL: URL { directory.appending(path: "apis.json") }

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "OpenAPIChat")) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            apis = (try? JSONDecoder().decode([SavedAPI].self, from: data)) ?? []
        }
    }

    // MARK: Adding and removing

    /// Validates the spec and stores it. Throws a user-facing error if it can't be used.
    @discardableResult
    func add(specData: Data, sourceURL: URL?) throws -> SavedAPI {
        let spec = try APISpec(data: specData, sourceURL: sourceURL)
        let api = SavedAPI(name: spec.title, sourceURL: sourceURL, baseURL: spec.servers.first?.url ?? "")
        try specData.write(to: specURL(for: api.id))
        specs[api.id] = spec
        apis.append(api)
        persist()
        return api
    }

    func add(from url: URL) async throws -> SavedAPI {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "El servidor respondió HTTP \(http.statusCode)."])
        }
        return try add(specData: data, sourceURL: url)
    }

    /// Downloads the spec again from its source URL, keeping the user's settings.
    func refresh(_ api: SavedAPI) async throws {
        guard let url = api.sourceURL else { return }
        let (data, _) = try await URLSession.shared.data(from: url)
        let spec = try APISpec(data: data, sourceURL: url)
        try data.write(to: specURL(for: api.id))
        specs[api.id] = spec
        engines[api.id] = nil
    }

    func remove(_ api: SavedAPI) {
        apis.removeAll { $0.id == api.id }
        specs[api.id] = nil
        engines[api.id] = nil
        try? FileManager.default.removeItem(at: specURL(for: api.id))
        Keychain.deleteCredentials(for: api.id)
        persist()
    }

    func update(_ api: SavedAPI) {
        guard let index = apis.firstIndex(where: { $0.id == api.id }) else { return }
        apis[index] = api
        persist()
        engines[api.id]?.configuration = configuration(for: api)
    }

    // MARK: Specs and chat engines

    func spec(for api: SavedAPI) throws -> APISpec {
        if let spec = specs[api.id] { return spec }
        let spec = try APISpec(data: Data(contentsOf: specURL(for: api.id)), sourceURL: api.sourceURL)
        specs[api.id] = spec
        return spec
    }

    func engine(for api: SavedAPI) throws -> ChatEngine {
        if let engine = engines[api.id] { return engine }
        let engine = ChatEngine(spec: try spec(for: api), configuration: configuration(for: api))
        engines[api.id] = engine
        return engine
    }

    func credentialsDidChange(for api: SavedAPI) {
        engines[api.id]?.configuration = configuration(for: api)
    }

    private func configuration(for api: SavedAPI) -> ChatConfiguration {
        let allIDs = (try? spec(for: api).operations.map(\.id)) ?? []
        return ChatConfiguration(
            baseURL: api.baseURL,
            credentials: Keychain.credentials(for: api.id),
            enabledOperationIDs: api.disabledOperationIDs.isEmpty ? nil : Set(allIDs).subtracting(api.disabledOperationIDs),
            model: api.model.effective,
            requiresConfirmation: api.requiresConfirmation
        )
    }

    // MARK: Persistence

    private func specURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).spec")
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(apis) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

/// Stores each API's credentials as one Keychain item.
enum Keychain {
    private static let service = "com.ivanmz.OpenAPIChat.credentials"

    static func credentials(for apiID: UUID) -> [String: Credential] {
        var query = baseQuery(apiID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: Credential].self, from: data)) ?? [:]
    }

    /// Returns an error message if the credentials could not be stored.
    @discardableResult
    static func save(_ credentials: [String: Credential], for apiID: UUID) -> String? {
        let filtered = credentials.filter { !$0.value.isEmpty }
        deleteCredentials(for: apiID)
        guard !filtered.isEmpty, let data = try? JSONEncoder().encode(filtered) else { return nil }
        var item = baseQuery(apiID)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "código \(status)"
            return "No se pudieron guardar las credenciales en el llavero: \(reason)"
        }
        return nil
    }

    static func deleteCredentials(for apiID: UUID) {
        SecItemDelete(baseQuery(apiID) as CFDictionary)
    }

    private static func baseQuery(_ apiID: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiID.uuidString,
        ]
        #if os(iOS)
        // On macOS the data-protection keychain needs a keychain-access-groups entitlement,
        // so the sandboxed app uses its regular (file-based) keychain there instead.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
