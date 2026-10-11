import Foundation
import OpenAPIChatKit

// Usage: openapi-chat <spec path or URL> [--base-url URL] [--cloud] [--auth scheme=secret ...] [--tools]
var args = Array(CommandLine.arguments.dropFirst())
guard let source = args.first else {
    print("usage: openapi-chat <spec path or URL> [--base-url URL] [--cloud] [--auth scheme=secret] [--tools]")
    exit(1)
}
args.removeFirst()

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let url = source.contains("://") ? URL(string: source)! : URL(fileURLWithPath: source)
let data = url.isFileURL ? try Data(contentsOf: url) : try await URLSession.shared.data(from: url).0
let spec = try APISpec(data: data, sourceURL: url.isFileURL ? nil : url)
print("\(spec.title) \(spec.version) — \(spec.operations.count) operations, servers: \(spec.servers.map(\.url))")

if args.contains("--tools") {
    for operation in spec.operations {
        do {
            let interface = try ToolInterface(operation: operation, spec: spec)
            print("✓ \(operation.id) [\(operation.method) \(operation.path)] args: \(interface.bindings.map(\.argumentName))")
        } catch {
            print("✗ \(operation.id): \(error)")
        }
    }
    exit(0)
}

var credentials: [String: Credential] = [:]
for (i, arg) in args.enumerated() where arg == "--auth" && i + 1 < args.count {
    let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { credentials[parts[0]] = Credential(secret: parts[1]) }
}

let engine = ChatEngine(spec: spec, configuration: ChatConfiguration(
    baseURL: option("--base-url") ?? spec.servers.first?.url ?? "",
    credentials: credentials,
    model: args.contains("--cloud") ? .privateCloud : .onDevice,
    requiresConfirmation: false
))

var printed = 0
while true {
    print("> ", terminator: "")
    guard let line = readLine(), line != "exit" else { break }
    await engine.sendAndWait(line)
    let messages = engine.messages
    for message in messages.dropFirst(printed + 1) {
        switch message.role {
        case .toolCall(let status): print("  ⚙︎ \(message.detail ?? message.text) → \(status)")
        case .error: print("! \(message.text)")
        default: print(message.text)
        }
    }
    printed = messages.count
    print("  [tools: \(engine.activeOperationIDs.joined(separator: ", "))]")
}
