import Foundation

/// Shrinks API responses so they fit in the model's context window while keeping the useful part.
public struct ResponseCondenser: Sendable {
    public var maxCharacters: Int

    public init(maxCharacters: Int = 2500) {
        self.maxCharacters = maxCharacters
    }

    public func condense(status: Int, contentType: String?, data: Data) -> String {
        let header = "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"
        guard !data.isEmpty else { return header + " (empty body)" }

        let type = contentType?.lowercased() ?? ""
        if type.contains("json") || type.isEmpty || type.hasPrefix("text/plain"),
           let json = try? JSONValue.parse(data), json.objectValue != nil || json.arrayValue != nil {
            return header + "\n" + condense(json)
        }
        if type.hasPrefix("text/") || type.contains("xml") || type.contains("yaml"),
           let text = String(data: data, encoding: .utf8) {
            return header + "\n" + truncate(text, to: maxCharacters)
        }
        return header + "\n<\(type.isEmpty ? "binary" : type) content, \(data.count) bytes>"
    }

    public func condense(_ json: JSONValue) -> String {
        // Passes go from "everything" to "less": first all list items with full detail, then all items with
        // only their short identifying fields ("slim"), then fewer items. For lists, seeing every item
        // usually matters more than seeing every field.
        let passes: [Pass] = [
            Pass(items: 50, string: 300, depth: 8, slim: false),
            Pass(items: 50, string: 100, depth: 5, slim: true),
            Pass(items: 30, string: 60, depth: 4, slim: true),
            Pass(items: 15, string: 60, depth: 3, slim: true),
            Pass(items: 8, string: 40, depth: 3, slim: true),
            Pass(items: 3, string: 40, depth: 2, slim: true),
        ]
        var text = ""
        for pass in passes {
            text = Self.compactJSON(prune(json, pass))
            if text.count <= maxCharacters { return text }
        }
        return truncate(text, to: maxCharacters)
    }

    struct Pass {
        var items: Int
        var string: Int
        var depth: Int
        /// Inside lists, keep only short scalar fields (ids, names, prices, statuses…).
        var slim: Bool
    }

    func prune(_ value: JSONValue, _ pass: Pass, inList: Bool = false) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(truncate(s, to: pass.string))
        case .array(let array):
            if pass.depth == 0 { return .string("[\(array.count) items]") }
            var next = pass
            next.depth -= 1
            var kept = array.prefix(pass.items).map { prune($0, next, inList: true) }
            if array.count > pass.items { kept.append(.string("… \(array.count - pass.items) more items (\(array.count) total)")) }
            return .array(kept)
        case .object(let dict):
            if pass.depth == 0 { return .string("{…}") }
            var next = pass
            next.depth -= 1
            var result: [String: JSONValue] = [:]
            for (key, v) in dict {
                switch v {
                case .null: continue
                case .array(let a) where a.isEmpty: continue
                case .object(let o) where o.isEmpty: continue
                case .array where pass.slim && inList, .object where pass.slim && inList: continue
                case .string(let text) where pass.slim && inList && (text.count > 80 || text.hasPrefix("http")):
                    continue
                default: result[key] = prune(v, next, inList: false)
                }
            }
            return .object(result)
        default:
            return value
        }
    }

    /// Identifying keys first, so each ID sits right next to the object it belongs to.
    private static let leadingKeys = ["id", "uuid", "slug", "key", "code", "name", "title"]

    static func compactJSON(_ value: JSONValue) -> String {
        switch value {
        case .array(let items):
            return "[" + items.map(compactJSON).joined(separator: ",") + "]"
        case .object(let dict):
            let keys = dict.keys.sorted { a, b in
                let ia = leadingKeys.firstIndex(of: a.lowercased()) ?? leadingKeys.count
                let ib = leadingKeys.firstIndex(of: b.lowercased()) ?? leadingKeys.count
                return (ia, a) < (ib, b)
            }
            return "{" + keys.map { compactJSON(.string($0)) + ":" + compactJSON(dict[$0]!) }.joined(separator: ",") + "}"
        default:
            return value.jsonString()
        }
    }

    func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…[truncated]"
    }
}
