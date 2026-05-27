import SwiftUI

struct LanguageSettingsView: View {
    @StateObject private var manager = LocalizationManager.shared

    var body: some View {
        List {
            // MARK: Bundled Languages
            Section {
                ForEach(LocalizationManager.bundledLanguageInfo, id: \.code) { lang in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang.name)
                            Text(lang.nativeName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            } header: {
                Text("Included")
            } footer: {
                Text("These languages are bundled with the app and always available.")
            }

            // MARK: Downloadable Languages
            Section {
                if manager.downloadableLanguages.isEmpty {
                    Text("No additional languages available")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.downloadableLanguages) { lang in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lang.name)
                                Text(lang.nativeName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()

                            if lang.isDownloaded {
                                Menu {
                                    Button(role: .destructive) {
                                        manager.removeLanguage(lang.code)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            } else if case .downloading(let code) = manager.downloadState, code == lang.code {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button {
                                    Task { await manager.downloadLanguage(lang.code) }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text("Downloadable")
                    Spacer()
                    let downloaded = manager.downloadableLanguages.filter(\.isDownloaded).count
                    if downloaded > 0 {
                        Text("\(downloaded) downloaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Download additional languages on demand. Each pack is a few KB.")
            }

            // MARK: Bulk Actions
            Section {
                let allDownloaded = manager.downloadableLanguages.allSatisfy(\.isDownloaded)
                let anyDownloaded = manager.downloadableLanguages.contains(where: \.isDownloaded)

                if !allDownloaded {
                    Button {
                        Task { await manager.downloadAll() }
                    } label: {
                        Label("Download All Languages", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(manager.downloadState != .idle)
                }

                if anyDownloaded {
                    Button(role: .destructive) {
                        manager.removeAll()
                    } label: {
                        Label("Remove All Downloads", systemImage: "trash")
                    }
                    .disabled(manager.downloadState != .idle)

                    HStack {
                        Text("Storage Used")
                        Spacer()
                        Text(manager.downloadedSize())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: Error
            if case .failed(let message) = manager.downloadState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Languages")
        .onAppear { manager.loadLanguageList() }
    }
}
