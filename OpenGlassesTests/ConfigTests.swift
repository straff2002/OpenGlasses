import XCTest
@testable import OpenGlasses

final class ConfigTests: XCTestCase {

    // Keys used by Config that we need to clean up
    private let testKeys = [
        "appMode",
        "openClawEnabled",
        "openClawConnectionMode",
        "openClawLanHost",
        "openClawPort",
        "openClawTunnelHost",
        "openClawGatewayToken",
        "geminiLiveAPIKey",
        "geminiLiveModel",
    ]

    // Secrets now live in the Keychain (see KeychainService), so they must be
    // cleared there too — clearing UserDefaults alone would leave them set.
    private let keychainTestKeys = [
        "openClawGatewayToken",
    ]

    override func setUp() {
        super.setUp()
        clearTestState()
    }

    override func tearDown() {
        clearTestState()
        super.tearDown()
    }

    private func clearTestState() {
        for key in testKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for key in keychainTestKeys {
            KeychainService.delete(key)
        }
    }

    // MARK: - AppMode

    func testAppModeDefaultIsDirect() {
        XCTAssertEqual(Config.appMode, .direct)
    }

    func testAppModeSetAndGet() {
        Config.setAppMode(.geminiLive)
        XCTAssertEqual(Config.appMode, .geminiLive)

        Config.setAppMode(.direct)
        XCTAssertEqual(Config.appMode, .direct)
    }

    func testAppModeEnum() {
        XCTAssertEqual(AppMode.direct.rawValue, "direct")
        XCTAssertEqual(AppMode.geminiLive.rawValue, "geminiLive")
        XCTAssertEqual(AppMode.openaiRealtime.rawValue, "openaiRealtime")
        XCTAssertEqual(AppMode.allCases.count, 3)
    }

    func testAppModeDisplayName() {
        XCTAssertEqual(AppMode.direct.displayName, "Direct Mode")
        XCTAssertEqual(AppMode.geminiLive.displayName, "Gemini Live")
    }

    func testAppModeDescription() {
        XCTAssertFalse(AppMode.direct.description.isEmpty)
        XCTAssertFalse(AppMode.geminiLive.description.isEmpty)
    }

    // MARK: - OpenClaw Configuration

    func testOpenClawEnabledDefault() {
        XCTAssertFalse(Config.openClawEnabled)
    }

    func testOpenClawEnabledSetAndGet() {
        Config.setOpenClawEnabled(true)
        XCTAssertTrue(Config.openClawEnabled)

        Config.setOpenClawEnabled(false)
        XCTAssertFalse(Config.openClawEnabled)
    }

    func testOpenClawConnectionModeDefault() {
        XCTAssertEqual(Config.openClawConnectionMode, .auto)
    }

    func testOpenClawConnectionModeSetAndGet() {
        Config.setOpenClawConnectionMode(.lan)
        XCTAssertEqual(Config.openClawConnectionMode, .lan)

        Config.setOpenClawConnectionMode(.tunnel)
        XCTAssertEqual(Config.openClawConnectionMode, .tunnel)

        Config.setOpenClawConnectionMode(.auto)
        XCTAssertEqual(Config.openClawConnectionMode, .auto)
    }

    func testOpenClawLanHostDefault() {
        XCTAssertEqual(Config.openClawLanHost, "http://macbook.local")
    }

    func testOpenClawLanHostSetAndGet() {
        Config.setOpenClawLanHost("http://192.168.1.100")
        XCTAssertEqual(Config.openClawLanHost, "http://192.168.1.100")
    }

    func testOpenClawPortDefault() {
        XCTAssertEqual(Config.openClawPort, 18789)
    }

    func testOpenClawPortSetAndGet() {
        Config.setOpenClawPort(9999)
        XCTAssertEqual(Config.openClawPort, 9999)
    }

    func testOpenClawTunnelHostDefault() {
        XCTAssertEqual(Config.openClawTunnelHost, "")
    }

    func testOpenClawTunnelHostSetAndGet() {
        Config.setOpenClawTunnelHost("https://my-tunnel.trycloudflare.com")
        XCTAssertEqual(Config.openClawTunnelHost, "https://my-tunnel.trycloudflare.com")
    }

    func testOpenClawGatewayTokenDefault() {
        XCTAssertEqual(Config.openClawGatewayToken, "")
    }

    func testOpenClawGatewayTokenSetAndGet() {
        Config.setOpenClawGatewayToken("my-secret-token")
        XCTAssertEqual(Config.openClawGatewayToken, "my-secret-token")
    }

    func testIsOpenClawConfiguredWhenDisabled() {
        Config.setOpenClawEnabled(false)
        Config.setOpenClawGatewayToken("token")
        XCTAssertFalse(Config.isOpenClawConfigured, "Should be false when disabled even with token")
    }

    func testIsOpenClawConfiguredWhenEnabledNoToken() {
        Config.setOpenClawEnabled(true)
        // Token is empty by default
        XCTAssertFalse(Config.isOpenClawConfigured, "Should be false with empty token")
    }

    func testIsOpenClawConfiguredWhenEnabledWithToken() {
        Config.setOpenClawEnabled(true)
        Config.setOpenClawGatewayToken("my-token")
        XCTAssertTrue(Config.isOpenClawConfigured)
    }

    // MARK: - Gemini Live Configuration (derived from model configs)

    func testGeminiLiveAPIKeyDefaultEmpty() {
        // When no Gemini model is configured, key is empty
        XCTAssertEqual(Config.geminiLiveAPIKey, "")
    }

    func testIsGeminiLiveConfiguredWhenNoKey() {
        XCTAssertFalse(Config.isGeminiLiveConfigured)
    }

    func testGeminiLiveWebSocketURLNilWhenNoKey() {
        XCTAssertNil(Config.geminiLiveWebSocketURL)
    }

    // MARK: - Gemini Live Constants

    func testGeminiLiveAudioConstants() {
        XCTAssertEqual(Config.geminiLiveInputSampleRate, 16000)
        XCTAssertEqual(Config.geminiLiveOutputSampleRate, 24000)
        XCTAssertEqual(Config.geminiLiveAudioChannels, 1)
        XCTAssertEqual(Config.geminiLiveAudioBitsPerSample, 16)
        XCTAssertEqual(Config.geminiLiveVideoFrameInterval, 1.0)
        XCTAssertEqual(Config.geminiLiveVideoJPEGQuality, 0.5)
    }

    // MARK: - OpenClawConnectionMode Enum

    func testOpenClawConnectionModeRawValues() {
        XCTAssertEqual(OpenClawConnectionMode.lan.rawValue, "lan")
        XCTAssertEqual(OpenClawConnectionMode.tunnel.rawValue, "tunnel")
        XCTAssertEqual(OpenClawConnectionMode.auto.rawValue, "auto")
    }

    func testOpenClawConnectionModeDisplayNames() {
        XCTAssertEqual(OpenClawConnectionMode.lan.displayName, "LAN (Local Network)")
        XCTAssertEqual(OpenClawConnectionMode.tunnel.displayName, "Tunnel (Remote)")
        XCTAssertEqual(OpenClawConnectionMode.auto.displayName, "Auto (try LAN first)")
    }

    func testOpenClawConnectionModeAllCases() {
        XCTAssertEqual(OpenClawConnectionMode.allCases.count, 3)
    }
}
