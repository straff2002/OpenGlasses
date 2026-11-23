import Foundation
#if canImport(Metal)
import Metal
#endif

/// The live readings `LocalMemoryBudget` judges (Plan MQ H2, P3): the process's remaining
/// allocation and footprint, Metal's recommended working set and the nominal RAM.
///
/// The kill limit is fixed per process, so it is measured **once**, at first use
/// (`processKillLimit`), and every later reading is judged against that same number: a reading
/// taken after a model is resident would otherwise count the model's own pages twice over.
///
/// The shipping load path does not read this yet. It keeps `MemoryHeadroom.canLoad` and the
/// catalog's RAM floors, which `LocalModelAdmissionTests` pins against each other; switching a
/// gate that decides which models a customer may load is a change of its own, to be made from the
/// device qualification records this adapter feeds (the device app records peak footprint against
/// `processKillLimit`).
enum LocalMemoryReadings {

    /// Readings now.
    static func current() -> LocalMemoryBudget.Readings {
        LocalMemoryBudget.Readings(availableBytes: MemoryHeadroom.availableBytes(),
                                   footprintBytes: MemoryHeadroom.appFootprintBytes(),
                                   recommendedWorkingSetBytes: recommendedWorkingSetBytes,
                                   marketingRAMGB: LocalLLMService.marketingRAMGB)
    }

    /// The kill limit, measured at first use and fixed for the process. Nil on a platform with no
    /// per-process limit.
    static let processKillLimit: Int64? = LocalMemoryBudget.killLimit(current())

    /// Metal's `recommendedMaxWorkingSetSize` for the default device, or 0 when there is none.
    static let recommendedWorkingSetBytes: Int64 = {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return 0 }
        return Int64(clamping: device.recommendedMaxWorkingSetSize)
        #else
        return 0
        #endif
    }()

    /// Readings with `availableBytes` re-derived from the fixed kill limit and the footprint now,
    /// so a fit judged later in the process is judged against the same limit as the first.
    static func againstProcessLimit() -> LocalMemoryBudget.Readings {
        let now = current()
        guard let limit = processKillLimit else { return now }
        return LocalMemoryBudget.Readings(availableBytes: max(0, limit - now.footprintBytes),
                                          footprintBytes: now.footprintBytes,
                                          recommendedWorkingSetBytes: now.recommendedWorkingSetBytes,
                                          marketingRAMGB: now.marketingRAMGB)
    }
}
