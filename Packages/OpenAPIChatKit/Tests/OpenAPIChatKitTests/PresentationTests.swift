import Foundation
import Testing
@testable import OpenAPIChatKit

@Suite struct PresentationTests {
    @Test func tableFromNestedList() throws {
        let products = (1...30).map { i in JSONValue.object([
            "id": .string("p\(i)"), "name": .string("RG Gundam \(i)"), "price": .object(["amount": .number(36), "currency": .string("EUR")]),
            "availability": .string("in_stock"), "url": .string("https://shop.example.com/p/\(i)"),
            "description": .string(String(repeating: "x", count: 200)), "images": .array([.object(["src": .string("a.jpg")])]),
        ]) }
        let presentation = try #require(ResultPresentation(.object(["products": .array(products), "total": .number(49)])))
        guard case .table(let table) = presentation else { Issue.record("expected table"); return }
        #expect(table.title == "products")
        #expect(table.rows.count == 30)
        #expect(table.columns.first == "name")
        #expect(table.columns.contains("price.amount") && table.columns.contains("availability"))
        #expect(!table.columns.contains("description") && !table.columns.contains("url"))
        #expect(table.columns.last == "id")
        #expect(table.linkColumn == "url")
    }

    @Test func recordFromSingleObject() throws {
        let presentation = try #require(ResultPresentation(.object(["name": .string("Rex"), "status": .string("sold"), "id": .number(7)])))
        guard case .record(let fields) = presentation else { Issue.record("expected record"); return }
        #expect(fields.map(\.key) == ["name", "status", "id"])
    }

    @Test func nothingForScalars() {
        #expect(ResultPresentation(.array([.string("a"), .string("b")])) == nil)
    }
}

/// A small paginated API: page numbers with a total, and a cursor-based feed.
let paginatedSpec = try! APISpec(data: Data("""
openapi: 3.1.0
info: { title: Shops, version: "1" }
paths:
  /stores/{id}/products:
    get:
      operationId: storeProducts
      parameters:
        - { name: id, in: path, required: true, schema: { type: string } }
        - { name: page, in: query, schema: { type: integer } }
      responses: {}
  /scans:
    get:
      operationId: scans
      parameters:
        - { name: before, in: query, schema: { type: string } }
      responses: {}
""".utf8))

@Suite struct PaginationTests {
    func page(_ count: Int, total: Int?) -> JSONValue {
        var dict: [String: JSONValue] = ["products": .array((0..<count).map { .object(["name": .string("P\($0)")]) })]
        if let total { dict["total"] = .number(Double(total)) }
        return .object(dict)
    }

    @Test func pageNumbers() throws {
        let products = try #require(paginatedSpec.operation(id: "storeProducts"))
        let first = try #require(Pagination.next(operation: products, arguments: .object(["id": .string("s1")]),
                                                 response: page(30, total: 49), pageItems: 30))
        #expect(first.nextArguments == .object(["id": .string("s1"), "page": .number(2)]))
        #expect(first.total == 49 && first.loaded == 30)
        #expect(first.hint(toolName: products.id).contains("page=2"))

        // The second page completes the 49 items: nothing more to load.
        #expect(Pagination.next(operation: products, arguments: first.nextArguments, response: page(19, total: 49),
                                pageItems: 19, loadedBefore: 30) == nil)
        // A short page without a total is treated as the last one.
        #expect(Pagination.next(operation: products, arguments: .object([:]), response: page(4, total: nil), pageItems: 4) == nil)
    }

    @Test func cursors() throws {
        let scans = try #require(paginatedSpec.operation(id: "scans"))
        let response = JSONValue.object(["scans": .array([.object(["name": .string("a")])]), "next": .string("cur_123")])
        let next = try #require(Pagination.next(operation: scans, arguments: .object([:]), response: response, pageItems: 1))
        #expect(next.nextArguments["before"] == .string("cur_123"))
    }

    @Test func replyLanguage() {
        #expect(ChatEngine.languageName(of: "enséñame los productos de la tienda") == "Spanish")
        #expect(ChatEngine.languageName(of: "show me all the products please") == "English")
    }
}
