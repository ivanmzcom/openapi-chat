import SwiftUI
import UniformTypeIdentifiers

struct AddAPIView: View {
    enum Source: String, CaseIterable, Identifiable {
        case url = "URL"
        case file = "Archivo"
        case paste = "Pegar"
        var id: Self { self }
    }

    var onAdded: (SavedAPI) -> Void

    @Environment(APILibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.url
    @State private var urlText = ""
    @State private var pastedText = ""
    @State private var importing = false
    @State private var loading = false
    @State private var errorMessage: String?

    private static let examples = [
        ("Swagger Petstore", "https://petstore3.swagger.io/api/v3/openapi.json"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Origen", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch source {
                case .url:
                    Section {
                        TextField("https://ejemplo.com/openapi.json", text: $urlText)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onSubmit(addFromURL)
                    } header: {
                        Text("URL de la spec (JSON o YAML)")
                    } footer: {
                        ForEach(Self.examples, id: \.1) { name, url in
                            Button("Probar con \(name)") { urlText = url }
                                .buttonStyle(.borderless)
                        }
                    }
                case .file:
                    Section("Archivo OpenAPI o Swagger (.json, .yaml)") {
                        Button("Elegir archivo…", systemImage: "doc") { importing = true }
                    }
                case .paste:
                    Section("Contenido de la spec") {
                        TextEditor(text: $pastedText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 220)
                            .autocorrectionDisabled()
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Añadir API")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if loading {
                        ProgressView()
                    } else if source != .file {
                        Button("Añadir") { source == .url ? addFromURL() : addPasted() }
                            .disabled(source == .url ? urlText.isEmpty : pastedText.isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.specTypes) { result in
                addFile(result)
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }

    private static let specTypes: [UTType] = [.json, .yaml, .plainText].compactMap { $0 }

    private func addFromURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            errorMessage = "Escribe una URL http(s) válida."
            return
        }
        loading = true
        errorMessage = nil
        Task {
            defer { loading = false }
            do {
                finish(try await library.add(from: url))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addPasted() {
        add { try library.add(specData: Data(pastedText.utf8), sourceURL: nil) }
    }

    private func addFile(_ result: Result<URL, Error>) {
        add {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try library.add(specData: Data(contentsOf: url), sourceURL: nil)
        }
    }

    private func add(_ body: () throws -> SavedAPI) {
        errorMessage = nil
        do {
            finish(try body())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish(_ api: SavedAPI) {
        onAdded(api)
        dismiss()
    }
}
