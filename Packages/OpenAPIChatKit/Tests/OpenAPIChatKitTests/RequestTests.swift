import Foundation
import Testing
@testable import OpenAPIChatKit

@Suite struct RequestTests {
    let builder = RequestBuilder(baseURL: "https://api.example.com/v3/")

    @Test func pathAndQuery() throws {
        let getPet = try #require(petstore3.operation(id: "getPetById"))
        let request = try builder.makeRequest(for: getPet, input: RequestInput(parameters: [(getPet.parameters[0], .number(7))]))
        #expect(request.url?.absoluteString == "https://api.example.com/v3/pet/7")
        #expect(request.httpMethod == "GET")

        let byTags = try #require(petstore3.operation(id: "findPetsByTags"))
        let tagsRequest = try builder.makeRequest(for: byTags, input: RequestInput(parameters: [(byTags.parameters[0], .array([.string("a b"), .string("c&d")]))]))
        #expect(tagsRequest.url?.absoluteString == "https://api.example.com/v3/pet/findByTags?tags=a%20b&tags=c%26d")
    }

    @Test func deepObjectAndMissing() throws {
        let spec = try APISpec(data: Data(yamlSpec.utf8))
        let list = spec.operations[0]
        let request = try RequestBuilder(baseURL: "https://x.io").makeRequest(for: list, input: RequestInput(parameters: [
            (list.parameters[0], .number(3)),
            (list.parameters[1], .object(["status": .string("open")])),
        ]))
        #expect(request.url?.absoluteString == "https://x.io/projects/3/tasks?filter%5Bstatus%5D=open")

        #expect(throws: RequestBuildError.missingRequired(["projectId"])) {
            try RequestBuilder(baseURL: "https://x.io").makeRequest(for: list, input: RequestInput())
        }
    }

    @Test func bodies() throws {
        let form = try #require(petstore2.operation(id: "updatePetWithForm"))
        let petId = try #require(form.parameters.first)
        let request = try builder.makeRequest(for: form, input: RequestInput(
            parameters: [(petId, .number(1))], body: .object(["name": .string("Rex Jr"), "status": .string("sold")])))
        #expect(String(decoding: request.httpBody!, as: UTF8.self) == "name=Rex%20Jr&status=sold")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        let addPet = try #require(petstore3.operation(id: "addPet"))
        let json = try builder.makeRequest(for: addPet, input: RequestInput(body: .object(["name": .string("Rex")])))
        #expect(String(decoding: json.httpBody!, as: UTF8.self) == "{\"name\":\"Rex\"}")
        #expect(json.httpMethod == "POST")
    }
}

@Suite struct AuthTests {
    @Test func picksSatisfiableAlternative() async throws {
        let getPet = try #require(petstore3.operation(id: "getPetById"))
        let requirements = petstore3.securityRequirements(for: getPet)

        let none = try await AuthResolver(schemes: petstore3.securitySchemes, credentials: [:]).resolve(requirements)
        #expect(none.headers.isEmpty)
        #expect(!none.missingSchemes.isEmpty)

        let key = try await AuthResolver(schemes: petstore3.securitySchemes, credentials: ["api_key": Credential(secret: "s3cret")]).resolve(requirements)
        #expect(key.headers == ["api_key": "s3cret"])
        #expect(key.missingSchemes.isEmpty)

        let oauth = try await AuthResolver(schemes: petstore3.securitySchemes, credentials: ["petstore_auth": Credential(secret: "tok")]).resolve(requirements)
        #expect(oauth.headers == ["Authorization": "Bearer tok"])

        let request = try RequestBuilder(baseURL: "https://x.io").makeRequest(
            for: getPet, input: RequestInput(parameters: [(getPet.parameters[0], .number(1))]), auth: key)
        #expect(request.value(forHTTPHeaderField: "api_key") == "s3cret")
    }

    @Test func queryKeyAndBasic() async throws {
        let schemes = [
            SecurityScheme(id: "key", kind: .apiKey(name: "api_key", location: .query)),
            SecurityScheme(id: "basic", kind: .httpBasic),
        ]
        let resolver = AuthResolver(schemes: schemes, credentials: [
            "key": Credential(secret: "k"),
            "basic": Credential(username: "ana", password: "pw"),
        ])
        let auth = try await resolver.resolve([["key": [], "basic": []]])
        #expect(auth.queryItems.map { "\($0)=\($1)" } == ["api_key=k"])
        #expect(auth.headers["Authorization"] == "Basic YW5hOnB3")

        // An empty requirement means anonymous access is allowed.
        let anonymous = try await AuthResolver(schemes: schemes, credentials: [:]).resolve([["key": []], [:]])
        #expect(anonymous.missingSchemes.isEmpty)
    }
}

@Suite struct PathRepairTests {
    let spec = try! APISpec(data: Data("""
    openapi: 3.1.0
    info: { title: Shops, version: "1" }
    paths:
      /stores/{id}/products:
        get:
          operationId: storeProducts
          parameters: [{ name: id, in: path, required: true, schema: { type: string } }]
          responses: {}
      /stores/{id}/product:
        get:
          operationId: storeProduct
          parameters:
            - { name: id, in: path, required: true, schema: { type: string } }
            - { name: url, in: query, schema: { type: string } }
          responses: {}
    """.utf8))

    var previous: [PathRepair.PreviousCall] {
        [PathRepair.PreviousCall(
            operation: spec.operation(id: "storeProducts")!,
            arguments: .object(["id": .string("store_A")]),
            rows: [["id": .string("prod_1"), "name": .string("Kit"), "url": .string("https://shop/kit-1")],
                   ["id": .string("prod_2"), "name": .string("Kit 2"), "url": .string("https://shop/kit-2")]]
        )]
    }

    @Test func itemIDInParentSlotIsReplaced() {
        let detail = spec.operation(id: "storeProduct")!
        let fixed = PathRepair.repair(.object(["id": .string("prod_2"), "url": .string("https://x")]), for: detail, previous: previous)
        #expect(fixed["id"] == .string("store_A"))
        #expect(fixed["url"] == .string("https://x"))
    }

    @Test func parentIDFollowsTheReferencedItem() {
        // The URL identifies an item listed under store_A, so a different store ID (e.g. taken from
        // some other listing) is replaced.
        let detail = spec.operation(id: "storeProduct")!
        let fixed = PathRepair.repair(.object(["id": .string("store_X"), "url": .string("https://shop/kit-2")]), for: detail, previous: previous)
        #expect(fixed["id"] == .string("store_A"))
    }

    @Test func otherValuesAreLeftAlone() {
        let detail = spec.operation(id: "storeProduct")!
        // Another store chosen on purpose: not an item of the previous result.
        #expect(PathRepair.repair(.object(["id": .string("store_B")]), for: detail, previous: previous)["id"] == .string("store_B"))
        #expect(PathRepair.repair(.object(["id": .string("store_A")]), for: detail, previous: previous)["id"] == .string("store_A"))
    }
}
