import Foundation
import Testing
@testable import OpenAPIChatKit

@Suite struct RouterTests {
    @Test func lexicalRanking() {
        let router = OperationRouter(operations: petstore3.operations)
        #expect(router.lexicalRank("find pets by status").first?.id == "findPetsByStatus")
        #expect(router.lexicalRank("store inventory").first?.id == "getInventory")
        #expect(router.lexicalRank("delete an order").first?.id == "deleteOrder")
    }

    @Test func budgets() {
        let small = ContextBudget(contextSize: 4096)
        #expect(small.maxTools == 3)
        #expect(small.reduced.maxTools == 1)
        #expect(ContextBudget(contextSize: 32_000).maxTools == 10)
    }
}

@Suite struct OverviewTests {
    @Test func areasComeFromTags() throws {
        let areas = try #require(ChatEngine.areas(of: petstore3.operations))
        #expect(areas.hasPrefix("pet ("))
        #expect(areas.contains("store") && areas.contains("user"))
    }
}
