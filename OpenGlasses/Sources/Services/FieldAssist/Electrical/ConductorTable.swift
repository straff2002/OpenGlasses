import Foundation
import os

/// The electrical trade's conductor reference data (Plan JJ decision 8): the standard AWG sizes
/// with their areas in circular mils, and each metal's factor in Ω·cmil/ft and Ω·mm²/m with the
/// temperature it is stated at. Bundled as `Resources/Electrical/conductors.json`, as the
/// refrigeration calculators carry their saturation tables (`SaturationTable`), and credited in
/// Attributions.
///
/// `voltage_drop` reads it only for a run given as a wire size or a metal; a resistance, factor or
/// area the technician gives wins over it, per quantity. A file that is missing or does not pass
/// `decode`'s checks is a refusal on that path, never a fallback to figures written in code.
///
/// Pure: `decode` parses and checks bytes; `ConductorTableCatalog.table` finds the bundled file.
struct ConductorTable: Decodable, Equatable, Sendable {

    struct Gauge: Decodable, Equatable, Sendable {
        /// "14", "1/0".
        let size: String
        let circularMils: Double
    }

    /// A factor and the conductor temperature it is stated at.
    struct Factor: Decodable, Equatable, Sendable {
        let value: Double
        let temperatureC: Double
    }

    struct Metal: Decodable, Equatable, Sendable {
        /// "copper" or "aluminum", `VoltageDrop.Material`'s raw value.
        let material: String
        let ohmCircularMilsPerFoot: Factor
        let ohmSquareMillimetresPerMetre: Factor
    }

    /// Smallest to largest, as the sizes are said back in a refusal.
    let awg: [Gauge]
    let materials: [Metal]
    /// The short line an answer carries: "standard AWG conductor areas and …".
    let source: String
    /// How each figure was arrived at, for whoever audits the file.
    let basis: String

    /// The size the file names `size` ("14", "1/0"), ignoring case.
    func gauge(named size: String) -> Gauge? { awg.first { $0.size.lowercased() == size.lowercased() } }

    /// The metal's factor in the unit, or nil when the file does not carry it.
    func factor(for material: VoltageDrop.Material, unit: VoltageDrop.FactorUnit) -> Factor? {
        guard let metal = materials.first(where: { $0.material == material.rawValue }) else { return nil }
        return unit == .ohmCircularMilsPerFoot ? metal.ohmCircularMilsPerFoot : metal.ohmSquareMillimetresPerMetre
    }

    enum Problem: Error, Equatable {
        case noSizes
        case badSize(String)
        case missingMaterial(String)
        case badFactor(String)
        case noSource
    }

    /// Decode and check: at least one size, every size named once with an area above zero, both
    /// metals with both factors above zero at a stated temperature, and a source to name.
    static func decode(_ data: Data) throws -> ConductorTable {
        let table = try JSONDecoder().decode(ConductorTable.self, from: data)
        guard !table.awg.isEmpty else { throw Problem.noSizes }
        var seen = Set<String>()
        for gauge in table.awg {
            guard !gauge.size.isEmpty, seen.insert(gauge.size).inserted,
                  gauge.circularMils.isFinite, gauge.circularMils > 0 else { throw Problem.badSize(gauge.size) }
        }
        for material in [VoltageDrop.Material.copper, .aluminum] {
            guard table.materials.contains(where: { $0.material == material.rawValue }) else {
                throw Problem.missingMaterial(material.rawValue)
            }
            for unit in [VoltageDrop.FactorUnit.ohmCircularMilsPerFoot, .ohmSquareMillimetresPerMetre] {
                guard let factor = table.factor(for: material, unit: unit), factor.value.isFinite, factor.value > 0,
                      factor.temperatureC.isFinite else { throw Problem.badFactor("\(material.rawValue) \(unit.rawValue)") }
            }
        }
        guard !table.source.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem.noSource }
        return table
    }
}

/// The bundled conductor file, loaded once per bundle.
enum ConductorTableCatalog {

    /// `conductors.json`, from `Resources/Electrical/`.
    static let resourceName = "conductors"

    private static let cache = OSAllocatedUnfairLock<[String: ConductorTable]>(initialState: [:])

    /// The bundle's conductor file, or nil when it is missing or malformed. Only a good file is
    /// kept, so a bundle without one is looked at again rather than remembered as empty.
    static func table(bundle: Bundle = .main) -> ConductorTable? {
        let key = bundle.bundleURL.path
        if let cached = cache.withLock({ $0[key] }) { return cached }
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? ConductorTable.decode(data) else { return nil }
        cache.withLock { $0[key] = table }
        return table
    }
}
