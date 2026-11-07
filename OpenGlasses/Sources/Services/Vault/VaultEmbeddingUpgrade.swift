import Foundation

/// Keeps every vault's manuals on Field Assist's embedding model (Plan IV P4).
///
/// Field Assist searches manuals with the contextual model while "Smarter manual search" is on —
/// the default — and its asset is on the device. The asset may not be there yet: it downloads from
/// Apple on first use, and a phone offline or a failed request leaves it missing. Until it lands,
/// a vault indexes and answers with the standard model and stays searchable; when it lands, or
/// when the setting changes either way, each vault is re-indexed once in the background
/// (`DocumentStore.upgradeVaultEmbeddings`). The index that answers is untouched until the new one
/// is complete, a run the app leaves behind carries on from where it stopped, and progress shows
/// where every other index's does (`VaultIndexingMonitor`).
///
/// **Per script (Plan JY P1).** A vault's manuals in another script — Cyrillic, Arabic, Urdu, CJK
/// — are on that script's own model instead, and each script is its own index: an English and a
/// Chinese manual in one library each keep the index that answers for them until their own new
/// one is complete. A manual whose script's model is not on the phone has no vectors and is
/// searched by its words; when the model lands (`ScriptModelAssets.onArrival` calls `start`),
/// the next pass embeds it. The script models come from the store (`scriptEmbedder(for:)`).
@MainActor
enum VaultEmbeddingUpgrade {

    /// The model a vault should be on now. A seam: tests pass their own.
    static var target: () -> Embedder = { Embedder.fieldAssist() }
    /// Asks for the contextual model's asset; true when it's on the device afterwards.
    static var prepareAssets: () async -> Bool = { await Embedder.prepareFieldAssistAssets() }

    private static var running: Task<Void, Never>?
    private static var generation = 0

    /// Bring every installed vault onto the target model — at launch, when the setting changes,
    /// and when the model's asset arrives. A run already going is superseded: it stops at its next
    /// chunk, keeping what it built, and the new run carries on.
    static func start(store: DocumentStore, manifests: @escaping () -> [VaultManifest] = { VaultImporter.installedManifests() },
                      monitor: VaultIndexingMonitor? = nil) {
        let monitor = monitor ?? .shared
        generation += 1
        let mine = generation
        running = Task { @MainActor in
            await run(store: store, manifests: manifests(), monitor: monitor) { generation == mine }
            let choice = Config.fieldAssistManualSearchModel
            guard generation == mine, choice != .standard,
                  !target().version.modelId.hasPrefix(choice.modelIdPrefix) else { return }
            // Chosen but the model isn't here or loaded yet: ask for it, and re-index once it arrives.
            if await prepareAssets(), generation == mine {
                await run(store: store, manifests: manifests(), monitor: monitor) { generation == mine }
            }
        }
    }

    /// One pass over the vaults. Returns each vault's outcome, for the tests: the Latin index's
    /// under the vault's id, and another script's under `outcomeKey(vaultId:script:)`.
    @discardableResult
    static func run(store: DocumentStore, manifests: [VaultManifest], monitor: VaultIndexingMonitor,
                    shouldContinue: @escaping () -> Bool = { true }) async -> [String: DocumentStore.UpgradeOutcome] {
        let model = target()
        store.fieldAssistEmbedder = model
        var outcomes: [String: DocumentStore.UpgradeOutcome] = [:]
        for manifest in manifests where manifest.hasDocuments {
            let namespace = DocumentStore.vaultNamespace(manifest.id)
            guard store.documentCount(namespace: namespace) > 0, shouldContinue() else { continue }
            let scripts = store.embeddingScripts(namespace: namespace)
            // Latin first, exactly as before; then each other script whose model is here. A
            // script whose model is not is left by its words until the model lands.
            var targets: [(script: EmbeddingScript, model: Embedder)] = scripts.contains(.latin) ? [(.latin, model)] : []
            for script in scripts where script != .latin {
                if let scriptModel = store.scriptEmbedder(for: script) { targets.append((script, scriptModel)) }
            }
            for (script, target) in targets {
                guard shouldContinue() else { break }
                let key = outcomeKey(vaultId: manifest.id, script: script)
                let progress = store.upgradeProgress(namespace: namespace, script: script, targetTag: target.version.tag)
                guard progress.done < progress.total
                        || store.servingVersionTag(namespace: namespace, script: script) != target.version.tag else {
                    outcomes[key] = .current
                    continue
                }
                await VaultOperationLock.withLock(manifest.id) {
                    monitor.begin(vaultId: manifest.id, titles: manifest.documents.map(\.title))
                    let background = monitor.backgroundTasks.begin(name: "Indexing manuals")
                    defer {
                        monitor.backgroundTasks.end(background)
                        monitor.end(vaultId: manifest.id)
                    }
                    outcomes[key] = await store.upgradeVaultEmbeddings(
                        namespace: namespace, script: script, to: target,
                        progress: { title, done, total in
                            monitor.progress(vaultId: manifest.id, title: title, completed: done, total: total)
                        },
                        shouldContinue: shouldContinue)
                }
            }
        }
        return outcomes
    }

    /// The key a run's outcome for one vault's index under `script` is returned by: the vault's
    /// id for Latin, as before, and `id#script` for any other.
    nonisolated static func outcomeKey(vaultId: String, script: EmbeddingScript) -> String {
        script == .latin ? vaultId : "\(vaultId)#\(script.rawValue)"
    }
}
