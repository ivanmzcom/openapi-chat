import Foundation
import FoundationModels
import NaturalLanguage
import Observation
import OSLog

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case user
        case assistant
        case toolCall(status: ToolStatus)
        case error
    }

    public enum ToolStatus: Sendable, Equatable {
        case running
        case succeeded(Int)
        case failed(String)
        case declined
    }

    public let id: UUID
    public var role: Role
    public var text: String
    /// For tool calls: the request URL.
    public var detail: String?
    /// For tool calls: the response data, ready to show as a table or card.
    public var presentation: ResultPresentation?
    /// For tool calls: how to fetch the next page of a list, if there is one.
    public var pagination: Pagination?
    /// For tool calls: the operation that was called and its arguments.
    public var operationID: String?
    public var arguments: JSONValue?
    /// For tool calls: the (condensed) response the model saw. Kept so later turns can reuse IDs and data.
    public var output: String?

    public init(id: UUID = UUID(), role: Role, text: String, detail: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
    }
}

public struct ChatConfiguration: Sendable {
    public var baseURL: String
    public var credentials: [String: Credential]
    /// `nil` enables every operation.
    public var enabledOperationIDs: Set<String>?
    public var model: ModelChoice
    public var requiresConfirmation: Bool

    public init(
        baseURL: String,
        credentials: [String: Credential] = [:],
        enabledOperationIDs: Set<String>? = nil,
        model: ModelChoice = .onDevice,
        requiresConfirmation: Bool = true
    ) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.enabledOperationIDs = enabledOperationIDs
        self.model = model
        self.requiresConfirmation = requiresConfirmation
    }
}

/// Drives a conversation about one API. Each turn picks the relevant operations, exposes them
/// as tools to a fresh `LanguageModelSession`, and streams the answer.
@MainActor
@Observable
public final class ChatEngine {
    public let spec: APISpec
    public var configuration: ChatConfiguration {
        didSet { tokens = OAuthTokenCache() }
    }

    public private(set) var messages: [ChatMessage] = []
    public private(set) var isResponding = false
    public private(set) var activeOperationIDs: [String] = []
    public private(set) var pendingCall: PendingAPICall?

    private var pendingContinuation: CheckedContinuation<Bool, Never>?
    private var tokens = OAuthTokenCache()
    private var currentTask: Task<Void, Never>?

    public init(spec: APISpec, configuration: ChatConfiguration) {
        self.spec = spec
        self.configuration = configuration
    }

    public var enabledOperations: [APIOperation] {
        guard let enabled = configuration.enabledOperationIDs else { return spec.operations.filter { !$0.isDeprecated } }
        return spec.operations.filter { enabled.contains($0.id) }
    }

    // MARK: Public API

