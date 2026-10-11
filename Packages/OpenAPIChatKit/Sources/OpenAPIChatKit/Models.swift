import Foundation
import FoundationModels

/// Which Apple Intelligence model answers.
public enum ModelChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The on-device model: private, offline and free, with a small context (4K–8K tokens).
    case onDevice
    /// Apple's Private Cloud Compute model: larger context, needs network.
    case privateCloud

    public var id: String { rawValue }

    /// Set to `true` only in builds signed with `com.apple.developer.private-cloud-compute`.
    /// Without that entitlement, FoundationModels traps as soon as PCC is used.
    nonisolated(unsafe) public static var isPrivateCloudEnabled = false

    /// The choices this build can actually use.
    public static var available: [ModelChoice] {
        isPrivateCloudEnabled ? allCases : [.onDevice]
    }

    /// Falls back to the on-device model when PCC isn't enabled in this build.
    public var effective: ModelChoice {
        self == .privateCloud && !Self.isPrivateCloudEnabled ? .onDevice : self
    }

    public var displayName: String {
        switch self {
        case .onDevice: "En el dispositivo"
        case .privateCloud: "Private Cloud Compute"
        }
    }

    /// `nil` when available, otherwise a user-facing reason.
    public var unavailableReason: String? {
        switch effective {
        case .onDevice:
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "Este dispositivo no es compatible con Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Activa Apple Intelligence en Ajustes para usar el chat."
            case .unavailable(.modelNotReady): return "El modelo de Apple Intelligence se está descargando o preparando. Inténtalo en unos minutos."
            case .unavailable: return "Apple Intelligence no está disponible."
            }
        case .privateCloud:
            switch PrivateCloudComputeLanguageModel().availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "Este dispositivo no puede usar Private Cloud Compute."
            case .unavailable(.systemNotReady): return "Private Cloud Compute aún no está listo en este dispositivo."
            case .unavailable: return "Private Cloud Compute no está disponible."
            }
        }
    }

    public func contextSize() async -> Int {
        switch effective {
        case .onDevice: SystemLanguageModel.default.contextSize
        case .privateCloud: (try? await PrivateCloudComputeLanguageModel().contextSize) ?? 4096
        }
    }

    public func makeSession(tools: [any Tool] = [], instructions: String) -> LanguageModelSession {
        switch effective {
        case .onDevice: LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
        case .privateCloud: LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        }
    }
}

/// Context-dependent limits. Instructions, tool schemas, history, tool results and the answer all
/// share the model's small context window, so everything is budgeted from its size.
public struct ContextBudget: Sendable {
    public var contextSize: Int
    public var maxTools: Int
    public var maxHistoryTurns: Int
    public var historyCharactersPerMessage: Int
    public var responseCharacters: Int
    public var routerCatalogSize: Int

    public init(contextSize: Int) {
        let size = max(contextSize, 2048)
        self.contextSize = size
        maxTools = size <= 4096 ? 3 : size <= 8192 ? 6 : 10
        maxHistoryTurns = size <= 4096 ? 2 : size <= 8192 ? 3 : 6
        historyCharactersPerMessage = size <= 4096 ? 300 : size <= 8192 ? 700 : 1200
        // ~20% of the context for a single tool result (≈3.5 characters per token).
        responseCharacters = min(Int(Double(size) * 0.2 * 3.5), 20_000)
        routerCatalogSize = size <= 4096 ? 40 : 120
    }

    /// A tighter budget used to retry after the context window overflowed.
    public var reduced: ContextBudget {
        var budget = self
        budget.maxTools = max(1, maxTools / 2)
        budget.maxHistoryTurns = 0
        budget.responseCharacters = responseCharacters / 2
        return budget
    }
}
