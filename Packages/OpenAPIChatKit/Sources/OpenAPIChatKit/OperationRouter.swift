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
        let ranked = lexicalRank(question + " " + (context ?? "")).filter { !previous.contains($0) }
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
