import Combine
import ExternalAccessory
import Foundation
import SwiftUI
import UIKit

/// A deliberately plain hardware probe for the RV101 command path.
///
/// Nothing here is product code. It exists to answer three questions that no capture can
/// answer on its own, because every capture we have starts after the session was already
/// established:
///
/// 1. Does iOS surface the accessory at all, and under which protocol string?
/// 2. Does the glasses' host expect a framed iAP2 packet or the bare Caps blob?
/// 3. What session id (frame bytes 9-10) does a fresh connection use?
///
/// Every byte written and read is logged in hex so a failed probe is still evidence.
@MainActor
final class RokidDiagnosticsModel: ObservableObject {
    @Published private(set) var accessoryLines: [String] = []
    @Published private(set) var entries: [String] = []
    @Published private(set) var isConnected = false
    @Published private(set) var bytesIn = 0
    @Published private(set) var bytesOut = 0
    @Published private(set) var sequence: UInt32 = 1

    /// Which payload policy the transport applies. `.framed` writes `ff 5a …`; `.rawCaps`
    /// writes only the Caps blob inside it.
    @Published var useRawCaps = false
    @Published var sessionIDText = "1"
    @Published var rawHexText = ""
    @Published var channel = "Dev"
    @Published var method = "Dev_GetGlassInfo"
    @Published var payloadText = ""

    private var transport: RokidMFITransport?
    private let clock = DispatchTime.now()
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var framing: RokidMFIFraming { useRawCaps ? .rawCaps : .framed }

    var framingName: String { useRawCaps ? "rawCaps" : "framed" }

