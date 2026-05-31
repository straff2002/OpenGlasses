import Foundation

/// IP subnet / CIDR math for the IT/Network Field Assist pack (Plan G). Pure computation — no vault
/// dependency — so it works any time. Supports IPv4 (network/broadcast/usable range) and IPv6
/// (network prefix + address count).
@MainActor
final class NetworkCalcTool: NativeTool {
    let name = "network_calc"
    let description = """
    Network math for IT field work. Operation 'subnet': given an IPv4 or IPv6 CIDR (e.g. \
    '192.168.1.42/26' or '2001:db8::/48'), returns the network address, broadcast (IPv4), usable \
    host range and count, and mask. Use for subnetting, "what's the broadcast/usable range", or \
    sizing a subnet.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "operation": ["type": "string", "description": "'subnet' (default)."],
            "cidr": ["type": "string", "description": "CIDR notation, e.g. '10.0.0.0/24' or '2001:db8::/48'."]
        ],
        "required": ["cidr"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard let cidr = (args["cidr"] as? String)?.trimmingCharacters(in: .whitespaces), !cidr.isEmpty else {
            return "Specify a 'cidr', e.g. '192.168.1.0/24'."
        }
        if cidr.contains(":") {
            guard let info = Self.subnetIPv6(cidr) else { return "Couldn't parse IPv6 CIDR '\(cidr)'." }
            return "IPv6 \(cidr):\n- Network prefix: \(info.prefix)\n- Prefix length: /\(info.prefixLength)\n- Addresses: \(info.addressCount)"
        }
        guard let info = Self.subnetIPv4(cidr) else {
            return "Couldn't parse IPv4 CIDR '\(cidr)'. Use a.b.c.d/prefix."
        }
        return """
        IPv4 \(cidr):
        - Network: \(info.network)
        - Broadcast: \(info.broadcast)
        - Netmask: \(info.netmask)
        - Usable range: \(info.usableRange)
        - Usable hosts: \(info.usableHosts)
        """
    }

    // MARK: - IPv4

    struct IPv4Subnet: Equatable {
        let network: String
        let broadcast: String
        let netmask: String
        let usableRange: String
        let usableHosts: String
    }

    nonisolated static func subnetIPv4(_ cidr: String) -> IPv4Subnet? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix),
              let ip = parseIPv4(String(parts[0])) else { return nil }

        let mask: UInt32 = prefix == 0 ? 0 : (0xFFFF_FFFF << (32 - prefix)) & 0xFFFF_FFFF
        let network = ip & mask
        let broadcast = network | ~mask

        let usableHosts: String
        let usableRange: String
        switch prefix {
        case 32:
            usableHosts = "1 (host route)"
            usableRange = formatIPv4(network)
        case 31:
            usableHosts = "2 (point-to-point, RFC 3021)"
            usableRange = "\(formatIPv4(network)) – \(formatIPv4(broadcast))"
        default:
            let count = (UInt64(1) << (32 - prefix)) - 2
            usableHosts = "\(count)"
            usableRange = "\(formatIPv4(network &+ 1)) – \(formatIPv4(broadcast &- 1))"
        }

        return IPv4Subnet(
            network: formatIPv4(network),
            broadcast: formatIPv4(broadcast),
            netmask: formatIPv4(mask),
            usableRange: usableRange,
            usableHosts: usableHosts
        )
    }

    nonisolated static func parseIPv4(_ s: String) -> UInt32? {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var result: UInt32 = 0
        for octet in octets {
            guard let value = UInt32(octet), value <= 255 else { return nil }
            result = (result << 8) | value
        }
        return result
    }

    nonisolated static func formatIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    // MARK: - IPv6

    struct IPv6Subnet: Equatable {
        let prefix: String
        let prefixLength: Int
        let addressCount: String
    }

    nonisolated static func subnetIPv6(_ cidr: String) -> IPv6Subnet? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefixLen = Int(parts[1]), (0...128).contains(prefixLen) else { return nil }
        // Validate the address portion parses; keep the user's notation for display.
        var addr = in6_addr()
        guard String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }

        let hostBits = 128 - prefixLen
        let count: String
        if hostBits == 0 { count = "1" }
        else if hostBits <= 63 { count = "\(UInt64(1) << hostBits)" }
        else { count = "2^\(hostBits)" } // too large for UInt64
        return IPv6Subnet(prefix: String(parts[0]), prefixLength: prefixLen, addressCount: count)
    }
}
