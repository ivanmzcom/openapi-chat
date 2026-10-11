import OpenAPIChatKit
import SwiftUI

struct RootView: View {
    @Environment(APILibrary.self) private var library
    @State private var selection: SavedAPI.ID?
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.apis) { api in
                    NavigationLink(value: api.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(api.name).lineLimit(1)
                            Text(api.baseURL.isEmpty ? "Sin servidor" : api.baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contextMenu {
                        Button("Eliminar", systemImage: "trash", role: .destructive) { remove(api) }
                    }
                }
                .onDelete { offsets in offsets.map { library.apis[$0] }.forEach(remove) }
            }
            .navigationTitle("APIs")
            .toolbar {
                ToolbarItem {
                    Button("Añadir API", systemImage: "plus") { showingAdd = true }
                }
            }
            .overlay {
                if library.apis.isEmpty {
                    ContentUnavailableView {
                        Label("Sin APIs", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Añade una spec OpenAPI para chatear con su API.")
                    } actions: {
                        Button("Añadir API") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            #endif
        } detail: {
            if let api = library.apis.first(where: { $0.id == selection }) {
                ChatView(api: api)
                    .id(api.id)
            } else {
                ContentUnavailableView("Elige una API", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Selecciona una API de la lista para empezar a chatear."))
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddAPIView { api in selection = api.id }
        }
        .onAppear {
            if selection == nil { selection = library.apis.first?.id }
        }
    }

    private func remove(_ api: SavedAPI) {
        if selection == api.id { selection = nil }
        library.remove(api)
    }
}