    public func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        currentTask = Task { await respond(to: question) }
    }

    /// Sends a message and waits for the full answer (used by the CLI and tests).
    public func sendAndWait(_ text: String) async {
        send(text)
        await currentTask?.value
    }

    public func stop() {
        currentTask?.cancel()
        resolvePendingCall(approved: false)
    }

    public func reset() {
        stop()
        messages.removeAll()
        activeOperationIDs = []
    }

    /// Loads the next page of a table shown under a tool call, straight from the API (no model involved).
    public func loadMore(_ messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              let pagination = messages[index].pagination,
              let operation = messages[index].operationID.flatMap(spec.operation(id:)),
              case .table(var table) = messages[index].presentation else { return }
        messages[index].pagination = nil
        do {
            let page = try await makeExecutor()
                .fetchPage(operation, arguments: pagination.nextArguments, loadedBefore: pagination.loaded)
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
            if let more = page.table {
                table.append(more)
                messages[index].presentation = .table(table)
            }
            messages[index].pagination = page.pagination
        } catch {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
            messages[index].pagination = pagination
            messages.append(ChatMessage(role: .error, text: "No se pudo cargar la página siguiente: \(error.localizedDescription)"))
        }
    }

    public func resolvePendingCall(approved: Bool) {
        pendingContinuation?.resume(returning: approved)
        pendingContinuation = nil
        pendingCall = nil
    }

    // MARK: Turn

    private func respond(to question: String) async {
        isResponding = true
        defer {
            isResponding = false
            #if DEBUG
            let reply = messages.last.map { "\($0.role == .error ? "error" : "answer"): \($0.text)" } ?? ""
            Self.trace.debug("turn \(self.spec.title, privacy: .public) | \(question, privacy: .public) | \(reply, privacy: .public)")
            #endif
        }

        let history = recentHistory()
        messages.append(ChatMessage(role: .user, text: question))

        if let reason = configuration.model.unavailableReason {
            messages.append(ChatMessage(role: .error, text: reason))
            return
        }

        var budget = ContextBudget(contextSize: await configuration.model.contextSize())
        for attempt in 0..<2 {
            let toolsUsedBefore = toolCallCount
            do {
                try await runTurn(question: question, history: history, budget: budget)
                return
            } catch is CancellationError {
                return
            } catch where Self.isContextOverflow(error) && toolCallCount > toolsUsedBefore {
                // The API was already called: answer from those results instead of calling it again,
                // replacing any half-written answer from the failed attempt.
                if let turnStart = messages.lastIndex(where: { $0.role == .user }) {
                    let partial = Set(messages[turnStart...].filter { $0.role == .assistant }.map(\.id))
                    messages.removeAll { partial.contains($0.id) }
                }
                do {
                    try await answerFromResults(question: question, since: toolsUsedBefore)
                } catch {
                    messages.append(ChatMessage(role: .error, text: describe(error)))
                }
                return
            } catch where Self.isContextOverflow(error) && attempt == 0 {
                // Nothing was executed yet, so it is safe to retry with less context.
                budget = budget.reduced
            } catch {
                messages.append(ChatMessage(role: .error, text: describe(error)))
                return
            }
        }
    }

    /// Context overflows arrive as `LanguageModelError.contextSizeExceeded` or, on some paths, as the
    /// deprecated `GenerationError.exceededContextWindowSize`, matched by name to avoid deprecation warnings.
    nonisolated static func isContextOverflow(_ error: Error) -> Bool {
        if case LanguageModelError.contextSizeExceeded = error { return true }
        return String(describing: error).contains("exceededContextWindowSize")
    }

    /// Writes the reply from the API results of this turn in a fresh session without tools.
    private func answerFromResults(question: String, since toolIndex: Int) async throws {
        let calls = messages.filter { if case .toolCall = $0.role { true } else { false } }.dropFirst(toolIndex)
        let share = 2500 / max(calls.count, 1)
        let results = calls.compactMap { call in
            call.output.map { "Result of \(call.detail ?? call.text):\n\(String($0.prefix(share)))" }
        }.joined(separator: "\n\n")
        let session = configuration.model.makeSession(instructions: "You answer questions using API results. Never invent data.")
        let language = Self.languageName(of: question)
        let prompt = "\(results)\n\nUser question: \(question)"
        var answerID: UUID?
        for try await snapshot in session.streamResponse(to: prompt, schema: Self.replySchema(language: language)) {
            guard case .structure(let properties, _) = snapshot.content.kind,
                  case .string(let text)? = properties["reply"]?.kind, !text.isEmpty else { continue }
            upsertAnswer(text, id: &answerID)
        }
    }

    #if DEBUG
    nonisolated static func summary(_ presentation: ResultPresentation) -> String {
        switch presentation {
        case .table(let table): "table \(table.rows.count) rows \(table.columns)"
        case .record(let fields): "record \(fields.map(\.key))"
        case .detail(let fields, let tables): "detail \(fields.count) fields, lists \(tables.map { "\($0.title ?? "-")(\($0.rows.count))" })"
        }
    }
    #endif

    private func upsertAnswer(_ text: String, id answerID: inout UUID?) {
        if let answerID, let index = messages.firstIndex(where: { $0.id == answerID }) {
            messages[index].text = text
        } else {
            let message = ChatMessage(role: .assistant, text: text)
            answerID = message.id
            messages.append(message)
        }
    }

    private var toolCallCount: Int {
        messages.filter { if case .toolCall = $0.role { true } else { false } }.count
    }

    private func runTurn(question: String, history: [ChatMessage], budget: ContextBudget) async throws {
        let historyText = Self.format(Self.lastTurns(history, count: budget.maxHistoryTurns), limit: budget.historyCharactersPerMessage)
        let router = OperationRouter(operations: enabledOperations)
        var selected = await router.select(for: question, context: historyText, previous: lastTurnOperations(),
                                           model: configuration.model, budget: budget)
        // Also offer the list operations that provide path IDs, so the model can look an ID up
        // instead of guessing it.
        let enabled = enabledOperations
        for operation in selected {
            for parameter in operation.parameters {
                if let source = spec.sourceOperation(for: parameter, in: operation),
                   enabled.contains(source), !selected.contains(source), selected.count < budget.maxTools + 2 {
                    selected.append(source)
                }
            }
        }
        activeOperationIDs = selected.map(\.id)
        try Task.checkCancellation()

        let executor = makeExecutor(responseCharacters: budget.responseCharacters)
        var tools: [any Tool] = selected.compactMap { try? OpenAPITool(operation: $0, spec: spec, executor: executor, maxDepth: budget.contextSize <= 4096 ? 2 : 3) }
        let instructions = instructions(history: historyText)
        tools = await fit(tools, instructions: instructions, budget: budget)
        let session = configuration.model.makeSession(tools: tools, instructions: instructions)

        var answerID: UUID?
        // The question decides the language; very short ones ("ok", "más") fall back to the previous message.
        let language = question.split(separator: " ").count >= 3
            ? Self.languageName(of: question)
            : Self.languageName(of: question + " " + (history.last { $0.role == .user }?.text ?? ""))
        for try await snapshot in session.streamResponse(to: question, schema: Self.replySchema(language: language)) {
            // Read the partially generated `reply` so the answer streams in instead of appearing all at once.
            guard case .structure(let properties, _) = snapshot.content.kind,
                  case .string(let text)? = properties["reply"]?.kind, !text.isEmpty else { continue }
            upsertAnswer(text, id: &answerID)
        }
        if answerID == nil {
            messages.append(ChatMessage(role: .assistant, text: "…"))
        }
    }

    /// Drops the least relevant tools (they come last) until instructions + tool schemas leave room
    /// for the tool results and the answer: about half the context. Only the on-device model can
    /// count tokens ahead of time; Private Cloud Compute has room to spare anyway.
    private func fit(_ tools: [any Tool], instructions: String, budget: ContextBudget) async -> [any Tool] {
        guard configuration.model.effective == .onDevice else { return tools }
        let model = SystemLanguageModel.default
        let limit = budget.contextSize / 2
        var kept = tools
        while kept.count > 1 {
            guard let used = try? await model.tokenCount(for: kept), let base = try? await model.tokenCount(for: Instructions(instructions)),
                  used + base > limit else { break }
            kept.removeLast()
        }
        return kept
    }

    /// The final answer is generated as a single `reply` string (guided generation). Tables already show the
    /// data, and with free text the small model tends to re-list every item, which is slow and redundant.
    nonisolated static func replySchema(language: String) -> GenerationSchema {
        let root = DynamicGenerationSchema(name: "Reply", properties: [
            .init(name: "reply",
                  description: "Answer to the user's latest message, in \(language), 1-3 short sentences in one paragraph. After fetching data, give the key takeaway (how many results, notable items…), not the items themselves. If a request FAILED, say so and give the HTTP error. If the user asks what you can do, describe the main areas of the API. No lists or line breaks, and don't mention tables or the app.",
                  schema: DynamicGenerationSchema(type: String.self)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }

    /// English name of the language the user wrote in ("Spanish"), used to pin the reply language.
    nonisolated static func languageName(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let code = recognizer.dominantLanguage?.rawValue,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: code) else { return "the user's language" }
        return name
    }

    private func instructions(history: String) -> String {
        var text = """
            You are an assistant for the "\(spec.title)" API and know nothing about its data. Whenever the user \
            asks about data or wants an action, call the most suitable tool first and answer only from its \
            result; never invent data, IDs or results. Use IDs and URLs exactly as they appear in API results. \
            If a tool needs a value (ID, URL…) you don't have, first call the tool that returns it, in the same \
            turn. Leave optional arguments unset unless the request needs them. Only ask the user when a required \
            argument is truly unknown. Don't ask for confirmation \
            before calling read-only tools. The user already sees every API result as a table or card.

            Today is \(Date.now.formatted(date: .complete, time: .omitted)).
            """
        if let summary = spec.summary?.replacingOccurrences(of: "\n", with: " "), !summary.isEmpty {
            text += "\nAbout the API: \(summary.prefix(240))"
        }
        if let areas = Self.areas(of: enabledOperations) {
            text += "\nMain areas of the API: \(areas)"
        }
        if !history.isEmpty {
            text += "\nRecent conversation:\n\(history)"
        }
        return text
    }

    /// A one-line overview of what the API covers, grouped by tag (or first path segment), so the model can
    /// answer "what can you do?" without fetching anything.
    nonisolated static func areas(of operations: [APIOperation], limit: Int = 10) -> String? {
        let grouped = Dictionary(grouping: operations, by: OperationRouter.area)
        guard grouped.count > 1 || operations.count > 1 else { return nil }
        return grouped.sorted { $0.value.count > $1.value.count }.prefix(limit).map { name, operations in
            let examples = operations.compactMap(\.summary).prefix(2).map { $0.prefix(50) }.joined(separator: "; ")
            return examples.isEmpty ? name : "\(name) (\(examples))"
        }.joined(separator: " · ")
    }

    /// Operations actually called during the most recent completed turn.
    private func lastTurnOperations() -> [APIOperation] {
        guard let lastUser = messages.lastIndex(where: { $0.role == .user }),
              let previousUser = messages[..<lastUser].lastIndex(where: { $0.role == .user }) else { return [] }
        let ids = messages[previousUser..<lastUser].compactMap { message -> String? in
            guard case .toolCall = message.role else { return nil }
            return message.operationID
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.compactMap { spec.operation(id: $0) }
    }

    private func recentHistory() -> [ChatMessage] {
        messages.filter { $0.role != .error }
    }

    /// The messages belonging to the last `count` user turns.
    static func lastTurns(_ messages: [ChatMessage], count: Int) -> ArraySlice<ChatMessage> {
        guard count > 0 else { return [] }
        let userIndices = messages.indices.filter { messages[$0].role == .user }
        guard userIndices.count > count else { return messages[...] }
        return messages[userIndices[userIndices.count - count]...]
    }

    static func format(_ messages: some Collection<ChatMessage>, limit: Int) -> String {
        messages.compactMap { message in
            func clip(_ text: String, _ max: Int) -> String {
                text.count > max ? String(text.prefix(max)) + "…" : text
            }
            switch message.role {
            case .user: return "User: \(clip(message.text, limit))"
            case .assistant: return "Assistant: \(clip(message.text, limit))"
            case .toolCall:
                // API data (IDs, names…) from earlier turns, so follow-up questions can use it.
                guard let output = message.output else { return nil }
                return "API result of \(message.detail ?? message.text): \(clip(output, limit * 2))"
            case .error: return nil
            }
        }.joined(separator: "\n")
    }

    // MARK: Tool plumbing

    private func makeExecutor(responseCharacters: Int = ResponseCondenser().maxCharacters) -> APIExecutor {
        APIExecutor(
            spec: spec,
            baseURL: configuration.baseURL,
            credentials: configuration.credentials,
            tokens: tokens,
            condenser: ResponseCondenser(maxCharacters: responseCharacters),
            requiresConfirmation: configuration.requiresConfirmation,
            confirm: { [weak self] call in await self?.confirm(call) ?? false },
            onEvent: { [weak self] event in await self?.handle(event) },
            repairArguments: { [weak self] operation, arguments in
                await self?.repair(arguments, for: operation) ?? arguments
            }
        )
    }

    private func repair(_ arguments: JSONValue, for operation: APIOperation) -> JSONValue {
        let previous = messages.compactMap { message -> PathRepair.PreviousCall? in
            guard case .toolCall(.succeeded(let code)) = message.role, (200..<300).contains(code),
                  let operation = message.operationID.flatMap(spec.operation(id:)),
                  let arguments = message.arguments,
                  let presentation = message.presentation else { return nil }
            return PathRepair.PreviousCall(operation: operation, arguments: arguments, rows: presentation.allRows)
        }
        return PathRepair.repair(arguments, for: operation, previous: previous)
    }

    private func confirm(_ call: PendingAPICall) async -> Bool {
        resolvePendingCall(approved: false)
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            pendingCall = call
        }
    }

    #if DEBUG
    /// Debug builds trace each turn to the unified log (`log stream --predicate 'subsystem == "OpenAPIChat"'`),
    /// so the app can be checked without looking at the screen.
    private static let trace = Logger(subsystem: "OpenAPIChat", category: "chat")
    #endif

    private func handle(_ event: ToolCallEvent) {
        #if DEBUG
        switch event.phase {
        case .started: Self.trace.debug("call \(event.operation.method, privacy: .public) \(event.url ?? "", privacy: .public)")
        case .finished(let status, _, let presentation, _):
            Self.trace.debug("done \(status) \(event.operation.id, privacy: .public) \(String(describing: presentation.map(Self.summary)), privacy: .public)")
        case .failed(let reason): Self.trace.debug("failed \(event.operation.id, privacy: .public): \(reason, privacy: .public)")
        case .declined: Self.trace.debug("declined \(event.operation.id, privacy: .public)")
        }
        #endif
        let status: ChatMessage.ToolStatus = switch event.phase {
        case .started: .running
        case .finished(let code, _, _, _): .succeeded(code)
        case .failed(let reason): .failed(reason)
        case .declined: .declined
        }
        let title = event.operation.displayTitle
        if let index = messages.firstIndex(where: { $0.id == event.callID }) {
            messages[index].role = .toolCall(status: status)
            switch event.phase {
            case .finished(_, let output, let presentation, let pagination):
                messages[index].output = output
                messages[index].presentation = presentation
                messages[index].pagination = pagination
            case .failed(let reason): messages[index].output = "Error: \(reason)"
            default: break
            }
        } else {
            var message = ChatMessage(id: event.callID, role: .toolCall(status: status), text: title,
                                      detail: "\(event.operation.method) \(event.url ?? event.operation.path)")
            message.operationID = event.operation.id
            message.arguments = event.arguments
            messages.append(message)
        }
    }

    func describe(_ error: Error) -> String {
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .quotaLimitReached(let info):
                let reset = info.resetDate.map { " Se renueva el \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
                return "Has agotado la cuota diaria de Private Cloud Compute.\(reset) Mientras tanto, usa el modelo del dispositivo."
            case .networkFailure:
                return "No hay conexión con Private Cloud Compute. Comprueba tu conexión a internet."
            case .serviceUnavailable:
                return "Private Cloud Compute no está disponible ahora mismo. Inténtalo más tarde."
            @unknown default:
                return "Error de Private Cloud Compute: \(error.localizedDescription)"
            }
        }
        guard let error = error as? LanguageModelError else {
            return "Error: \(error.localizedDescription)"
        }
        switch error {
        case .contextSizeExceeded:
            return "La conversación no cabe en la memoria del modelo. Empieza una conversación nueva o desactiva endpoints que no uses."
        case .guardrailViolation:
            return "Apple Intelligence bloqueó esta respuesta por sus filtros de seguridad."
        case .unsupportedLanguageOrLocale:
            return "Apple Intelligence no admite este idioma."
        case .rateLimited:
            return "Demasiadas peticiones al modelo. Espera un momento."
        case .refusal:
            return "El modelo se negó a responder esta petición."
        case .timeout:
            return "El modelo tardó demasiado en responder."
        default:
            return "Error del modelo: \(error.localizedDescription)"
        }
    }
}
