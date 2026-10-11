import OpenAPIChatKit
import SwiftUI

struct ChatView: View {
    let api: SavedAPI

    @Environment(APILibrary.self) private var library
    @State private var engine: ChatEngine?
    @State private var loadError: String?
    @State private var showingSettings = false

    var body: some View {
        Group {
            if let engine {
                ConversationView(engine: engine, api: api)
            } else if let loadError {
                ContentUnavailableView("No se pudo cargar la spec", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(api.name)
        #if os(macOS)
        .navigationSubtitle(api.baseURL)
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Nueva conversación", systemImage: "square.and.pencil") { engine?.reset() }
                    .disabled(engine?.messages.isEmpty ?? true)
                Button("Ajustes de la API", systemImage: "slider.horizontal.3") { showingSettings = true }
            }
        }
        .sheet(isPresented: $showingSettings) {
            if let spec = try? library.spec(for: api) {
                APISettingsView(api: api, spec: spec)
            }
        }
        .task {
            do {
                engine = try library.engine(for: api)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct ConversationView: View {
    @Bindable var engine: ChatEngine
    let api: SavedAPI

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if api.baseURL.isEmpty {
                Label("La spec no indica a qué servidor llamar. Añade la URL base en los ajustes de la API.", systemImage: "network.slash")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.yellow.opacity(0.15))
            } else if let reason = api.model.unavailableReason {
                Label(reason, systemImage: "apple.intelligence")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.yellow.opacity(0.15))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if engine.messages.isEmpty {
                            EmptyConversation(spec: engine.spec, operations: engine.enabledOperations) { send($0) }
                        }
                        ForEach(engine.messages) { message in
                            MessageRow(message: message, onLoadMore: { await engine.loadMore(message.id) }).id(message.id)
                        }
                        if engine.isResponding, engine.messages.last?.role != .assistant {
                            ProgressView().controlSize(.small).padding(.leading, 4).id("typing")
                        }
                    }
                    .padding()
                }
                // The welcome screen reads from the top; a conversation follows its latest message.
                .defaultScrollAnchor(engine.messages.isEmpty ? .top : .bottom)
                .onChange(of: engine.messages.last) {
                    withAnimation { proxy.scrollTo(engine.messages.last?.id, anchor: .bottom) }
                }
            }

            Divider()
            inputBar
        }
        .alert(
            "¿Ejecutar esta petición?",
            isPresented: Binding(get: { engine.pendingCall != nil }, set: { if !$0 { engine.resolvePendingCall(approved: false) } }),
            presenting: engine.pendingCall
        ) { _ in
            Button("Cancelar", role: .cancel) { engine.resolvePendingCall(approved: false) }
            Button("Ejecutar", role: .destructive) { engine.resolvePendingCall(approved: true) }
        } message: { call in
            Text("\(call.operation.displayTitle)\n\n\(call.operation.method) \(call.url)" + (call.bodyPreview.map { "\n\n\($0)" } ?? ""))
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(api.model.unavailableReason == nil ? "Pregunta algo sobre la API…" : "Esperando a Apple Intelligence…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { send(draft) }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 18))

            if engine.isResponding {
                Button("Detener", systemImage: "stop.circle.fill") { engine.stop() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
            } else {
                Button("Enviar", systemImage: "arrow.up.circle.fill") { send(draft) }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(10)
        .disabled(api.model.unavailableReason != nil || api.baseURL.isEmpty)
        .onAppear { inputFocused = true }
    }

    private func send(_ text: String) {
        guard !engine.isResponding else { return }
        engine.send(text)
        draft = ""
    }
}

private struct EmptyConversation: View {
    let spec: APISpec
    let operations: [APIOperation]
    let onSuggestion: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spec.title).font(.title2.bold())
            if let summary = spec.summary {
                Text(summary.count > 220 ? summary.prefix(220) + "…" : summary)
                    .lineLimit(4)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(operations.count) endpoints disponibles · versión \(spec.version)")
                .font(.caption)
                .foregroundStyle(.secondary)

            let suggestions = operations.filter { !$0.isMutating && $0.summary != nil }.prefix(4)
            if !suggestions.isEmpty {
                Text("Prueba a preguntar").font(.headline).padding(.top, 8)
                ForEach(Array(suggestions)) { operation in
                    Button(operation.summary!) { onSuggestion(operation.summary!) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    var onLoadMore: (() async -> Void)?

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: .rect(cornerRadius: 16))
            }
        case .assistant:
            Text(Self.markdown(message.text))
                .textSelection(.enabled)
                .padding(.trailing, 40)
        case .toolCall(let status):
            ToolCallRow(message: message, status: status, onLoadMore: onLoadMore)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct ToolCallRow: View {
    let message: ChatMessage
    let status: ChatMessage.ToolStatus
    var onLoadMore: (() async -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            callSummary
            if let presentation = message.presentation {
                ResultView(presentation: presentation, pagination: message.pagination, onLoadMore: onLoadMore)
            }
        }
    }

    private var callSummary: some View {
        HStack(spacing: 8) {
            icon.frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.text).font(.caption.weight(.medium))
                if let detail = message.detail {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if case .failed(let reason) = status {
                    Text(reason).font(.caption2).foregroundStyle(.red)
                }
                if case .succeeded(let code) = status, !(200..<400).contains(code) {
                    Text("Error HTTP \(code) \(HTTPURLResponse.localizedString(forStatusCode: code))")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded(let code):
            Image(systemName: (200..<400).contains(code) ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle((200..<400).contains(code) ? .green : .orange)
                .help("HTTP \(code)")
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .declined:
            Image(systemName: "hand.raised.fill").foregroundStyle(.secondary)
        }
    }
}
