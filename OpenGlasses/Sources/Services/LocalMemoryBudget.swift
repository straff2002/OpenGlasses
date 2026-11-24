import Foundation

/// Whether a downloaded model fits this process, judged against the point where iOS kills the app
/// (Plan MQ H2, P3). Pure: the readings are inputs, so every rule runs headlessly.
///
/// The RAM gates (`LocalLLMService.deviceMeetsRAMFloor`, the catalog's `minimumRAMGB`) use
/// physical memory rounded up to the number on the box. The point where iOS terminates the app is
/// lower, and it is fixed for the life of the process: `os_proc_available_memory()` plus the
/// footprint the process already holds (`phys_footprint`), taken at one moment. That sum is the
/// **kill limit**.
///
/// - A backend that copies its weights into memory (MLX) is judged against the kill limit: the
///   footprint already held, the weights, the working set and the reserve must fit under it. The
///   readings are taken with the model not resident (before a load), or its pages count twice.
/// - A backend that memory-maps its weights (GGUF) is judged against Metal's
///   `recommendedMaxWorkingSetSize`, the most the GPU will keep resident; mapped pages are
///   file-backed and do not count against the footprint the same way. The footprint held, its
///   working set and the reserve must still fit under the kill limit.
/// - A 6 GB phone keeps about 1 GB in reserve, because a Field Assist turn's KV cache keeps
///   growing over a job, and that growth is what tips a model that only just fits. Larger phones
///   keep `LocalModelBudget.admissionComfortMarginBytes` (512 MB), the margin the load admission
///   already flags below.
///
/// The device qualification app records peak footprint against the same `killLimit`, so the fit
/// rule and the evidence use one number. **Not wired into the shipping gates yet**: the app's load
/// path keeps `MemoryHeadroom.canLoad` and the RAM floors (see `LocalMemoryReadings` for why).
enum LocalMemoryBudget {

    /// One set of readings, taken together.
    struct Readings: Equatable, Sendable {
        /// `os_proc_available_memory()`: what the process may still allocate. 0 where the
        /// platform has no per-process limit (simulator, Mac).
        let availableBytes: Int64
        /// `phys_footprint` at the same moment.
        let footprintBytes: Int64
        /// Metal's `recommendedMaxWorkingSetSize`, or 0 when unknown.
        let recommendedWorkingSetBytes: Int64
        /// The device's nominal RAM in GB (`LocalLLMService.marketingRAMGB`).
        let marketingRAMGB: Double

        init(availableBytes: Int64, footprintBytes: Int64, recommendedWorkingSetBytes: Int64, marketingRAMGB: Double) {
            self.availableBytes = availableBytes
            self.footprintBytes = footprintBytes
            self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
            self.marketingRAMGB = marketingRAMGB
        }
    }

    /// How a backend holds its weights.
    enum Backing: String, Equatable, Sendable, Codable {
        /// Read into memory (MLX).
        case copied
        /// Memory-mapped from the file (GGUF).
        case mapped
    }

    /// Nominal RAM at or below which the larger reserve applies.
    static let smallPhoneRAMGB: Double = 6
    /// The reserve on a 6 GB phone.
    static let smallPhoneReserveBytes: Int64 = 1_024 * 1_024 * 1_024

    /// The kill limit, or nil where the platform reports no per-process limit.
    static func killLimit(_ readings: Readings) -> Int64? {
        guard readings.availableBytes > 0 else { return nil }
        return readings.availableBytes + max(0, readings.footprintBytes)
    }

    /// What this phone keeps free above a model's needs.
    static func reserveBytes(marketingRAMGB: Double) -> Int64 {
        marketingRAMGB > 0 && marketingRAMGB <= smallPhoneRAMGB
            ? smallPhoneReserveBytes
            : LocalModelBudget.admissionComfortMarginBytes
    }

    /// What a fit was judged against.
    enum Limit: String, Equatable, Sendable, Codable {
        case killLimit
        case metalWorkingSet
        /// No limit could be read: the fit is not judged (simulator, Mac).
        case unknown
    }

    struct Fit: Equatable, Sendable {
        let judgedAgainst: Limit
        /// The limit's value, 0 when unknown.
        let limitBytes: Int64
        /// What the model needs under that limit: the footprint already held (kill limit only),
        /// the weights (copied, or mapped against the GPU's working set), the working set and the
        /// reserve.
        let neededBytes: Int64
        let reserveBytes: Int64
        /// True when it fits, or when no limit could be read.
        let fits: Bool

        /// Limit minus need; negative when it does not fit. 0 when unknown.
        var spareBytes: Int64 { judgedAgainst == .unknown ? 0 : limitBytes - neededBytes }
    }

    /// Whether a model of `weightsBytes` (plus `workingBytes` while generating) fits.
    static func fit(weightsBytes: Int64, workingBytes: Int64, backing: Backing, readings: Readings) -> Fit {
        let reserve = reserveBytes(marketingRAMGB: readings.marketingRAMGB)
        let weights = max(0, weightsBytes)
        let working = max(0, workingBytes)
        let held = max(0, readings.footprintBytes)
        switch backing {
        case .copied:
            guard let limit = killLimit(readings) else {
                return Fit(judgedAgainst: .unknown, limitBytes: 0, neededBytes: weights + working + reserve,
                           reserveBytes: reserve, fits: true)
            }
            let needed = held + weights + working + reserve
            return Fit(judgedAgainst: .killLimit, limitBytes: limit, neededBytes: needed, reserveBytes: reserve,
                       fits: needed <= limit)
        case .mapped:
            // The working set and the reserve live in the footprint; the mapped weights in the
            // GPU's working set. Both must hold; the tighter one is reported.
            let footprintFit: Fit? = killLimit(readings).map { limit in
                let needed = held + working + reserve
                return Fit(judgedAgainst: .killLimit, limitBytes: limit, neededBytes: needed, reserveBytes: reserve,
                           fits: needed <= limit)
            }
            let gpuFit: Fit? = readings.recommendedWorkingSetBytes > 0 ? {
                let needed = weights + working + reserve
                return Fit(judgedAgainst: .metalWorkingSet, limitBytes: readings.recommendedWorkingSetBytes,
                           neededBytes: needed, reserveBytes: reserve,
                           fits: needed <= readings.recommendedWorkingSetBytes)
            }() : nil
            switch (footprintFit, gpuFit) {
            case let (f?, g?):
                if !f.fits { return f }
                if !g.fits { return g }
                return f.spareBytes <= g.spareBytes ? f : g
            case let (f?, nil): return f
            case let (nil, g?): return g
            case (nil, nil):
                return Fit(judgedAgainst: .unknown, limitBytes: 0, neededBytes: weights + working + reserve,
                           reserveBytes: reserve, fits: true)
            }
        }
    }

    /// The room a measured peak footprint left under the kill limit, for the qualification record:
    /// negative means the peak went past it (the process would have been killed, or nearly was).
    static func headroomAtPeak(peakFootprintBytes: Int64, killLimitBytes: Int64?) -> Int64? {
        killLimitBytes.map { $0 - max(0, peakFootprintBytes) }
    }
}
