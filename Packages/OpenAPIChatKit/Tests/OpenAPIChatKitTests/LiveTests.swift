import Foundation
import Testing
@testable import OpenAPIChatKit

/// Hits the public Petstore demo. Run with `LIVE_API_TESTS=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE_API_TESTS"] == "1"))
struct LiveTests {
    @Test func executorAgainstPetstore() async throws {
        let events = EventLog()
        let executor = APIExecutor(spec: petstore3, baseURL: petstore3.servers[0].url, credentials: [:],
                                   onEvent: { await events.append($0) })
        let operation = try #require(petstore3.operation(id: "findPetsByStatus"))
        let tool = try OpenAPITool(operation: operation, spec: petstore3, executor: executor)
        let output = try await tool.call(arguments: .init(properties: ["status": "available"]))
        #expect(output.hasPrefix("HTTP 200"))
        #expect(output.count < 3000)
        #expect(await events.count == 1)

        // Mutating calls wait for confirmation; declining never sends the request.
        let declining = APIExecutor(spec: petstore3, baseURL: petstore3.servers[0].url, credentials: [:], confirm: { _ in false })
        let delete = try #require(petstore3.operation(id: "deletePet"))
        let declined = try await OpenAPITool(operation: delete, spec: petstore3, executor: declining)
            .call(arguments: .init(properties: ["petId": 1]))
        #expect(declined.contains("declined"))
    }
}

actor EventLog {
    var events: [ToolCallEvent] = []
    var count: Int { events.filter { if case .finished = $0.phase { true } else { false } }.count }
    func append(_ event: ToolCallEvent) { events.append(event) }
}
