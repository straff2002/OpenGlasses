import XCTest
import CryptoKit
@testable import OpenGlasses

/// The shared connect-params builder both gateway sockets use — one builder so the handshakes
/// can't drift from what the device-identity signature covers.
final class OpenClawConnectParamsTests: XCTestCase {

    private func build(challenge: GatewayChallenge? = nil, pairedDeviceId: String? = nil,
                       role: GatewayWire.Role = .operator,
                       identity: OpenClawDeviceIdentity.Identity? = nil,
                       signedAtMs: Int? = nil) -> [String: Any] {
        OpenClawConnectParams.build(
            displayName: "OpenGlasses",
            version: "1.0",
            token: "tok",
            role: role,
            challenge: challenge,
            pairedDeviceId: pairedDeviceId,
            localeIdentifier: "en_US",
            identity: identity,
            signedAtMs: signedAtMs
        )
    }

    func testOperatorParamsSpeakProtocolFourWithRoleAndScopes() {
        let params = build()
        XCTAssertEqual(params["minProtocol"] as? Int, 4, "operator clients must speak exactly the current wire version")
        XCTAssertEqual(params["maxProtocol"] as? Int, 4)
        XCTAssertEqual(params["role"] as? String, "operator")
        XCTAssertEqual(params["scopes"] as? [String], ["operator.read", "operator.write"])
        XCTAssertEqual(params["locale"] as? String, "en_US")
        XCTAssertEqual(params["userAgent"] as? String, "openglasses-ios/1.0")
        XCTAssertEqual((params["auth"] as? [String: String])?["token"], "tok")
        XCTAssertNil(params["deviceCapabilities"], "no free-form keys: the schema is closed")
        XCTAssertNil(params["caps"], "empty caps are omitted rather than sent as []")
        XCTAssertNil(params["commands"])
        let client = params["client"] as? [String: Any]
        XCTAssertEqual(client?["id"] as? String, "gateway-client")
        XCTAssertEqual(client?["mode"] as? String, "node")
        XCTAssertEqual(client?["platform"] as? String, "ios")
        XCTAssertEqual(client?["deviceFamily"] as? String, OpenClawDeviceIdentity.deviceFamilyLabel(),
                       "the gateway rebuilds the signature payload from this field")
        XCTAssertNil(client?["instanceId"], "no paired device id → none advertised")
        XCTAssertNil(client?["deviceId"], "not a client-block key")
    }

    func testNodeRoleGetsTheLegacyWindowAndNoOperatorScopes() {
        let params = build(role: .node)
        XCTAssertEqual(params["minProtocol"] as? Int, 3)
        XCTAssertEqual(params["maxProtocol"] as? Int, 4)
        XCTAssertEqual(params["role"] as? String, "node")
        XCTAssertEqual(params["scopes"] as? [String], [])
    }

    func testCapsAndCommandsAreCarriedWhenDeclared() {
        let params = OpenClawConnectParams.build(
            displayName: "OpenGlasses", version: "1.0", token: "tok", role: .node,
            caps: ["talk"], commands: ["camera.snap", "system.notify"], challenge: nil)
        XCTAssertEqual(params["caps"] as? [String], ["talk"])
        XCTAssertEqual(params["commands"] as? [String], ["camera.snap", "system.notify"])
    }

    func testNoChallengeMeansNoDeviceBlock() {
        XCTAssertNil(build()["device"], "unchallenged connects stay token-only")
    }

    func testPairedDeviceIdIsCarriedAsTheClientInstanceId() {
        let client = build(pairedDeviceId: "paired-123")["client"] as? [String: Any]
        XCTAssertEqual(client?["instanceId"] as? String, "paired-123")
    }

    func testSignedAtIsTheChallengeTimestampNotTheClientClock() throws {
        let identity = OpenClawDeviceIdentity.Identity(privateKey: Curve25519.Signing.PrivateKey())
        let params = build(challenge: GatewayChallenge(nonce: "n0nce", timestampMs: 1_737_264_000_000), identity: identity)
        let device = try XCTUnwrap(params["device"] as? [String: Any])
        XCTAssertEqual(device["signedAt"] as? Int, 1_737_264_000_000,
                       "the gateway checks signedAt against ITS clock; the challenge ts is the only skew-proof value")
        XCTAssertEqual(Set(device.keys), ["id", "publicKey", "signature", "signedAt", "nonce"])
    }

    func testChallengeWithoutTimestampFallsBackToAnInjectedClock() throws {
        let identity = OpenClawDeviceIdentity.Identity(privateKey: Curve25519.Signing.PrivateKey())
        let params = build(challenge: GatewayChallenge(nonce: "n0nce", timestampMs: nil), identity: identity, signedAtMs: 42_000)
        XCTAssertEqual((params["device"] as? [String: Any])?["signedAt"] as? Int, 42_000)
    }

    func testChallengedConnectCarriesAVerifiableDeviceIdentity() throws {
        let identity = OpenClawDeviceIdentity.Identity(privateKey: Curve25519.Signing.PrivateKey())
        let params = build(challenge: GatewayChallenge(nonce: "n0nce", timestampMs: 42_000), identity: identity)
        let device = try XCTUnwrap(params["device"] as? [String: Any])
        let client = try XCTUnwrap(params["client"] as? [String: Any])
        XCTAssertEqual(device["id"] as? String, identity.deviceId)
        XCTAssertEqual(device["nonce"] as? String, "n0nce")

        // The signature must cover the SAME clientId/mode/role/scopes/platform/deviceFamily the
        // frame carries — the gateway rebuilds this exact v3 payload from the frame and verifies.
        let payload = OpenClawDeviceIdentity.signedPayloadV3(
            deviceId: identity.deviceId,
            clientId: client["id"] as? String ?? "",
            clientMode: client["mode"] as? String ?? "",
            role: params["role"] as? String ?? "",
            scopes: params["scopes"] as? [String] ?? [],
            signedAtMs: device["signedAt"] as? Int ?? 0,
            token: "tok",
            nonce: "n0nce",
            platform: client["platform"] as? String ?? "",
            deviceFamily: client["deviceFamily"] as? String ?? "")
        var b64 = try XCTUnwrap(device["signature"] as? String)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let signature = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertTrue(identity.privateKey.publicKey.isValidSignature(signature, for: Data(payload.utf8)))
    }

    func testEveryAdvertisedCapabilityRoundTripsThroughTheParser() {
        XCTAssertEqual(RemoteGlassesCommand.allCanonicalActions.count, 17)
        for action in RemoteGlassesCommand.allCanonicalActions {
            let frame: [String: Any] = [
                "type": "req", "id": "x", "method": "node.invoke",
                "params": ["action": action, "text": "t", "source": "de", "target": "en"] as [String: Any],
            ]
            guard case .command(let command)? = RemoteCommandParser.parse(frame)?.outcome else {
                return XCTFail("advertised capability '\(action)' is not parseable")
            }
            XCTAssertEqual(command.canonicalAction, action,
                           "advertised name must be the canonical name the parser produces")
        }
    }
}
