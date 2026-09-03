import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Ed25519 device identity for OpenClaw gateway handshakes (protocol v3/v4).
///
/// The signed payload is the gateway's `buildDeviceAuthPayloadV3` layout, byte for byte —
/// pinned by `OpenClawDeviceIdentityTests`.
///
/// Remote gateways grant scopes based on a signed device identity presented with the `connect`
/// request: the client signs the gateway's `connect.challenge` nonce (plus the connect metadata)
/// with a per-device Ed25519 key. A token-only connect still authenticates but can be granted
/// zero scopes on newer gateways, leaving the socket deaf for chat/invoke. The private key is
/// generated once and kept in the Keychain; the device id is the SHA-256 of the public key.
enum OpenClawDeviceIdentity {

    private static let privateKeyKeychainKey = "openClawDeviceEd25519PrivateKey"

    struct Identity {
        let deviceId: String
        let publicKeyBase64URL: String
        let privateKey: Curve25519.Signing.PrivateKey

        init(privateKey: Curve25519.Signing.PrivateKey) {
            let rawPublic = privateKey.publicKey.rawRepresentation
            self.privateKey = privateKey
            self.deviceId = OpenClawDeviceIdentity.sha256Hex(rawPublic)
            self.publicKeyBase64URL = OpenClawDeviceIdentity.base64URLEncode(rawPublic)
        }
    }

    /// Load the stored device key, or mint and persist a new one.
    static func loadOrCreate() -> Identity {
        if let stored = KeychainService.data(for: privateKeyKeychainKey),
           stored.count == 32,
           let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored) {
            return Identity(privateKey: privateKey)
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        _ = KeychainService.setData(privateKey.rawRepresentation, for: privateKeyKeychainKey)
        return Identity(privateKey: privateKey)
    }

    /// Build the `device` object for a `connect` request. `clientId`/`clientMode`/`role`/`scopes`
    /// MUST match what the connect frame itself carries — the gateway verifies the signature over
    /// exactly these values.
    ///
    /// The identity/time-injected form is deterministic for tests; the convenience overload uses
    /// the stored identity and the current clock.
    static func connectDevice(
        identity: Identity,
        token: String,
        nonce: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int,
        platform: String = GatewayWire.platform,
        deviceFamily: String? = nil
    ) -> [String: Any]? {
        let payload = signedPayloadV3(
            deviceId: identity.deviceId,
            clientId: clientId,
            clientMode: clientMode,
            role: role,
            scopes: scopes,
            signedAtMs: signedAtMs,
            token: token,
            nonce: nonce,
            platform: platform,
            deviceFamily: deviceFamily
        )
        guard let signature = try? identity.privateKey.signature(for: Data(payload.utf8)) else {
            return nil
        }
        return [
            "id": identity.deviceId,
            "publicKey": identity.publicKeyBase64URL,
            "signature": base64URLEncode(signature),
            "signedAt": signedAtMs,
            "nonce": nonce,
        ]
    }

    static func connectDevice(
        token: String,
        nonce: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String]
    ) -> [String: Any]? {
        connectDevice(
            identity: loadOrCreate(),
            token: token,
            nonce: nonce,
            clientId: clientId,
            clientMode: clientMode,
            role: role,
            scopes: scopes,
            signedAtMs: Int(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// The exact string the signature covers (gateway "v3" payload format) — exposed for tests.
    static func signedPayloadV3(
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int,
        token: String,
        nonce: String,
        platform: String = GatewayWire.platform,
        deviceFamily: String? = nil
    ) -> String {
        [
            "v3",
            deviceId,
            clientId,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token,
            nonce,
            normalizeMetadata(platform),
            normalizeMetadata(deviceFamily ?? deviceFamilyLabel()),
        ].joined(separator: "|")
    }

    // MARK: - Helpers

    private static func normalizeMetadata(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The device family the connect frame carries as `client.deviceFamily`. The gateway rebuilds
    /// the v3 signature payload from that field, so the frame and the signer must agree — which is
    /// why this is the one source both read.
    static func deviceFamilyLabel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #else
        return "iphone"
        #endif
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
