import Foundation
import Testing
@testable import OpenAPIChatKit

@Suite struct SchemaTests {
    let spec = try! APISpec(data: Data(yamlSpec.utf8))

    @Test func allOfRefsAndCycles() throws {
        let body = try #require(spec.operations[1].requestBody)
        let (schema, _) = spec.normalize(body.schema)
        guard case .object(let properties, let required) = schema else {
            Issue.record("expected object, got \(schema)")
            return
        }
        // Required first, read-only dropped.
        #expect(properties.map(\.name) == ["title", "due", "labels", "parent", "priority"])
        #expect(required == ["title"])
        let priority = try #require(properties.first { $0.name == "priority" })
        guard case .integer(1, 5) = priority.schema else {
            Issue.record("oneOf with null should collapse to the integer, got \(priority.schema)")
            return
        }
        // Recursive Node terminates.
        let parent = try #require(properties.first { $0.name == "parent" })
        guard case .object(let nodeProps, _) = parent.schema, case .any = nodeProps[0].schema else {
            Issue.record("recursive ref should end in .any, got \(parent.schema)")
            return
        }
    }

    @Test func everyPetstoreOperationBecomesATool() throws {
        for spec in [petstore2, petstore3, self.spec] {
            for operation in spec.operations {
                _ = try ToolInterface(operation: operation, spec: spec)
            }
        }
    }

    @Test func collisionsGetPrefixed() throws {
        let update = try #require(petstore3.operation(id: "updateUser"))
        let interface = try ToolInterface(operation: update, spec: petstore3)
        #expect(interface.bindings.map(\.argumentName).contains("body_username"))
        let input = interface.requestInput(from: .object(["username": .string("ana"), "body_username": .string("ana2"), "email": .string("a@b.c")]))
        #expect(input.value(for: "username", in: .path) == .string("ana"))
        #expect(input.body == .object(["username": .string("ana2"), "email": .string("a@b.c")]))
    }

    @Test func coercion() throws {
        let addPet = try #require(petstore3.operation(id: "addPet"))
        let interface = try ToolInterface(operation: addPet, spec: petstore3)
        let input = interface.requestInput(from: .object([
            "name": .string("Rex"),
            "id": .string("12"),
            "photoUrls": .string("[\"a.png\"]"),
            "status": .string(""),
        ]))
        #expect(input.body == .object([
            "name": .string("Rex"),
            "id": .number(12),
            "photoUrls": .array([.string("a.png")]),
        ]))
    }
}

@Suite struct ProvenanceTests {
    let spec = try! APISpec(data: Data("""
    openapi: 3.1.0
    info: { title: Stores, version: "1" }
    paths:
      /stores:
        get: { operationId: listStores, responses: {} }
        head: { operationId: headStores, responses: {} }
      /stores/{id}/products:
        get:
          operationId: storeProducts
          parameters:
            - { name: id, in: path, required: true, schema: { type: string } }
          responses: {}
      /stores/{id}:
        delete:
          operationId: deleteStore
          parameters:
            - { name: id, in: path, required: true, description: Store slug, schema: { type: string } }
          responses: {}
    """.utf8))

    @Test func undocumentedPathIDsPointToTheirListOperation() throws {
        #expect(!spec.operations.contains { $0.method == "HEAD" })
        let products = try #require(spec.operation(id: "storeProducts"))
        let id = products.parameters[0]
        #expect(spec.sourceOperation(for: id, in: products)?.id == "listStores")
        #expect(id.description?.contains("listStores") == true)
        // Existing descriptions are left alone.
        #expect(spec.operation(id: "deleteStore")?.parameters[0].description == "Store slug")
    }

    @Test func idsLeadEachObject() {
        let json = JSONValue.object(["categories": .array([.object(["name": .string("Toys"), "id": .number(5)])]), "name": .string("Acme Store"), "id": .string("store_1")])
        #expect(ResponseCondenser.compactJSON(json) == #"{"id":"store_1","name":"Acme Store","categories":[{"id":5,"name":"Toys"}]}"#)
    }
}
