import Foundation

public struct RequestInput: Sendable {
    public var parameters: [(parameter: APIParameter, value: JSONValue)] = []
    public var body: JSONValue?

    public init(parameters: [(parameter: APIParameter, value: JSONValue)] = [], body: JSONValue? = nil) {
        self.parameters = parameters
        self.body = body
    }

    public func value(for name: String, in location: ParameterLocation) -> JSONValue? {
        parameters.first { $0.parameter.name == name && $0.parameter.location == location }?.value
    }
}

public enum RequestBuildError: LocalizedError, Equatable {
    case missingRequired([String])
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .missingRequired(let names): "Missing required arguments: \(names.joined(separator: ", ")). Ask the user for them."
        case .invalidURL(let url): "Invalid URL: \(url)"
        }
    }
}

/// Builds `URLRequest`s from an operation plus model-provided arguments. Pure and synchronous.
public struct RequestBuilder: Sendable {
    public var baseURL: String

    public init(baseURL: String) {
        self.baseURL = baseURL
    }

    public func makeRequest(for operation: APIOperation, input: RequestInput, auth: ResolvedAuth = ResolvedAuth()) throws -> URLRequest {
        let missing = operation.parameters
            .filter { $0.isRequired && input.value(for: $0.name, in: $0.location) == nil }
            .map(\.name)
            + (operation.requestBody?.isRequired == true && input.body == nil ? ["body"] : [])
        guard missing.isEmpty else { throw RequestBuildError.missingRequired(missing) }

        var path = operation.path
        var queryItems: [(String, String)] = []
        var headers: [String: String] = [:]
        var cookies: [(String, String)] = []

        for (parameter, value) in input.parameters {
            switch parameter.location {
            case .path:
                let text = Self.flatText(value)
                path = path.replacingOccurrences(of: "{\(parameter.name)}", with: Self.encode(text))
            case .query:
                queryItems += Self.queryItems(name: parameter.name, value: value, style: parameter.style, explode: parameter.explode)
            case .header:
                headers[parameter.name] = Self.flatText(value)
            case .cookie:
                cookies.append((parameter.name, Self.flatText(value)))
            }
        }

        headers.merge(auth.headers) { _, new in new }
        queryItems += auth.queryItems
        cookies += auth.cookies

        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: base + (path.hasPrefix("/") ? path : "/" + path)),
              components.scheme != nil, components.host != nil else {
            throw RequestBuildError.invalidURL(base + path)
        }
        if !queryItems.isEmpty {
            let existing = components.percentEncodedQuery.map { [$0] } ?? []
            components.percentEncodedQuery = (existing + queryItems.map { "\(Self.encode($0))=\(Self.encode($1))" }).joined(separator: "&")
        }
        guard let url = components.url else { throw RequestBuildError.invalidURL(base + path) }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = operation.method
        request.setValue("application/json, */*;q=0.8", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !cookies.isEmpty {
            request.setValue(cookies.map { "\($0)=\($1)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }

        if let body = input.body, let spec = operation.requestBody {
            let (data, contentType) = Self.encodeBody(body, contentType: spec.contentType)
            request.httpBody = data
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: Encoding helpers

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    static func flatText(_ value: JSONValue) -> String {
        if case .array(let items) = value { return items.map(\.scalarText).joined(separator: ",") }
        return value.scalarText
    }

    static func queryItems(name: String, value: JSONValue, style: String?, explode: Bool?) -> [(String, String)] {
        switch value {
        case .array(let items):
            let separator: String? = switch style {
            case "pipeDelimited", "pipes": "|"
            case "spaceDelimited", "ssv": " "
            case "tsv": "\t"
            case "csv": ","
            case "multi": nil
            default: explode == false ? "," : nil
            }
            if let separator { return [(name, items.map(\.scalarText).joined(separator: separator))] }
            return items.map { (name, $0.scalarText) }
        case .object(let dict):
            let keys = dict.keys.sorted()
            if style == "deepObject" { return keys.map { ("\(name)[\($0)]", dict[$0]!.scalarText) } }
            if explode == false { return [(name, keys.flatMap { [$0, dict[$0]!.scalarText] }.joined(separator: ","))] }
            return keys.map { ($0, dict[$0]!.scalarText) }
        default:
            return [(name, value.scalarText)]
        }
    }

    static func encodeBody(_ body: JSONValue, contentType: String) -> (Data, String) {
        if contentType.contains("x-www-form-urlencoded") {
            let pairs = (body.objectValue ?? [:]).sorted { $0.key < $1.key }
                .map { "\(encode($0.key))=\(encode(flatText($0.value)))" }
            return (Data(pairs.joined(separator: "&").utf8), contentType)
        }
        if contentType.contains("multipart/form-data") {
            let boundary = "Boundary-\(UUID().uuidString)"
            var data = Data()
            for (key, value) in (body.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(flatText(value))\r\n".utf8))
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            return (data, "multipart/form-data; boundary=\(boundary)")
        }
        if contentType.hasPrefix("text/") {
            return (Data(body.scalarText.utf8), contentType)
        }
        return (body.jsonData(), contentType == "*/*" ? "application/json" : contentType)
    }
}
