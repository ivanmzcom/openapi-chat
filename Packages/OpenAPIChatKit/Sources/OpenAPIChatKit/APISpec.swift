import Foundation

public enum OpenAPIError: LocalizedError, Equatable {
    case invalidDocument(String)
    case unsupportedVersion(String)
    case noOperations

    public var errorDescription: String? {
        switch self {
        case .invalidDocument(let reason): "La spec no es válida. \(reason)"
        case .unsupportedVersion(let version): "Versión de spec no soportada: \(version). Se admiten OpenAPI 3.x y Swagger 2.0."
        case .noOperations: "La spec no define ninguna operación."
        }
    }
}

public enum ParameterLocation: String, Sendable, Hashable, Codable {
    case path, query, header, cookie
}

public struct APIParameter: Sendable, Hashable {
    public var name: String
    public var location: ParameterLocation
    public var isRequired: Bool
    public var description: String?
    /// JSON Schema of the parameter (still may contain `$ref`s, resolved lazily).
    public var schema: JSONValue
    public var style: String?
    public var explode: Bool?
}

public struct APIRequestBody: Sendable, Hashable {
    public var contentType: String
    public var schema: JSONValue
    public var isRequired: Bool
    public var description: String?

    public var isJSON: Bool { contentType.contains("json") || contentType == "*/*" }
    public var isForm: Bool { contentType.contains("form") }
}

public typealias SecurityRequirement = [String: [String]]

public struct APIOperation: Sendable, Hashable, Identifiable {
    /// Unique, tool-safe identifier (derived from `operationId` when present).
    public var id: String
    public var operationId: String?
    public var method: String
    public var path: String
    public var summary: String?
    public var description: String?
    public var tags: [String]
    public var parameters: [APIParameter]
    public var requestBody: APIRequestBody?
    /// `nil` means the operation inherits the document-level security.
    public var security: [SecurityRequirement]?
    public var isDeprecated: Bool

    public var isMutating: Bool { !["GET", "HEAD", "OPTIONS"].contains(method) }

    public var displayTitle: String {
        if let summary, !summary.isEmpty { return summary }
        return operationId ?? "\(method) \(path)"
    }
}

public struct APIServer: Sendable, Hashable, Identifiable {
    public var url: String
    public var description: String?
    public var id: String { url }
}

public struct SecurityScheme: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case apiKey(name: String, location: ParameterLocation)
        case httpBearer(format: String?)
        case httpBasic
        case oauth2(OAuthFlows)
        case openIdConnect(url: String)
        case unsupported(String)
    }

    public struct OAuthFlows: Sendable, Hashable {
        public var clientCredentialsTokenURL: String?
        public var passwordTokenURL: String?
        public var authorizationURL: String?
        public var scopes: [String: String]
    }

    public var id: String
    public var kind: Kind
    public var description: String?
}

/// A parsed OpenAPI 3.x or Swagger 2.0 document reduced to what the chatbot needs.
public struct APISpec: Sendable {
    public var title: String
    public var version: String
    public var summary: String?
    public var specVersion: String
    public var servers: [APIServer]
    public var operations: [APIOperation]
    public var securitySchemes: [SecurityScheme]
    public var globalSecurity: [SecurityRequirement]
    public let root: JSONValue

    public var isSwagger2: Bool { specVersion.hasPrefix("2") }

    public init(data: Data, sourceURL: URL? = nil) throws {
        let root = try JSONValue.parse(data)
        try self.init(root: root, sourceURL: sourceURL)
    }

    public init(root: JSONValue, sourceURL: URL? = nil) throws {
        guard root.objectValue != nil else { throw OpenAPIError.invalidDocument("La raíz no es un objeto.") }
        self.root = root
        if let v = root["openapi"]?.stringValue {
            guard v.hasPrefix("3") else { throw OpenAPIError.unsupportedVersion(v) }
            specVersion = v
        } else if let v = root["swagger"]?.stringValue {
            guard v.hasPrefix("2") else { throw OpenAPIError.unsupportedVersion(v) }
            specVersion = v
        } else {
            throw OpenAPIError.invalidDocument("Falta el campo `openapi` o `swagger`.")
        }

        title = root["info"]?["title"]?.stringValue ?? "API"
        version = root["info"]?["version"]?.scalarText ?? ""
        summary = root["info"]?["description"]?.stringValue ?? root["info"]?["summary"]?.stringValue
        globalSecurity = Self.parseSecurity(root["security"]) ?? []
        servers = []
        operations = []
        securitySchemes = []

        servers = isSwagger2 ? swagger2Servers(sourceURL: sourceURL) : openAPI3Servers(sourceURL: sourceURL)
        securitySchemes = parseSecuritySchemes()
        operations = parseOperations()
        describeUndocumentedPathParameters()
        if operations.isEmpty { throw OpenAPIError.noOperations }
    }

