import Foundation

/// The plain-words lines an install sheet shows for an add-on's permissions.
///
/// None is granted by default, and speaking needs none, so an add-on that asks for nothing shows
/// only the fixed line. Plain `String`s: this is the model; the sheet that shows it localises.
enum AddOnPermissionSummary {

    struct Line: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case network, location, memory, display
            // Reserved capabilities: only a signed add-on holds one, and only then are they shown.
            case credentials, parts, workRecord, office
            case never

            init(_ capability: AddOnReservedCapability) {
                switch capability {
                case .credentials: self = .credentials
                case .parts: self = .parts
                case .workRecord: self = .workRecord
                case .office: self = .office
                }
            }
        }
        let kind: Kind
        let text: String
    }

    /// Shown on every sheet: what no add-on can ever reach — these aren't permissions the format has.
    static let neverLine = "It can never reach your contacts, camera, health data, messages, calendar, photos or microphone."

    static func lines(for permissions: RecipeAddOnManifest.Permissions) -> [Line] {
        var lines: [Line] = []
        if !permissions.network.isEmpty {
            // Every domain, as the author wrote it (normalised when it parses).
            let domains = permissions.network.map { entry -> String in
                if case .success(let rule) = AddOnDomainRule.parse(entry) { return rule.display }
                return entry
            }
            var seen = Set<String>()
            let unique = domains.filter { seen.insert($0).inserted }
            lines.append(.init(kind: .network, text: "Connect to: \(unique.joined(separator: ", "))"))
        }
        if permissions.location {
            lines.append(.init(kind: .location, text: "Use your approximate location (about 1 km) when you ask it something"))
        }
        if permissions.memory {
            lines.append(.init(kind: .memory, text: "Save things to your memory. It can't read what's already there."))
        }
        if permissions.display {
            lines.append(.init(kind: .display, text: "Show cards on your phone, watch and glasses display"))
        }
        for capability in AddOnReservedCapability.allCases where permissions.reserved.contains(capability) {
            lines.append(.init(kind: .init(capability), text: capability.summaryText))
        }
        lines.append(.init(kind: .never, text: neverLine))
        return lines
    }
}
