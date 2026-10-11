import Foundation
import FoundationModels

/// A request waiting for the user's approval (used for operations that modify data).
public struct PendingAPICall: Sendable, Identifiable {
    public let id = UUID()
    public var operation: APIOperation
    public var url: String
    public var bodyPreview: String?
}

public struct ToolCallEvent: Sendable {
    public enum Phase: Sendable {
        case started
        /// `presentation` is how the UI can show the data without the model writing it out.
        case finished(status: Int, output: String, presentation: ResultPresentation?, pagination: Pagination?)
        case failed(String)
        case declined
    }

    public var callID: UUID
    public var operation: APIOperation
    public var url: String?
    public var phase: Phase
}

/// Executes API operations on behalf of the model and returns text the model can read.
public struct APIExecutor: Sendable {
    public var spec: APISpec
    public var builder: RequestBuilder
    public var auth: AuthResolver
    public var condenser: ResponseCondenser
    public var session: URLSession
    public var requiresConfirmation: Bool
    public var confirm: @Sendable (PendingAPICall) async -> Bool
    public var onEvent: @Sendable (ToolCallEvent) async -> Void

    public init(
        spec: APISpec,
        baseURL: String,
        credentials: [String: Credential],
        tokens: OAuthTokenCache = OAuthTokenCache(),
        condenser: ResponseCondenser = ResponseCondenser(),
        session: URLSession = .shared,
        requiresConfirmation: Bool = true,
        confirm: @escaping @Sendable (PendingAPICall) async -> Bool = { _ in true },
        onEvent: @escaping @Sendable (ToolCallEvent) async -> Void = { _ in }
    ) {
        self.spec = spec
        self.builder = RequestBuilder(baseURL: baseURL)
        self.auth = AuthResolver(schemes: spec.securitySchemes, credentials: credentials, tokens: tokens)
        self.condenser = condenser
        self.session = session
        self.requiresConfirmation = requiresConfirmation
        self.confirm = confirm
        self.onEvent = onEvent
    }

    /// - Parameter arguments: the raw tool arguments, used to build the next-page arguments.
    public func execute(_ operation: APIOperation, input: RequestInput, arguments: JSONValue = .object([:])) async -> String {
        let callID = UUID()
        let request: URLRequest
        let resolvedAuth: ResolvedAuth
        do {
            resolvedAuth = try await auth.resolve(spec.securityRequirements(for: operation))
            request = try builder.makeRequest(for: operation, input: input, auth: resolvedAuth)
        } catch {
            await onEvent(ToolCallEvent(callID: callID, operation: operation, url: nil, phase: .failed(error.localizedDescription)))
            return "Error: \(error.localizedDescription)"
        }

        let url = request.url?.absoluteString ?? ""
        if operation.isMutating && requiresConfirmation {
            let preview = request.httpBody.map { String(decoding: $0.prefix(600), as: UTF8.self) }
            guard await confirm(PendingAPICall(operation: operation, url: url, bodyPreview: preview)) else {
                await onEvent(ToolCallEvent(callID: callID, operation: operation, url: url, phase: .declined))
                return "The user declined this request, so it was not sent. Do not retry it; tell the user it was cancelled."
            }
        }

        await onEvent(ToolCallEvent(callID: callID, operation: operation, url: url, phase: .started))
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            var text = condenser.condense(status: status, contentType: http?.value(forHTTPHeaderField: "Content-Type"), data: data)
            if status >= 400 {
                // Small models tend to turn errors into "no results"; make the failure unmistakable.
                text = "REQUEST FAILED. Tell the user this request failed and why (do NOT say there were no results). Check that IDs and arguments are correct.\n" + text
            }
            if status == 401 || status == 403, !resolvedAuth.missingSchemes.isEmpty {
                text += "\nAuthentication is not configured (\(resolvedAuth.missingSchemes.joined(separator: ", "))). Tell the user to add credentials in the API settings."
            }
            let page = (200..<300).contains(status)
                ? Self.page(operation, arguments: arguments, data: data, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
                : nil
            if let presentation = page?.presentation {
                // The user already sees the data; give the model the same compact rows instead of the JSON.
                text = "HTTP \(status). The app already shows this data to the user as a table/card. Data:\n"
                    + presentation.modelText(maxCharacters: condenser.maxCharacters)
                if let total = page?.pagination?.total ?? Pagination.findTotal(in: JSONValue.parseIfJSON(data, contentType: http?.value(forHTTPHeaderField: "Content-Type")) ?? .null) {
                    text += "\nTotal items reported by the API: \(total)"
                }
            }
            if let pagination = page?.pagination {
                text += "\n" + pagination.hint(toolName: operation.id)
            }
            await onEvent(ToolCallEvent(callID: callID, operation: operation, url: url,
                                        phase: .finished(status: status, output: text, presentation: page?.presentation,
                                                         pagination: page?.pagination)))
            return text
        } catch {
            await onEvent(ToolCallEvent(callID: callID, operation: operation, url: url, phase: .failed(error.localizedDescription)))
            return "Error: the request failed (\(error.localizedDescription))."
        }
    }
}