    // MARK: References

    /// Follows a local `$ref` (`#/components/...` or `#/definitions/...`). External refs resolve to `{}`.
    public func resolve(_ value: JSONValue, maxHops: Int = 16) -> JSONValue {
        var current = value
        for _ in 0..<maxHops {
            guard let ref = current["$ref"]?.stringValue else { return current }
            guard let target = pointer(ref) else { return .object([:]) }
            current = target
        }
        return current
    }

    public func pointer(_ ref: String) -> JSONValue? {
        guard ref.hasPrefix("#") else { return nil }
        var node = root
        for raw in ref.dropFirst().split(separator: "/") {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            let key = token.removingPercentEncoding ?? token
            switch node {
            case .object(let dict):
                guard let next = dict[key] else { return nil }
                node = next
            case .array(let array):
                guard let i = Int(key), array.indices.contains(i) else { return nil }
                node = array[i]
            default:
                return nil
            }
        }
        return node
    }

    // MARK: Servers

    private func openAPI3Servers(sourceURL: URL?) -> [APIServer] {
        let raw = root["servers"]?.arrayValue ?? []
        var result: [APIServer] = raw.compactMap { server in
            guard var url = server["url"]?.stringValue else { return nil }
            for (name, variable) in server["variables"]?.objectValue ?? [:] {
                url = url.replacingOccurrences(of: "{\(name)}", with: variable["default"]?.scalarText ?? "")
            }
            return APIServer(url: Self.absolute(url, relativeTo: sourceURL), description: server["description"]?.stringValue)
        }
        if result.isEmpty, let sourceURL {
            result = [APIServer(url: Self.absolute("/", relativeTo: sourceURL), description: nil)]
        }
        return result.filter { !$0.url.isEmpty }
    }

