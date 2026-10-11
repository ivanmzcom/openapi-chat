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

@Suite struct ChartTests {
    @Test func priceHistoryIsATimeSeries() throws {
        let history = JSONValue.object(["history": .array([
            .object(["observedAt": .string("2026-10-09T20:52:00Z"), "price": .number(29.75), "availability": .string("out_of_stock")]),
            .object(["observedAt": .string("2026-10-02T03:39:00Z"), "price": .number(29.75), "availability": .string("in_stock")]),
            .object(["observedAt": .string("2026-10-05T10:00:00.000Z"), "price": .number(27.5), "availability": .string("in_stock")]),
        ])])
        let chart = try #require(ResultPresentation(history)?.chart)
        #expect(chart.kind == .timeSeries)
        #expect(chart.xKey == "observedAt" && chart.yKey == "price")
        #expect(chart.points.map(\.value) == [29.75, 27.5, 29.75])   // sorted by date
    }

    @Test func flatHistoryStillCharts() throws {
        let rows: [JSONValue] = [
            .object(["date": .string("2026-10-02"), "price": .number(10)]),
            .object(["date": .string("2026-10-09"), "price": .number(10)]),
        ]
        #expect(try #require(ResultPresentation(.array(rows))?.chart).kind == .timeSeries)
    }

    @Test func labelledValuesAreBars() throws {
        let rows = (1...5).map { JSONValue.object(["id": .number(Double($0)), "name": .string("Kit \($0)"), "price": .number(Double($0) * 10)]) }
        let chart = try #require(ResultPresentation(.array(rows))?.chart)
        #expect(chart.kind == .bars && chart.yKey == "price")
        #expect(chart.points.first?.label == "Kit 1")
    }

    @Test func numericRecordIsBars() throws {
        let inventory = JSONValue.object(["approved": .number(7), "placed": .number(-19), "available": .number(3)])
        let chart = try #require(ResultPresentation(inventory)?.chart)
        #expect(chart.kind == .bars && chart.points.count == 3)
    }

    @Test func noChartWithoutNumbers() {
        let rows = (1...3).map { JSONValue.object(["name": .string("Store \($0)"), "url": .string("https://s\($0).example.com")]) }
        #expect(ResultPresentation(.array(rows))?.chart == nil)
    }
}

@Suite struct NumericStringTests {
    @Test func decimalStringsChart() throws {
        let rows = (1...4).map { JSONValue.object(["name": .string("Kit \($0)"), "price": .string("\($0)9.75")]) }
        let chart = try #require(ResultPresentation(.array(rows))?.chart)
        #expect(chart.yKey == "price" && chart.points.map(\.value) == [19.75, 29.75, 39.75, 49.75])
    }

    @Test func onlyExactNumbers() {
        #expect(JSONValue.string("29.75").numericValue == 29.75)
        #expect(JSONValue.string("-3").numericValue == -3)
        #expect(JSONValue.string("29,75 €").numericValue == nil)
        #expect(JSONValue.string("1e5").numericValue == nil)
    }
}

@Suite struct ShapeTests {
    @Test func detailKeepsEveryList() throws {
        let pokemon = JSONValue.object([
            "name": .string("pikachu"), "height": .number(4), "weight": .number(60), "base_experience": .number(112),
            "stats": .array(["hp": 35, "attack": 55, "speed": 90].map { .object(["base_stat": .number(Double($0.value)), "stat": .object(["name": .string($0.key)])]) }),
            "types": .array([.object(["slot": .number(1), "type": .object(["name": .string("electric")])])]),
            "moves": .array((1...100).map { .object(["move": .object(["name": .string("move-\($0)"), "url": .string("https://x/\($0)")])]) }),
        ])
        guard case .detail(let fields, let tables) = try #require(ResultPresentation(pokemon)) else {
            Issue.record("expected detail"); return
        }
        #expect(fields.map(\.key).contains("name"))
        #expect(tables.first?.title == "stats")          // charts best, so it comes first
        #expect(Set(tables.compactMap(\.title)) == ["stats", "types", "moves"])
        let text = ResultPresentation.detail(fields: fields, tables: tables).modelText(maxCharacters: 2500)
        #expect(text.contains("electric") && text.contains("speed"))
        #expect(text.count <= 2700)
    }

    @Test func listsInDisguise() throws {
        let byName = JSONValue.object(["adyen.com": .object(["added": .string("2020-01-01"), "preferred": .string("v1")]),
                                       "amadeus.com": .object(["added": .string("2021-01-01"), "preferred": .string("v2")]),
                                       "ebay.com": .object(["added": .string("2022-01-01"), "preferred": .string("v3")])])
        guard case .table(let table) = try #require(ResultPresentation(byName)) else { Issue.record("expected table"); return }
        #expect(table.columns.first == "key" && table.rows.count == 3)

        let names = JSONValue.object(["data": .array((1...40).map { .string("provider\($0).com") })])
        guard case .table(let list) = try #require(ResultPresentation(names)) else { Issue.record("expected table"); return }
        #expect(list.rows.count == 40 && list.columns == ["value"])
        #expect(list.modelText(maxCharacters: 3000).contains("provider40.com"))
    }
}

@Suite struct JSONLDTests {
    @Test func metadataIsIgnored() throws {
        let alerts = JSONValue.object([
            "@context": .array([.object(["@version": .string("1.1")])]),
            "type": .string("FeatureCollection"),
            "features": .array((1...4).map { .object(["properties": .object(["event": .string("Flood \($0)"), "severity": .string("Moderate")])]) }),
        ])
        guard case .table(let table) = try #require(ResultPresentation(alerts)) else { Issue.record("expected table"); return }
        #expect(table.rows.count == 4 && table.columns.contains("properties.event"))
    }
}
