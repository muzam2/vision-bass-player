import SwiftUI

/// Shares → folders → files. Selecting a video file hands a `MediaItem` to the player.
struct NASBrowserView: View {
    @EnvironmentObject private var nas: NASClient
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if nas.shares.isEmpty {
                    ContentUnavailableView {
                        Label("No shares yet", systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text("Add your NAS (SMB or WebDAV) to browse and play files directly. Enter just the host to see all its shares.")
                    } actions: {
                        Button { showAdd = true } label: { Label("Add share", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(nas.shares) { share in
                            NavigationLink(value: NASLocation(share: share, path: "")) {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(share.name).font(.headline)
                                        Text("\(share.kind.label) · \(share.address)").font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "externaldrive.connected.to.line.below")
                                }
                            }
                        }
                        .onDelete { idx in idx.map { nas.shares[$0] }.forEach { nas.remove($0) } }
                    }
                }
            }
            .navigationTitle("NAS")
            .navigationDestination(for: NASLocation.self) { loc in
                NASFolderView(location: loc)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Label("Add share", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { NASShareEditor() }
        }
    }
}

struct NASLocation: Hashable {
    let share: NASShare
    let path: String
}

struct NASFolderView: View {
    let location: NASLocation
    @EnvironmentObject private var nas: NASClient
    @EnvironmentObject private var library: LibraryStore
    @State private var entries: [NASEntry] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Listing…")
            } else if let error {
                ContentUnavailableView("Can't open folder", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if entries.isEmpty {
                ContentUnavailableView("Empty", systemImage: "folder")
            } else {
                List {
                    ForEach(entries.filter { $0.isDirectory || $0.isVideo }) { e in
                        if e.isDirectory {
                            NavigationLink(value: NASLocation(share: location.share, path: e.path)) {
                                Label(e.name, systemImage: "folder")
                            }
                        } else {
                            Button {
                                library.play(nas.mediaItem(share: location.share, entry: e))
                            } label: {
                                HStack {
                                    Label(e.name, systemImage: "film")
                                    Spacer()
                                    if e.size > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle(location.path.isEmpty ? location.share.name : (location.path as NSString).lastPathComponent)
        .task(id: location) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do { entries = try await nas.list(share: location.share, path: location.path) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct NASShareEditor: View {
    @EnvironmentObject private var nas: NASClient
    @Environment(\.dismiss) private var dismiss
    @State private var share = NASShare(name: "", kind: .smb, address: "", username: "")
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Share") {
                    TextField("Name (e.g. Synology)", text: $share.name)
                    Picker("Type", selection: $share.kind) {
                        ForEach(NASShare.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    TextField(share.kind == .smb ? "nas.local/video  or  192.168.1.20" : "https://nas.local:5006/video", text: $share.address)
                        .textInputAutocapitalization(.never)
                    if share.kind == .smb {
                        Text("Host alone lists the shares; host/share opens one share directly.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Sign in") {
                    TextField("Username (blank for guest)", text: $share.username)
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                    if share.kind == .smb {
                        TextField("Domain / workgroup (optional)", text: $share.domain)
                            .textInputAutocapitalization(.never)
                    }
                }
            }
            .navigationTitle("Add NAS share")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if share.name.isEmpty { share.name = share.address }
                        nas.add(share, password: password)
                        dismiss()
                    }
                    .disabled(share.address.isEmpty)
                }
            }
        }
    }
}