    private func swagger2Servers(sourceURL: URL?) -> [APIServer] {
        let host = root["host"]?.stringValue ?? sourceURL?.host().map { h in sourceURL?.port.map { "\(h):\($0)" } ?? h }
        guard let host else { return [] }
        let basePath = root["basePath"]?.stringValue ?? ""
        var schemes = root["schemes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if schemes.isEmpty { schemes = [sourceURL?.scheme ?? "https"] }
        schemes.sort { a, _ in a == "https" }
        return schemes.map { APIServer(url: "\($0)://\(host)\(basePath)", description: nil) }
    }

    static func absolute(_ url: String, relativeTo base: URL?) -> String {
        if url.contains("://") { return url }
        guard let base, let resolved = URL(string: url, relativeTo: base)?.absoluteURL else { return url.hasPrefix("/") ? "" : url }
        return resolved.absoluteString
    }

    // MARK: Security

    static func parseSecurity(_ value: JSONValue?) -> [SecurityRequirement]? {
        guard let array = value?.arrayValue else { return nil }
        return array.compactMap { item in
            item.objectValue?.mapValues { $0.arrayValue?.compactMap(\.stringValue) ?? [] }
        }
    }

    private func parseSecuritySchemes() -> [SecurityScheme] {
        let raw = (isSwagger2 ? root["securityDefinitions"] : root["components"]?["securitySchemes"])?.objectValue ?? [:]
        return raw.keys.sorted().map { name in
            let def = resolve(raw[name]!)
            let type = def["type"]?.stringValue ?? ""
            let kind: SecurityScheme.Kind
            switch type {
            case "apiKey":
                let location = ParameterLocation(rawValue: def["in"]?.stringValue ?? "header") ?? .header
                kind = .apiKey(name: def["name"]?.stringValue ?? name, location: location)
            case "http":
                switch def["scheme"]?.stringValue?.lowercased() {
                case "bearer": kind = .httpBearer(format: def["bearerFormat"]?.stringValue)
                case "basic": kind = .httpBasic
                case let other: kind = .unsupported("http \(other ?? "")")
                }
            case "basic":
                kind = .httpBasic
            case "oauth2":
                kind = .oauth2(isSwagger2 ? swagger2Flows(def) : openAPI3Flows(def))
            case "openIdConnect":
                kind = .openIdConnect(url: def["openIdConnectUrl"]?.stringValue ?? "")
            default:
                kind = .unsupported(type)
            }
            return SecurityScheme(id: name, kind: kind, description: def["description"]?.stringValue)
        }
    }

    private func openAPI3Flows(_ def: JSONValue) -> SecurityScheme.OAuthFlows {
        let flows = def["flows"]
        var scopes: [String: String] = [:]
        for flow in (flows?.objectValue ?? [:]).values {
            for (k, v) in flow["scopes"]?.objectValue ?? [:] { scopes[k] = v.stringValue ?? "" }
        }
        return .init(
            clientCredentialsTokenURL: flows?["clientCredentials"]?["tokenUrl"]?.stringValue,
            passwordTokenURL: flows?["password"]?["tokenUrl"]?.stringValue,
            authorizationURL: (flows?["authorizationCode"] ?? flows?["implicit"])?["authorizationUrl"]?.stringValue,
            scopes: scopes
        )
    }

    private func swagger2Flows(_ def: JSONValue) -> SecurityScheme.OAuthFlows {
        let flow = def["flow"]?.stringValue
        let scopes = (def["scopes"]?.objectValue ?? [:]).mapValues { $0.stringValue ?? "" }
        return .init(
            clientCredentialsTokenURL: flow == "application" ? def["tokenUrl"]?.stringValue : nil,
            passwordTokenURL: flow == "password" ? def["tokenUrl"]?.stringValue : nil,
            authorizationURL: def["authorizationUrl"]?.stringValue,
            scopes: scopes
        )
    }

    // MARK: Operations

    // HEAD, OPTIONS and TRACE add nothing to a chat and crowd the router.
    private static let methods = ["get", "post", "put", "patch", "delete"]
    private static let ignoredHeaders: Set<String> = ["accept", "content-type", "authorization"]

    private func parseOperations() -> [APIOperation] {
        let paths = root["paths"]?.objectValue ?? [:]
        var usedIDs = Set<String>()
        var result: [APIOperation] = []
        for path in paths.keys.sorted() {
            let item = resolve(paths[path]!)
            let shared = item["parameters"]?.arrayValue ?? []
            for method in Self.methods {
                guard let op = item[method]?.objectValue.map(JSONValue.object) else { continue }
                var operation = parseOperation(op, method: method, path: path, sharedParameters: shared)
                operation.id = Self.uniqueID(Self.toolName(for: operation), used: &usedIDs)
                result.append(operation)
            }
        }
        return result
    }

    private func parseOperation(_ op: JSONValue, method: String, path: String, sharedParameters: [JSONValue]) -> APIOperation {
        // Operation-level parameters override path-level ones with the same name + location.
        var rawParams: [String: JSONValue] = [:]
        var order: [String] = []
        for param in sharedParameters + (op["parameters"]?.arrayValue ?? []) {
            let p = resolve(param)
            let key = "\(p["in"]?.stringValue ?? ""):\(p["name"]?.stringValue ?? "")"
            if rawParams[key] == nil { order.append(key) }
            rawParams[key] = p
        }

        var parameters: [APIParameter] = []
        var requestBody: APIRequestBody?
        var formProperties: [String: JSONValue] = [:]
        var formRequired: [JSONValue] = []

        for key in order {
            let p = rawParams[key]!
            guard let name = p["name"]?.stringValue, let location = p["in"]?.stringValue else { continue }
            let description = p["description"]?.stringValue
            switch location {
            case "body":
                requestBody = APIRequestBody(
                    contentType: preferredContentType(op["consumes"]?.arrayValue ?? root["consumes"]?.arrayValue),
                    schema: p["schema"] ?? .object([:]),
                    isRequired: p["required"]?.boolValue ?? false,
                    description: description
                )
            case "formData":
                if p["type"]?.stringValue == "file" { continue }
                formProperties[name] = swagger2ParameterSchema(p)
                if p["required"]?.boolValue == true { formRequired.append(.string(name)) }
            default:
                guard let loc = ParameterLocation(rawValue: location) else { continue }
                if loc == .header, Self.ignoredHeaders.contains(name.lowercased()) { continue }
                let schema: JSONValue
                if let s = p["schema"] {
                    schema = s
                } else if let content = p["content"]?.objectValue, let first = content.values.first {
                    schema = first["schema"] ?? .object([:])
                } else {
                    schema = swagger2ParameterSchema(p)
                }
                parameters.append(APIParameter(
                    name: name,
                    location: loc,
                    isRequired: loc == .path || (p["required"]?.boolValue ?? false),
                    description: description,
                    schema: schema,
                    style: p["style"]?.stringValue ?? p["collectionFormat"]?.stringValue,
                    explode: p["explode"]?.boolValue
                ))
            }
        }

        if !formProperties.isEmpty {
            let consumes = op["consumes"]?.arrayValue ?? root["consumes"]?.arrayValue
            let multipart = consumes?.contains { $0.stringValue?.contains("multipart") == true } ?? false
            requestBody = APIRequestBody(
                contentType: multipart ? "multipart/form-data" : "application/x-www-form-urlencoded",
                schema: .object(["type": .string("object"), "properties": .object(formProperties), "required": .array(formRequired)]),
                isRequired: !formRequired.isEmpty,
                description: nil
            )
        }

        if let body = op["requestBody"].map({ resolve($0) }), let content = body["content"]?.objectValue {
            let contentType = preferredContentType(content.keys.map(JSONValue.string))
            requestBody = APIRequestBody(
                contentType: contentType,
                schema: content[contentType]?["schema"] ?? .object([:]),
                isRequired: body["required"]?.boolValue ?? false,
                description: body["description"]?.stringValue
            )
        }

        return APIOperation(
            id: "",
            operationId: op["operationId"]?.stringValue,
            method: method.uppercased(),
            path: path,
            summary: op["summary"]?.stringValue,
            description: op["description"]?.stringValue,
            tags: op["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            parameters: parameters,
            requestBody: requestBody,
            security: Self.parseSecurity(op["security"]),
            isDeprecated: op["deprecated"]?.boolValue ?? false
        )
    }

    private func preferredContentType(_ types: [JSONValue]?) -> String {
        let all = types?.compactMap(\.stringValue) ?? []
        let preferences: [(String) -> Bool] = [
            { $0 == "application/json" },
            { $0.hasSuffix("+json") || $0.hasSuffix("/json") },
            { $0 == "application/x-www-form-urlencoded" },
            { $0 == "multipart/form-data" },
            { $0.hasPrefix("text/") },
        ]
        for matches in preferences {
            if let match = all.first(where: matches) { return match }
        }
        return all.first ?? "application/json"
    }

    /// Swagger 2.0 non-body parameters carry their schema inline.
    private func swagger2ParameterSchema(_ p: JSONValue) -> JSONValue {
        var schema: [String: JSONValue] = [:]
        for key in ["type", "format", "items", "enum", "default", "minimum", "maximum", "minItems", "maxItems", "pattern"] {
            if let v = p[key] { schema[key] = v }
        }
        return .object(schema)
    }

    static func toolName(for op: APIOperation) -> String {
        let base = op.operationId ?? ([op.method.lowercased()] + op.path.split(separator: "/").map {
            $0.hasPrefix("{") ? "by_" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "{}")) : String($0)
        }).joined(separator: "_")
        var name = base.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "_" }.joined()
        while name.contains("__") { name = name.replacingOccurrences(of: "__", with: "_") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if name.isEmpty { name = op.method.lowercased() }
        if name.first!.isNumber { name = "op_" + name }
        return String(name.prefix(60))
    }

