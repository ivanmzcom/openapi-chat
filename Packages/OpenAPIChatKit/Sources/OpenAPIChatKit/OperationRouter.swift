import Foundation
import FoundationModels

/// Chooses the few operations relevant to a question, since only a handful of tool
/// definitions fit in the on-device model's context at once.
public struct OperationRouter: Sendable {
    public var operations: [APIOperation]

    public init(operations: [APIOperation]) {
        self.operations = operations
    }

    // MARK: Lexical ranking (cheap prefilter, no model involved)

    public func lexicalRank(_ query: String) -> [APIOperation] {
        let queryTokens = Set(Self.tokens(query))
        guard !queryTokens.isEmpty else { return operations }
        let documents = operations.map { Self.tokens(Self.document(for: $0)) }
        var documentFrequency: [String: Int] = [:]
        for doc in documents { for token in Set(doc) { documentFrequency[token, default: 0] += 1 } }
        let n = Double(operations.count)

        let scored = zip(operations, documents).enumerated().map { index, pair in
            let (operation, doc) = pair
            let tokens = Set(doc)
            var score = 0.0
            for token in queryTokens where tokens.contains(token) {
                score += log(1 + n / Double(documentFrequency[token] ?? 1))
            }
            // Read operations are the most common need in chat; prefer them on ties.
            if !operation.isMutating { score += 0.01 }
            return (operation, score, index)
        }
        return scored.sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }.map(\.0)
    }

    static func document(for operation: APIOperation) -> String {
        ([operation.id, operation.operationId ?? "", operation.method, operation.path, operation.summary ?? "", operation.description ?? ""]
            + operation.tags).joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        // Split camelCase and snake_case, lowercase, drop short words and a trivial plural.
        var spaced = ""
        var previous: Character = " "
        for c in text {
            if c.isUppercase && previous.isLowercase { spaced.append(" ") }
            spaced.append(c)
            previous = c
        }
        return spaced.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
            .map { $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
    }

    // MARK: Areas

    /// The area an operation belongs to: its first tag, or its first meaningful path segment.
    public static func area(of operation: APIOperation) -> String {
        if let tag = operation.tags.first { return tag }
        let segments = operation.path.split(separator: "/").filter {
            !$0.hasPrefix("{") && !["api", "v1", "v2", "v3", "v4"].contains($0.lowercased())
        }
        return segments.first.map(String.init) ?? "general"
    }

    /// Asks the model which areas of the API the request is about and returns their operations.
    func operationsInRelevantAreas(for question: String, context: String?, model: ModelChoice) async -> [APIOperation]? {
        let groups = Dictionary(grouping: operations, by: Self.area)
        guard groups.count >= 3 else { return nil }
        let areas = groups.sorted { $0.value.count > $1.value.count }.prefix(80)
        let catalog = areas.map { name, operations in
            let examples = operations.compactMap(\.summary).prefix(3).map { String($0.prefix(40)) }.joined(separator: "; ")
            return "- \(name): \(examples)"
        }.joined(separator: "\n")
        let choice = DynamicGenerationSchema(name: "Area", anyOf: areas.map(\.key))
        let root = DynamicGenerationSchema(name: "Areas", properties: [
            .init(name: "areas", description: "The 1-3 areas most related to the request",
                  schema: DynamicGenerationSchema(arrayOf: choice, minimumElements: 1, maximumElements: 3)),
        ])
        do {
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = model.makeSession(instructions: "You classify user requests into areas of an API. The request may be in any language.")
            var prompt = "API areas (with example operations):\n\(catalog)\n\n"
            if let context, !context.isEmpty { prompt += "Recent conversation:\n\(context.suffix(1200))\n\n" }
            prompt += "User request: \(question)"
            let response = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(temperature: 0))
            let chosen = try response.content.value([String].self, forProperty: "areas")
            let result = chosen.flatMap { groups[$0] ?? [] }
            return result.isEmpty ? nil : result
        } catch {
            return nil
        }
    }

    // MARK: Model-based routing

    /// Asks the model which operations are needed. Works across languages (e.g. a Spanish
    /// question over an English spec), which plain keyword matching does not.
    /// - Parameter previous: operations called in the previous turn. Follow-ups ("show me all of
    ///   them", "the second one") usually need them again, so they are always kept available.
    public func select(
        for question: String,
        context: String?,
        previous: [APIOperation] = [],
        model: ModelChoice,
        budget: ContextBudget
    ) async -> [APIOperation] {
        guard operations.count > budget.maxTools else { return operations }

        let previous = previous.filter { operations.contains($0) }
        let query = question + " " + (context ?? "")
        var ranked = lexicalRank(query)
        // Big APIs don't fit in one catalog, and keywords fail across languages ("estrellas" vs "stars"):
        // first let the model pick the relevant areas, then rank inside them.
        if operations.count > budget.routerCatalogSize,
           let inAreas = await operationsInRelevantAreas(for: question, context: context, model: model) {
            ranked = OperationRouter(operations: inAreas).lexicalRank(query) + ranked
        }
        var seen = Set(previous.map(\.id))
        ranked = ranked.filter { seen.insert($0.id).inserted }
        let candidates = Array((previous + ranked).prefix(budget.routerCatalogSize))
        let catalog = candidates.map { op in
            "- \(op.id): \(op.method) \(op.path)" + (op.summary.map { " — \($0.prefix(80))" } ?? "")
        }.joined(separator: "\n")

        let choice = DynamicGenerationSchema(name: "OperationID", anyOf: candidates.map(\.id))
        let root = DynamicGenerationSchema(name: "Selection", properties: [
            .init(name: "operations", description: "Operations needed, most relevant first. Empty if none.",
                  schema: DynamicGenerationSchema(arrayOf: choice, minimumElements: 0, maximumElements: budget.maxTools)),
        ])

        do {
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = model.makeSession(instructions: """
                You route user requests to API operations. Pick the operations whose results are needed \
                to answer the request or carry out the action. Prefer fewer operations.
                """)
            var prompt = "Available operations:\n\(catalog)\n\n"
            if let context, !context.isEmpty { prompt += "Recent conversation:\n\(context)\n\n" }
            if !previous.isEmpty {
                prompt += "Operations used in the previous turn (likely needed again for follow-up requests): \(previous.map(\.id).joined(separator: ", "))\n\n"
            }
            prompt += "User request: \(question)"
            let response = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(temperature: 0))
            let ids = try response.content.value([String].self, forProperty: "operations")
            // The model's picks go first; remaining slots are filled with the best lexical matches,
            // so a single wrong pick doesn't leave the answering model without the right tool.
            var selected: [APIOperation] = []
            for id in ids {
                if let op = candidates.first(where: { $0.id == id }), !selected.contains(op) { selected.append(op) }
            }
            for op in previous where !selected.contains(op) {
                selected.append(op)
            }
            for op in candidates where selected.count < budget.maxTools && !selected.contains(op) {
                selected.append(op)
            }
            return Array(selected.prefix(budget.maxTools + previous.count))
        } catch {
            return Array(candidates.prefix(budget.maxTools))
        }
    }
}
