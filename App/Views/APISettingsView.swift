import OpenAPIChatKit
import SwiftUI

struct APISettingsView: View {
    @Environment(APILibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    let spec: APISpec
    @State private var api: SavedAPI
    @State private var credentials: [String: Credential]
    @State private var refreshing = false
    @State private var errorMessage: String?

    init(api: SavedAPI, spec: APISpec) {
        self.spec = spec
        _api = State(initialValue: api)
        _credentials = State(initialValue: Keychain.credentials(for: api.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Servidor") {
                    if !spec.servers.isEmpty {
                        Picker("Servidor de la spec", selection: $api.baseURL) {
                            ForEach(spec.servers) { server in
                                Text(server.description ?? server.url).tag(server.url)
                            }
                            if !spec.servers.contains(where: { $0.url == api.baseURL }) {
                                Text("Personalizado").tag(api.baseURL)
                            }
                        }
                    }
                    TextField("URL base", text: $api.baseURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                }

                Section {
                    if ModelChoice.available.count > 1 {
                        Picker("Modelo", selection: $api.model) {
                            ForEach(ModelChoice.available) { Text($0.displayName).tag($0) }
                        }
                    }
                    if let reason = api.model.unavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Confirmar antes de modificar datos", isOn: $api.requiresConfirmation)
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    Text("El modelo en el dispositivo es privado y funciona sin conexión, pero tiene un contexto pequeño. Private Cloud Compute admite conversaciones y respuestas más largas.")
                }

                if !spec.securitySchemes.isEmpty {
                    Section {
                        ForEach(spec.securitySchemes) { scheme in
                            CredentialEditor(scheme: scheme, credential: binding(for: scheme.id))
                        }
                    } header: {
                        Text("Autenticación")
                    } footer: {
                        Text("Las credenciales se guardan en el llavero y solo se envían a esta API.")
                    }
                }

                Section("Endpoints") {
                    NavigationLink {
                        OperationsView(spec: spec, disabled: $api.disabledOperationIDs)
                    } label: {
                        LabeledContent("Activos", value: "\(spec.operations.count - api.disabledOperationIDs.count) de \(spec.operations.count)")
                    }
                }

                Section {
                    if api.sourceURL != nil {
                        Button("Volver a descargar la spec", systemImage: "arrow.clockwise", action: refresh)
                            .disabled(refreshing)
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                    LabeledContent("Versión de la spec", value: "\(spec.isSwagger2 ? "Swagger" : "OpenAPI") \(spec.specVersion)")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ajustes de \(api.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar", action: save)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func binding(for schemeID: String) -> Binding<Credential> {
        Binding(get: { credentials[schemeID] ?? Credential() }, set: { credentials[schemeID] = $0 })
    }

    private func save() {
        if let error = Keychain.save(credentials, for: api.id) {
            errorMessage = error
            return
        }
        library.update(api)
        library.credentialsDidChange(for: api)
        dismiss()
    }

    private func refresh() {
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                try await library.refresh(api)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct CredentialEditor: View {
    let scheme: SecurityScheme
    @Binding var credential: Credential

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(scheme.id).font(.headline)
                Spacer()
                Text(kindLabel).font(.caption).foregroundStyle(.secondary)
            }
            if let description = scheme.description {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            fields
        }
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .padding(.vertical, 4)
    }

    @ViewBuilder private var fields: some View {
        switch scheme.kind {
        case .apiKey:
            SecureField("API key", text: $credential.secret)
        case .httpBearer, .openIdConnect:
            SecureField("Token", text: $credential.secret)
        case .httpBasic:
            TextField("Usuario", text: $credential.username)
            SecureField("Contraseña", text: $credential.password)
        case .oauth2(let flows):
            SecureField("Access token", text: $credential.secret)
            if flows.clientCredentialsTokenURL != nil || flows.passwordTokenURL != nil {
                Text("o deja que la app obtenga el token:").font(.caption).foregroundStyle(.secondary)
                TextField("Client ID", text: $credential.clientID)
                SecureField("Client secret", text: $credential.clientSecret)
                if flows.passwordTokenURL != nil {
                    TextField("Usuario", text: $credential.username)
                    SecureField("Contraseña", text: $credential.password)
                }
            }
        case .unsupported(let type):
            Text("Tipo de autenticación no soportado: \(type)").font(.caption).foregroundStyle(.orange)
        }
    }

    private var kindLabel: String {
        switch scheme.kind {
        case .apiKey(let name, let location): "API key · \(location.rawValue) “\(name)”"
        case .httpBearer(let format): "Bearer" + (format.map { " (\($0))" } ?? "")
        case .httpBasic: "HTTP Basic"
        case .oauth2: "OAuth 2"
        case .openIdConnect: "OpenID Connect"
        case .unsupported: "No soportado"
        }
    }
}

private struct OperationsView: View {
    let spec: APISpec
    @Binding var disabled: Set<String>

    private var groups: [(tag: String, operations: [APIOperation])] {
        let grouped = Dictionary(grouping: spec.operations) { $0.tags.first ?? "General" }
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Activar todos") { disabled = [] }
                    Spacer()
                    Button("Solo lectura") { disabled = Set(spec.operations.filter(\.isMutating).map(\.id)) }
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("Con menos endpoints activos, Apple Intelligence elige mejor cuál usar.")
            }
            ForEach(groups, id: \.tag) { group in
                Section(group.tag) {
                    ForEach(group.operations) { operation in
                        Toggle(isOn: Binding(
                            get: { !disabled.contains(operation.id) },
                            set: { if $0 { disabled.remove(operation.id) } else { disabled.insert(operation.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    MethodBadge(method: operation.method)
                                    Text(operation.path).font(.caption.monospaced()).lineLimit(1)
                                }
                                Text(operation.displayTitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Endpoints")
    }
}

struct MethodBadge: View {
    let method: String

    var body: some View {
        Text(method)
            .font(.caption2.monospaced().bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color, in: .rect(cornerRadius: 4))
    }

    private var color: Color {
        switch method {
        case "GET": .blue
        case "POST": .green
        case "PUT", "PATCH": .orange
        case "DELETE": .red
        default: .gray
        }
    }
}