extension APIExecutor {
    static func page(_ operation: APIOperation, arguments: JSONValue, data: Data, contentType: String?,
                     loadedBefore: Int = 0) -> (presentation: ResultPresentation?, pagination: Pagination?)? {
        guard let json = JSONValue.parseIfJSON(data, contentType: contentType) else { return nil }
        let presentation = ResultPresentation(json)
        var items = 0
        if case .table(let table) = presentation { items = table.rows.count }
        let pagination = Pagination.next(operation: operation, arguments: arguments, response: json,
                                         pageItems: items, loadedBefore: loadedBefore)
        return (presentation, pagination)
    }

    /// Fetches another page for the UI ("Cargar más"), without involving the model. Read-only operations only.
    public func fetchPage(_ operation: APIOperation, arguments: JSONValue, loadedBefore: Int) async throws
        -> (table: ResultTable?, pagination: Pagination?) {
        guard !operation.isMutating else { return (nil, nil) }
        let input = try ToolInterface(operation: operation, spec: spec).requestInput(from: arguments)
        let resolvedAuth = try await auth.resolve(spec.securityRequirements(for: operation))
        let request = try builder.makeRequest(for: operation, input: input, auth: resolvedAuth)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http?.statusCode ?? 0)"])
        }
        let page = Self.page(operation, arguments: arguments, data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                             loadedBefore: loadedBefore)
        guard case .table(let table) = page?.presentation else { return (nil, nil) }
        return (table, page?.pagination)
    }
}

/// One OpenAPI operation exposed to the model as a Foundation Models tool.
public struct OpenAPITool: Tool {
    public typealias Arguments = GeneratedContent
    public typealias Output = String

    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    let operation: APIOperation
    let interface: ToolInterface
    let executor: APIExecutor

    public init(operation: APIOperation, spec: APISpec, executor: APIExecutor, maxDepth: Int = 3) throws {
        self.operation = operation
        self.interface = try ToolInterface(operation: operation, spec: spec, maxDepth: maxDepth)
        self.executor = executor
        self.name = operation.id
        self.description = Self.describe(operation)
        self.parameters = interface.parameters
    }

    public func call(arguments: GeneratedContent) async throws -> String {
        let json = arguments.jsonValue
        return await executor.execute(operation, input: interface.requestInput(from: json), arguments: json)
    }

    static func describe(_ operation: APIOperation) -> String {
        var text = "\(operation.method) \(operation.path)"
        if let summary = operation.summary, !summary.isEmpty { text += ": \(summary)" }
        if let description = operation.description?.replacingOccurrences(of: "\n", with: " "),
           !description.isEmpty, description != operation.summary {
            text += ". " + (description.count > 180 ? String(description.prefix(180)) + "…" : description)
        }
        return text
    }
}
