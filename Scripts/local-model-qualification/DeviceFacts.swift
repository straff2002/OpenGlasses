import Foundation
import UIKit

/// The facts a qualification record names about where it ran, and the phone's readings the run
/// gate decides on. Counts and identifiers only.
enum DeviceFacts {

    /// The mlx-swift-lm revision this app is built against: the app's own pin (`project.base.yml`).
    /// `LocalModelQualificationFixtureTests` fails when they differ.
    static let mlxSwiftLMRevision = "4c21c84ba239583d6448dc38bbc9001e2df714a6"

    /// `hw.machine`, e.g. `iPhone17,3`.
    static var machine: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    /// `kern.osversion`, the OS build, e.g. `24B113`.
    static var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static var device: LocalModelQualificationRecord.Device {
        .init(model: machine, osVersion: osVersion, osBuild: osBuild,
              marketingRAMGB: LocalLLMService.marketingRAMGB,
              physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory))
    }

    static var app: LocalModelQualificationRecord.App {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = (info["AvenkinSourceCommit"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        return .init(commit: commit, version: info["CFBundleShortVersionString"] as? String,
                     build: info["CFBundleVersion"] as? String)
    }

    /// The commit a downloaded MLX snapshot holds: the hub cache's `refs/main` under the production
    /// downloader's directory (`LocalLLMService`'s `Application Support/LocalModels`).
    static func downloadedRevision(modelID: String) -> String? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let repo = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let ref = support.appendingPathComponent("LocalModels/\(repo)/refs/main")
        let sha = (try? String(contentsOf: ref, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sha, sha.count == 40, sha.allSatisfy(\.isHexDigit) else { return nil }
        return sha
    }

    // MARK: - The gate's reading

    @MainActor
    static func gateReading(at time: TimeInterval) -> QualificationRunGate.Reading {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let thermal: QualificationRunGate.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .critical
        }
        let power: QualificationRunGate.Power
        switch device.batteryState {
        case .charging: power = .charging
        case .full: power = .full
        case .unplugged: power = .unplugged
        case .unknown: power = .unknown
        @unknown default: power = .unknown
        }
        let level = device.batteryLevel
        return .init(time: time, thermal: thermal, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                     batteryLevel: level >= 0 ? Double(level) : nil, power: power)
    }
}
