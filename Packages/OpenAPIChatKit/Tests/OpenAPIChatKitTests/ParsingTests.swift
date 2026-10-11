import Foundation
import Testing
@testable import OpenAPIChatKit

@Suite struct ParsingTests {
    @Test func openAPI3() throws {
        #expect(petstore3.operations.count == 19)
        #expect(petstore3.servers.map(\.url) == ["https://petstore3.swagger.io/api/v3"])
        #expect(Set(petstore3.securitySchemes.map(\.id)) == ["api_key", "petstore_auth"])
        let getPet = try #require(petstore3.operation(id: "getPetById"))
        #expect(getPet.parameters.map(\.name) == ["petId"])
        #expect(getPet.parameters[0].isRequired)
        #expect(petstore3.securityRequirements(for: getPet).count == 2)
    }

    @Test func swagger2() throws {
        #expect(petstore2.servers.first?.url == "https://petstore.swagger.io/v2")
        let addPet = try #require(petstore2.operation(id: "addPet"))
        #expect(addPet.requestBody?.contentType == "application/json")
        let form = try #require(petstore2.operation(id: "updatePetWithForm"))
        #expect(form.requestBody?.contentType == "application/x-www-form-urlencoded")
        // `file` form fields are skipped.
        let upload = try #require(petstore2.operation(id: "uploadFile"))
        #expect(upload.requestBody?.schema["properties"]?["file"] == nil)
    }

    @Test func yaml31() throws {
        let spec = try APISpec(data: Data(yamlSpec.utf8))
        #expect(spec.servers.map(\.url) == ["https://eu.example.com/v1"])
        #expect(spec.operations.map(\.id) == ["list_tasks", "post_projects_by_projectId_tasks"])
        let list = spec.operations[0]
        // Path-level parameters are inherited; Accept headers are ignored.
        #expect(list.parameters.map(\.name) == ["projectId", "filter"])
        #expect(list.security == [])
        #expect(spec.operations[1].security == nil)
    }

    @Test func rejectsGarbage() {
        #expect(throws: OpenAPIError.self) { try APISpec(data: Data("{\"hello\": 1}".utf8)) }
        #expect(throws: OpenAPIError.self) { try APISpec(data: Data("openapi: 3.0.0\npaths: {}".utf8)) }
    }
}
