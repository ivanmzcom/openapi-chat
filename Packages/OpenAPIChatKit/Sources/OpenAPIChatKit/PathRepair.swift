import Foundation

/// Fixes a common small-model mistake when chaining calls: putting an item's ID into the parent's
/// path parameter. With `/stores/{id}/products` returning products that also have an `id`, a follow-up
/// like `/stores/{id}/product?url=…` often gets the *product's* id as the store `{id}`.
public enum PathRepair {
    public struct PreviousCall: Sendable {
        public var operation: APIOperation
        public var arguments: JSONValue
        public var rows: [[String: JSONValue]]

        public init(operation: APIOperation, arguments: JSONValue, rows: [[String: JSONValue]]) {
            self.operation = operation
            self.arguments = arguments
            self.rows = rows
        }
    }

    /// Uses the parent's path value from a previous result (requested under the same path prefix)
    /// when the new call is clearly about one of that result's items:
    /// - the path value itself is one of the items' IDs (an item ID can't be the parent's ID), or
    /// - another argument carries a value taken from those items (e.g. the item's URL), so the item,
    ///   and therefore its parent, is known.
    /// - Parameter previous: earlier successful calls, oldest first.
    public static func repair(_ arguments: JSONValue, for operation: APIOperation, previous: [PreviousCall]) -> JSONValue {
        guard var args = arguments.objectValue else { return arguments }
        let pathNames = Set(operation.parameters.filter { $0.location == .path }.map(\.name))
        let otherValues = Set(args.filter { !pathNames.contains($0.key) }.map(\.value.scalarText).filter { $0.count >= 4 })

        for parameter in operation.parameters where parameter.location == .path {
            guard let value = args[parameter.name]?.scalarText,
                  let range = operation.path.range(of: "{\(parameter.name)}") else { continue }
            let prefix = String(operation.path[..<range.upperBound])
            for call in previous.reversed() where call.operation.path.hasPrefix(prefix) {
                guard let parentValue = call.arguments[parameter.name]?.scalarText, parentValue != value else { continue }
                let refersToItem = itemIDs(in: call.rows).contains(value)
                    || !otherValues.isDisjoint(with: allValues(in: call.rows))
                if refersToItem {
                    args[parameter.name] = .string(parentValue)
                    break
                }
            }
        }
        return .object(args)
    }

    static func allValues(in rows: [[String: JSONValue]]) -> Set<String> {
        Set(rows.flatMap { $0.values.map(\.scalarText) })
    }

    static func itemIDs(in rows: [[String: JSONValue]]) -> Set<String> {
        var ids = Set<String>()
        for row in rows {
            for (key, value) in row {
                let lower = key.lowercased()
                if lower == "id" || lower.hasSuffix("id") || lower == "uuid" || lower == "slug" {
                    ids.insert(value.scalarText)
                }
            }
        }
        return ids
    }
}
