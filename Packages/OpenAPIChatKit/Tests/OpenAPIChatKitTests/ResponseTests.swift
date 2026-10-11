import Foundation
import Testing
@testable import OpenAPIChatKit

@Suite struct CondenserTests {
    @Test func largeArraysFit() {
        let items = (0..<500).map { i in JSONValue.object(["id": .number(Double(i)), "name": .string("pet \(i)"), "notes": .string(String(repeating: "x", count: 1000)), "tag": .null]) }
        let text = ResponseCondenser(maxCharacters: 1500).condense(status: 200, contentType: "application/json", data: JSONValue.array(items).jsonData())
        #expect(text.count <= 1600)
        #expect(text.hasPrefix("HTTP 200"))
        #expect(text.contains("500 total"))
        #expect(!text.contains("\"tag\""))
    }

    @Test func nonJSON() {
        let condenser = ResponseCondenser(maxCharacters: 50)
        #expect(condenser.condense(status: 204, contentType: nil, data: Data()) == "HTTP 204 no content (empty body)")
        #expect(condenser.condense(status: 200, contentType: "image/png", data: Data([1, 2, 3])).contains("image/png content, 3 bytes"))
    }
}

@Suite struct SlimListTests {
    @Test func keepsEveryItemOfAPageBySlimmingFields() {
        let products = (1...30).map { i in JSONValue.object([
            "id": .string("p\(i)"), "name": .string("RG Gundam \(i) 1/144"), "price": .number(36), "availability": .string("in_stock"),
            "url": .string("https://shop.example.com/products/rg-gundam-\(i)"), "description": .string(String(repeating: "x", count: 400)),
            "images": .array([.string("https://img.example.com/\(i).jpg")]),
        ]) }
        let page = JSONValue.object(["products": .array(products), "total": .number(49), "page": .number(1)])
        let text = ResponseCondenser(maxCharacters: 2900).condense(page)
        #expect(text.count <= 2900)
        #expect(text.contains("RG Gundam 30 1/144"))
        #expect(!text.contains("more items"))
        #expect(text.contains("\"total\":49"))
        #expect(!text.contains("img.example.com"))
    }
}

@Suite struct ModelTextTests {
    @Test func includesLinksAndFacts() throws {
        let rows = (1...6).map { i in JSONValue.object([
            "name": .string("Kit \(i)"), "availability": .string(i <= 2 ? "in_stock" : "out_of_stock"),
            "price": .number(Double(10 * i)), "url": .string("https://shop.example.com/kit-\(i)"),
        ]) }
        let table = try #require(ResultTable(.array(rows)))
        let text = table.modelText(maxCharacters: 2000)
        #expect(text.contains("https://shop.example.com/kit-1"))
        #expect(text.contains("availability counts: out_of_stock 4, in_stock 2"))
        #expect(text.contains("price: min 10, max 60"))
    }
}

@Suite struct LongIDTests {
    @Test func idsAreNeverTruncated() throws {
        let id = "store_3f9a1c3f9a1c3f9a1c3f9a1c3f9a1c3f9a1c3f9a1c3f9a1c3f9a1c3f9a1c3f9a1c"
        let rows: [JSONValue] = [
            .object(["id": .string(id), "name": .string("Acme Model Kits"), "storeId": .string(id + "x")]),
            .object(["id": .string("store_2"), "name": .string(String(repeating: "Very Long Store Name ", count: 10)), "storeId": .string("s2")]),
        ]
        let text = try #require(ResultPresentation(.array(rows))).modelText(maxCharacters: 3000)
        #expect(text.contains(id))
        #expect(text.contains(id + "x"))
        #expect(!text.contains(String(repeating: "Very Long Store Name ", count: 10)))
    }
}