    static func uniqueID(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var n = 2
        while used.contains(candidate) {
            candidate = "\(base)_\(n)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }

    // MARK: Path parameter provenance

    /// The GET operation listing the collection a path parameter points into,
    /// e.g. `GET /stores` for the `{id}` in `/stores/{id}/products`.
    public func sourceOperation(for parameter: APIParameter, in operation: APIOperation) -> APIOperation? {
        guard parameter.location == .path else { return nil }
        let segments = operation.path.split(separator: "/").map(String.init)
        guard let index = segments.firstIndex(of: "{\(parameter.name)}"), index > 0 else { return nil }
        let parent = "/" + segments[..<index].joined(separator: "/")
        return operations.first { $0.method == "GET" && $0.path == parent && $0.id != operation.id }
    }

    /// Many specs leave path parameters like `{id}` undocumented, and small models then grab the first
    /// ID they see (often a nested one). Explain what the identifier refers to and where it comes from.
    private mutating func describeUndocumentedPathParameters() {
        let snapshot = self
        for o in operations.indices {
            for p in operations[o].parameters.indices {
                let parameter = operations[o].parameters[p]
                guard parameter.location == .path, parameter.description?.isEmpty ?? true else { continue }
                let segments = operations[o].path.split(separator: "/").map(String.init)
                guard let index = segments.firstIndex(of: "{\(parameter.name)}"), index > 0,
                      !segments[index - 1].hasPrefix("{") else { continue }
                var description = "Identifier of one item of `\(segments[index - 1])`"
                if let source = snapshot.sourceOperation(for: parameter, in: operations[o]) {
                    description += ". Use the top-level identifier (usually `id`) of an item returned by \(source.id) (GET \(source.path)), never the ID of a nested object"
                }
                operations[o].parameters[p].description = description
            }
        }
    }

    // MARK: Helpers for consumers

    public func operation(id: String) -> APIOperation? {
        operations.first { $0.id == id }
    }

    public func securityRequirements(for operation: APIOperation) -> [SecurityRequirement] {
        operation.security ?? globalSecurity
    }
}