    var sessionID: UInt16 {
        let trimmed = sessionIDText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x") {
            return UInt16(trimmed.dropFirst(2), radix: 16) ?? 0x0001
        }
        return UInt16(trimmed) ?? 0x0001
    }

    // MARK: - Accessories

    func refreshAccessories() {
        var lines: [String] = []
        let accessories = EAAccessoryManager.shared().connectedAccessories
        lines.append("\(accessories.count) EAAccessory object(s) visible to this app")

        if accessories.isEmpty {
            lines.append("Nothing connected. Check, in order: glasses powered on and paired in")
            lines.append("Settings > Bluetooth; Rokid's own app force-quit; the MFi protocol")
            lines.append("strings declared in Info.plist under UISupportedExternalAccessoryProtocols.")
        }

        for accessory in accessories {
            let advertised = accessory.protocolStrings.sorted()
            let matched = RokidMFITransport.matchingProtocols(for: accessory)
            lines.append("• \(accessory.name)")
            lines.append("    serial \(accessory.serialNumber)  fw \(accessory.firmwareRevision)  hw \(accessory.hardwareRevision)")
            lines.append("    manufacturer \(accessory.manufacturer)  model \(accessory.modelNumber)")
            lines.append("    advertises [\(advertised.joined(separator: ", "))]")
            lines.append(matched.isEmpty
                         ? "    ✗ no Rokid protocol advertised — EASession cannot be opened"
                         : "    ✓ matches \(matched.joined(separator: ", "))")
        }

        accessoryLines = lines
        append("refreshed: \(accessories.count) accessory object(s)")
    }

    // MARK: - Session

    func toggleConnection() async {
        if isConnected {
            transport?.disconnect()
            transport = nil
            isConnected = false
            append("disconnected by operator")
            return
        }
        await connect()
    }

    private func connect() async {
        let transport = RokidMFITransport()
        transport.framing = framing

        // The transport calls these from the stream thread, so hop back before touching UI.
        transport.onEvent = { [weak self] bytes in
            Task { @MainActor in self?.handleInbound(bytes) }
        }
        transport.onDisconnect = { [weak self] error in
            Task { @MainActor in
                self?.isConnected = false
                let reason = error.map { String(describing: $0) } ?? "closed by the accessory"
                self?.append("disconnected: \(reason)")
            }
        }

        self.transport = transport
        append("opening EASession with framing \(framingName), session id \(hex4(sessionID))")

        do {
            try await transport.connect()
            isConnected = transport.isConnected
            append(isConnected ? "EASession open" : "connect() returned without a session")
        } catch {
            isConnected = false
            append("connect failed: \(String(describing: error))")
        }
    }

    // MARK: - Commands

    /// The safest first command: a status read the glasses answer without changing state.
    func probe(_ wanted: RokidMFIFraming) async {
        guard let transport, isConnected else {
            append("not connected — probe skipped")
            return
        }
        let previous = transport.framing
        transport.framing = wanted
        append("--- probing with \(wanted == .rawCaps ? "rawCaps" : "framed") ---")
        await send(channel: "Dev", method: "Dev_GetGlassInfo", payload: nil, framing: wanted)
        transport.framing = previous
        append("--- probe finished; watching for a reply ---")
    }

    func sendComposedCommand() async {
        let trimmedPayload = payloadText.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: RokidCapsValue? = trimmedPayload.isEmpty ? nil : guessPayload(trimmedPayload)
        await send(channel: channel, method: method, payload: payload, framing: framing)
    }

    func sendRawHex() async {
        guard let transport, isConnected else {
            append("not connected — raw send skipped")
            return
        }
        guard let bytes = parseHex(rawHexText), !bytes.isEmpty else {
            append("raw hex: nothing usable to send")
            return
        }
        append("TX raw \(bytes.count) B: \(hex(bytes))")
        do {
            try await transport.send(bytes)
            bytesOut += bytes.count
            append("TX raw ok")
        } catch {
            append("TX raw failed: \(String(describing: error))")
        }
    }

    private func send(channel: String, method: String, payload: RokidCapsValue?, framing: RokidMFIFraming) async {
        guard let transport, isConnected else {
            append("not connected — send skipped")
            return
        }

        let frame = RokidIAP2Packet.encodeCommand(
            sequence: sequence,
            channel: channel,
            method: method,
            payload: payload,
            timestampMicroseconds: elapsedMicroseconds(),
            sessionID: sessionID
        )
        let wire = RokidMFIPayload.payload(for: frame, framing: framing)
        append("TX \(framing == .rawCaps ? "rawCaps" : "framed") \(frame.count) B frame, \(wire.count) B on the wire: \(hex(frame))")

        do {
            try await transport.send(frame)
            bytesOut += wire.count
            sequence &+= 1
            append("TX ok, next seq \(sequence)")
        } catch {
            append("TX failed: \(String(describing: error))")
        }
    }

    // MARK: - Inbound

    private func handleInbound(_ bytes: [UInt8]) {
        bytesIn += bytes.count
        append("RX \(bytes.count) B: \(hex(bytes))")

        guard let frame = RokidIAP2Packet.decode(bytes) else {
            append("RX: not a decodable iAP2 frame (bad sync, length or checksum)")
            return
        }

        let seq = frame.sequence.map(String.init) ?? "none"
        append("RX frame route \(hex4(UInt16(truncatingIfNeeded: frame.route))) seq \(seq) ts \(frame.timestampMicroseconds) session \(hex4(frame.sessionID))")
        append("RX tags \(frame.caps.map { String($0.typeTag) }.joined())")

        if let message = RokidCapsMessage.decode(bytes) {
            append("RX message method \(message.method) channel \(message.channel ?? "-") payload \(message.textPayload ?? "-")")
        }
        if let transfer = RokidMediaTransfer.decode(bytes) {
            append("RX media chunk \(transfer.data.count) B")
        }
    }

    // MARK: - Log

    func append(_ line: String) {
        entries.insert("\(Self.clockFormatter.string(from: Date()))  \(line)", at: 0)
        if entries.count > 400 {
            entries.removeLast(entries.count - 400)
        }
    }

    func clearLog() {
        entries.removeAll()
        bytesIn = 0
        bytesOut = 0
    }

    var logText: String {
        entries.reversed().joined(separator: "\n")
    }

    // MARK: - Helpers

    private func elapsedMicroseconds() -> UInt32 {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- clock.uptimeNanoseconds
        return UInt32(truncatingIfNeeded: elapsed / 1_000)
    }

    /// JSON object, bare integer, or plain text — whichever the typed payload most resembles.
    private func guessPayload(_ text: String) -> RokidCapsValue {
        if text.hasPrefix("{") || text.hasPrefix("[") { return .string(text) }
        if let value = Int32(text) { return .int32(value) }
        if let value = UInt32(text) { return .uint32(value) }
        return .string(text)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func hex4(_ value: UInt16) -> String {
        String(format: "0x%04x", value)
    }

    private func parseHex(_ text: String) -> [UInt8]? {
        let digits = text.filter { $0.isHexDigit }
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// Drop this in wherever you want a hardware probe; it has no dependencies beyond the
/// transport and the codec, so it can be deleted again without touching anything else.
struct RokidDiagnosticsView: View {
    @StateObject private var model = RokidDiagnosticsModel()

    var body: some View {
        NavigationStack {
            List {
                accessoriesSection
                sessionSection
                commandSection
                rawSection
                logSection
            }
            .navigationTitle("Rokid probe")
            .navigationBarTitleDisplayMode(.inline)
            .task { model.refreshAccessories() }
        }
    }

    private var accessoriesSection: some View {
        Section("Accessories") {
            ForEach(model.accessoryLines.indices, id: \.self) { index in
                Text(model.accessoryLines[index])
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button("Refresh accessory list") { model.refreshAccessories() }
        }
    }

    private var sessionSection: some View {
        Section("Session") {
            Toggle("Write raw Caps instead of a framed packet", isOn: $model.useRawCaps)
            HStack {
                Text("Session id")
                Spacer()
                TextField("1", text: $model.sessionIDText)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Text("Captures show 1 on one connection and 8 on another; the allocation rule is unknown. Try both.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Text("Sequence")
                Spacer()
                Text("\(model.sequence)")
                    .font(.system(.caption, design: .monospaced))
            }
            Button(model.isConnected ? "Disconnect" : "Open EASession") {
                Task { await model.toggleConnection() }
            }
            HStack {
                Text("Received").font(.caption)
                Spacer()
                Text("\(model.bytesIn) B in, \(model.bytesOut) B out")
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private var commandSection: some View {
        Section("Commands") {
            Button("Probe as framed") {
                Task { await model.probe(.framed) }
            }
            Button("Probe as rawCaps") {
                Task { await model.probe(.rawCaps) }
            }
            Text("Each probe sends Dev_GetGlassInfo, which is a read: the glasses answer with a device descriptor and change nothing. Run one, then the other, and see which produces a reply.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Channel", text: $model.channel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Method", text: $model.method)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Payload (JSON, number, or empty)", text: $model.payloadText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send composed command") {
                Task { await model.sendComposedCommand() }
            }
        }
    }

    private var rawSection: some View {
        Section("Raw bytes") {
            TextField("hex, e.g. ff5a0032…", text: $model.rawHexText, axis: .vertical)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send raw bytes through the transport") {
                Task { await model.sendRawHex() }
            }
            Text("Goes through the same framing policy, so it is not a bypass.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        Section("Log (\(model.entries.count))") {
            HStack {
                Button("Clear") { model.clearLog() }
                Spacer()
                Button("Copy") { UIPasteboard.general.string = model.logText }
            }
            if model.entries.isEmpty {
                Text("Nothing yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.entries.indices, id: \.self) { index in
                Text(model.entries[index])
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}
