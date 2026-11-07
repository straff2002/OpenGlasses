import Foundation

/// One value, remembered for the generation of its source it was read at.
///
/// The reader notes the source's generation before reading, stores what it read under that
/// generation, and gets it back only while the source is still at the same generation. Any write
/// to the source advances the generation, so a stale copy is never returned: at worst the next
/// read goes back to the source once more.
///
/// `Config.savedModels` uses it with `KeychainService.writeGeneration`. Without it every read of
/// the saved models, and so of the active model, was a Keychain query and a JSON decode; the home
/// grid asks for the active model once per tile per render, and on a loaded simulator that kept the
/// main thread busy enough to stall an accessibility audit for minutes.
final class GenerationCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (generation: UInt64, value: Value)?

    init() {}

    /// The value stored at `generation`, or nil if nothing is stored or it was stored at another.
    func value(at generation: UInt64) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.generation == generation else { return nil }
        return entry.value
    }

    /// Stores `value` as read at `generation`. A read that began before a later one finished is
    /// older, so it never replaces an entry stored at a newer generation.
    func store(_ value: Value, at generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let entry, entry.generation > generation { return }
        entry = (generation, value)
    }

    /// Forgets the stored value.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }
}
