import Foundation

/// Detects paginated responses and builds the arguments for the next page, so both the model
/// ("call again with page=2") and the UI ("Cargar más") can continue a list.
public struct Pagination: Sendable, Equatable {
    /// Tool arguments that fetch the next page (the original ones plus the updated page/offset/cursor).
    public var nextArguments: JSONValue
    /// Total number of items, when the API reports it.
    public var total: Int?
    /// Items received so far, including this page.
    public var loaded: Int

    private static let pageNames = ["page", "pageNumber", "page_number", "p"]
    private static let offsetNames = ["offset", "skip", "start"]
    private static let cursorNames = ["cursor", "after", "before", "next", "page_token", "pageToken", "continuation"]
    private static let totalKeys = ["total", "totalCount", "total_count", "totalItems", "total_items", "totalResults",
                                    "total_results", "count", "totalElements"]
    private static let nextCursorKeys = ["next", "nextCursor", "next_cursor", "nextPageToken", "next_page_token", "cursor"]

    /// - Parameters:
    ///   - arguments: the tool arguments used for this request.
    ///   - pageItems: number of list items in this response.
    ///   - loadedBefore: items already shown from previous pages.
    public static func next(operation: APIOperation, arguments: JSONValue, response: JSONValue,
                            pageItems: Int, loadedBefore: Int = 0) -> Pagination? {
        guard pageItems > 0, var args = arguments.objectValue else { return nil }
        let query = operation.parameters.filter { $0.location == .query }
        let loaded = loadedBefore + pageItems
        let total = findTotal(in: response)
        if let total, loaded >= total { return nil }

        if let cursorParam = query.first(where: { cursorNames.contains($0.name) }),
           let cursor = findNextCursor(in: response) {
            args[cursorParam.name] = .string(cursor)
            return Pagination(nextArguments: .object(args), total: total, loaded: loaded)
        }
        // Without a total, a page/offset API is assumed to have more only while pages come back reasonably full.
        if total == nil && pageItems < 10 { return nil }
        if let pageParam = query.first(where: { pageNames.contains($0.name) }) {
            let current = args[pageParam.name]?.numberValue.map(Int.init) ?? pageParam.schema["default"]?.numberValue.map(Int.init) ?? 1
            args[pageParam.name] = .number(Double(current + 1))
            return Pagination(nextArguments: .object(args), total: total, loaded: loaded)
        }
        if let offsetParam = query.first(where: { offsetNames.contains($0.name) }) {
            let current = args[offsetParam.name]?.numberValue.map(Int.init) ?? 0
            args[offsetParam.name] = .number(Double(current + pageItems))
            return Pagination(nextArguments: .object(args), total: total, loaded: loaded)
        }
        return nil
    }

    /// Looks for a total count at the root or inside a `meta`/`pagination`-style object.
    static func findTotal(in json: JSONValue, depth: Int = 0) -> Int? {
        guard let dict = json.objectValue else { return nil }
        for key in totalKeys {
            if let n = dict[key]?.numberValue { return Int(n) }
        }
        guard depth < 2 else { return nil }
        for (_, value) in dict where value.objectValue != nil {
            if let total = findTotal(in: value, depth: depth + 1) { return total }
        }
        return nil
    }

    static func findNextCursor(in json: JSONValue, depth: Int = 0) -> String? {
        guard let dict = json.objectValue else { return nil }
        for key in nextCursorKeys {
            if let s = dict[key]?.stringValue, !s.isEmpty, !s.hasPrefix("http") { return s }
        }
        guard depth < 2 else { return nil }
        for (_, value) in dict where value.objectValue != nil {
            if let cursor = findNextCursor(in: value, depth: depth + 1) { return cursor }
        }
        return nil
    }

    /// Hint appended to the tool output so the model knows how to continue.
    func hint(toolName: String) -> String {
        let shown = total.map { "showing \(loaded) of \($0)" } ?? "showing \(loaded)"
        let paging = Set(Self.pageNames + Self.offsetNames + Self.cursorNames)
        let changed = (nextArguments.objectValue ?? [:]).filter { paging.contains($0.key) }
        let args = changed.map { "\($0.key)=\($0.value.scalarText)" }.sorted().joined(separator: ", ")
        return "MORE RESULTS EXIST (\(shown)). If the user wants more or all of them, call \(toolName) again with the same arguments and \(args)."
    }
}
