import Foundation

/// Pure builder for the `connect` request params both gateway sockets send (the chat socket in
/// `OpenClawBridge` and the event/invoke socket in `OpenClawEventClient`). One builder so the
/// two handshakes can't drift — critical because the device-identity signature covers the
/// clientId/mode/role/scopes carried in the frame, and a mismatch means a closed socket.
///
/// Wire notes (verified against the gateway's `ConnectParamsSchema`, a closed object):
/// - Operator clients must speak exactly protocol 4; node clients get a 3–4 window.
/// - `client.deviceFamily` is part of the v3 signature payload the gateway rebuilds from the
///   frame, so it is always sent and always the same value the signer normalised.
/// - `device` (present only when the gateway issued a `connect.challenge`) is the signed Ed25519
///   identity block, signed at the challenge's own `ts` so gateway clock skew cannot stale it.
/// - There is no free-form capability key; node command advertisement is `commands` and client
///   capability flags are `caps`, both only meaningful for the role that declares them.
enum OpenClawConnectParams {

    static func build(
        clientId: String = GatewayWire.clientId,
        displayName: String,
        version: String,
        token: String,
        role: GatewayWire.Role = .operator,
        scopes: [String]? = nil,
        caps: [String] = [],
        commands: [String] = [],
        challenge: GatewayChallenge?,
        pairedDeviceId: String? = nil,
        localeIdentifier: String = Locale.current.identifier,
        identity: OpenClawDeviceIdentity.Identity? = nil,
        signedAtMs: Int? = nil
    ) -> [String: Any] {
        let deviceFamily = OpenClawDeviceIdentity.deviceFamilyLabel()
        var client: [String: Any] = [
            "id": clientId,
            "displayName": displayName,
            "version": version,
            "platform": GatewayWire.platform,
            "deviceFamily": deviceFamily,
            "mode": GatewayWire.clientMode,
        ]
        if let pairedDeviceId, !pairedDeviceId.isEmpty {
            client["instanceId"] = pairedDeviceId
        }

        let window = role.protocolWindow
        let effectiveScopes = scopes ?? role.defaultScopes
        var params: [String: Any] = [
            "minProtocol": window.min,
            "maxProtocol": window.max,
            "role": role.rawValue,
            "scopes": effectiveScopes,
            "client": client,
            "locale": localeIdentifier,
            "userAgent": "openglasses-ios/\(version)",
            "auth": ["token": token],
        ]
        if !caps.isEmpty { params["caps"] = caps }
        if !commands.isEmpty { params["commands"] = commands }

        if let challenge {
            let signingIdentity = identity ?? OpenClawDeviceIdentity.loadOrCreate()
            let timestamp = signedAtMs ?? challenge.timestampMs ?? Int(Date().timeIntervalSince1970 * 1000)
            if let device = OpenClawDeviceIdentity.connectDevice(
                identity: signingIdentity,
                token: token,
                nonce: challenge.nonce,
                clientId: clientId,
                clientMode: GatewayWire.clientMode,
                role: role.rawValue,
                scopes: effectiveScopes,
                signedAtMs: timestamp,
                platform: GatewayWire.platform,
                deviceFamily: deviceFamily
            ) {
                params["device"] = device
            }
        }
        return params
    }
}
