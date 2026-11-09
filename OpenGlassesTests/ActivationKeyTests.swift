import XCTest
@testable import OpenGlasses

/// Plan CT 3a — the short activation key: its format and check character, the sealed file on the
/// static host, and the lookup that turns a key into the licence it stands for.
///
/// The vectors were computed independently of this code (Node's `crypto`: SHA-256, HKDF-SHA256,
/// AES-256-GCM), so they pin the derivations the generator script must also produce.
final class ActivationKeyTests: XCTestCase {

    private let vector = "K7Q3-X9PD-M2VA-8RTZ"
    private let vectorFile = "5bfc56ce37ae78c6344a5f44b7a3c46127f13ae100f728e6da2f9f499e9bcd5a"
    /// "LICENCE.CODE" sealed under the vector key, with nonce 00 01 … 0b.
    private let vectorSealed = "AAECAwQFBgcICQoLLrYpUDJR+YWx4a8zgSvsJKXB3eSl9eI6HWkUWQ=="

    private func key(_ text: String) throws -> ActivationKey {
        guard case .key(let key) = ActivationKey.read(text) else {
            XCTFail("not a key: \(text)")
            throw ActivationKey.Problem.mistyped
        }
        return key
    }

    // MARK: - Format

    func testTheVectorKeyReadsInAnyCaseWithOrWithoutDashes() throws {
        for text in [vector, "k7q3-x9pd-m2va-8rtz", "K7Q3X9PDM2VA8RTZ", " K7Q3 X9PD M2VA 8RTZ \n"] {
            guard case .key(let parsed) = ActivationKey.read(text) else { return XCTFail(text) }
            XCTAssertEqual(parsed.canonical, "K7Q3X9PDM2VA8RTZ")
            XCTAssertEqual(parsed.display, vector)
        }
    }

    func testLookalikeLettersReadAsTheirDigits() {
        let data = "01ABCDEFGHJKMNP"
        let values = data.map { ActivationKey.alphabet.firstIndex(of: $0)! }
        let check = ActivationKey.alphabet[ActivationKey.checkValue(values)]
        let rest = String(data.dropFirst(2))
        guard case .key(let typed) = ActivationKey.read("OL" + rest + String(check)),
              case .key(let exact) = ActivationKey.read(data + String(check)) else {
            return XCTFail("both spellings should read")
        }
        XCTAssertEqual(typed, exact)
        XCTAssertEqual(ActivationKey.read("OI" + rest + String(check)), .key(exact))
    }

    func testEverySingleWrongCharacterIsCaught() {
        let canonical = Array("K7Q3X9PDM2VA8RTZ")
        for position in canonical.indices {
            for replacement in ActivationKey.alphabet where replacement != canonical[position] {
                var typo = canonical
                typo[position] = replacement
                XCTAssertEqual(ActivationKey.read(String(typo)), .invalid(.mistyped), String(typo))
            }
        }
    }

    func testEverySwapOfNeighboursIsCaught() {
        let canonical = Array("K7Q3X9PDM2VA8RTZ")
        for position in 0..<(canonical.count - 1) where canonical[position] != canonical[position + 1] {
            var typo = canonical
            typo.swapAt(position, position + 1)
            XCTAssertEqual(ActivationKey.read(String(typo)), .invalid(.mistyped), String(typo))
        }
    }

    func testTheWrongLengthAndALetterUAreRefusedBeforeAnyLookup() {
        XCTAssertEqual(ActivationKey.read("K7Q3-X9PD-M2VA"), .invalid(.length(12)))
        XCTAssertEqual(ActivationKey.read("K7Q3-X9PD-M2VA-8RTZZ"), .invalid(.length(17)))
        XCTAssertEqual(ActivationKey.read("K7Q3-X9PD-M2VA-8RTU"), .invalid(.mistyped))
        XCTAssertEqual(ActivationKey.Problem.mistyped.errorDescription,
                       "Check the key — one character looks wrong.")
    }

    func testALicenceCodeIsNotReadAsAKey() {
        XCTAssertEqual(ActivationKey.read("eyJmZWF0dXJlIjoiZmllbGRfYXNzaXN0In0.c2lnbmF0dXJl"), .notAKey)
        XCTAssertEqual(ActivationKey.read(""), .notAKey)
        XCTAssertEqual(ActivationKey.read("abc.def"), .notAKey, "a dot is never part of a key")
    }

    func testGeneratedKeysReadBackAsThemselves() {
        var names = Set<String>()
        for _ in 0..<200 {
            let key = ActivationKey.generate()
            XCTAssertEqual(ActivationKey.read(key.display), .key(key))
            XCTAssertEqual(key.display.count, 19)
            names.insert(key.fileName)
        }
        XCTAssertEqual(names.count, 200)
    }

    // MARK: - Formatting as it is typed

    func testAKeyIsUpperCasedAndGroupedInFoursAsItIsTyped() {
        XCTAssertEqual(ActivationKey.formatEntry("k7q3x9pdm2va8rtz"), vector)
        var shown = ""
        for character in "k7q3x9pdm2va8rtz" {
            shown = ActivationKey.formatEntry(shown + String(character), previous: shown)
        }
        XCTAssertEqual(shown, vector, "one character at a time ends in the same place")
        XCTAssertEqual(ActivationKey.formatEntry(""), "")
    }

    func testAPastedKeyIsGroupedWhateverItCameWith() {
        for pasted in ["K7Q3X9PDM2VA8RTZ", "k7q3-x9pd-m2va-8rtz", "K7Q3 X9PD M2VA 8RTZ", " k7q3-x9pd m2va8rtz\n",
                       "K7Q-3X9-PDM-2VA-8RTZ"] {
            XCTAssertEqual(ActivationKey.formatEntry(pasted), vector, pasted)
            XCTAssertEqual(ActivationKey.formatEntry(pasted, previous: "K7Q3"), vector, "pasted over a partial key")
        }
    }

    func testAPartialKeyIsGroupedAsFarAsItGoes() {
        XCTAssertEqual(ActivationKey.formatEntry("k"), "K")
        XCTAssertEqual(ActivationKey.formatEntry("k7q3"), "K7Q3")
        XCTAssertEqual(ActivationKey.formatEntry("k7q3x"), "K7Q3-X")
        XCTAssertEqual(ActivationKey.formatEntry("K7Q3-X9PD-M2"), "K7Q3-X9PD-M2")
        XCTAssertEqual(ActivationKey.formatEntry("K7Q3-"), "K7Q3", "a dash with nothing after it goes")
        XCTAssertEqual(ActivationKey.formatEntry("K7Q3-X9PD-M2VA-8RTZZ"), "K7Q3-X9PD-M2VA-8RTZ-Z",
                       "a key typed one too long still reads as an attempt, and `read` says how long it is")
    }

    func testLookalikeLettersStayAsTyped() {
        XCTAssertEqual(ActivationKey.formatEntry("oil0-u"), "OIL0-U", "read maps O, I and L and refuses U")
        let data = "01ABCDEFGHJKMNP"
        let values = data.map { ActivationKey.alphabet.firstIndex(of: $0)! }
        let check = String(ActivationKey.alphabet[ActivationKey.checkValue(values)])
        let shown = ActivationKey.formatEntry("ol" + data.dropFirst(2).lowercased() + check)
        XCTAssertTrue(shown.hasPrefix("OLAB-"), shown)
        XCTAssertEqual(ActivationKey.read(shown), ActivationKey.read(data + check))
    }

    func testBackspacingOverADashTakesTheCharacterBeforeIt() {
        // The cursor just after the dash in "K7Q3-X9PD"; backspace removes the dash alone.
        XCTAssertEqual(ActivationKey.formatEntry("K7Q3X9PD", previous: "K7Q3-X9PD"), "K7QX-9PD")
        XCTAssertEqual(ActivationKey.formatEntry("K7Q3-X9PDM2VA-8RTZ", previous: vector), "K7Q3-X9PM-2VA8-RTZ")
        // Backspacing the last character would leave a trailing dash, which goes with it.
        XCTAssertEqual(ActivationKey.formatEntry("K7Q3-", previous: "K7Q3-X"), "K7Q3")
        // Any other edit is formatted as it stands.
        XCTAssertEqual(ActivationKey.formatEntry("K7Q-X9PD", previous: "K7Q3-X9PD"), "K7QX-9PD")
        XCTAssertEqual(ActivationKey.formatEntry("K7Q3-X9P", previous: "K7Q3-X9PD"), "K7Q3-X9P")
        XCTAssertEqual(ActivationKey.formatEntry("", previous: "K"), "")
    }

    func testALicenceCodeIsLeftExactlyAsPasted() {
        let code = "eyJmZWF0dXJlIjoiZmllbGRfYXNzaXN0In0.c2lnbmF0dXJl"
        XCTAssertEqual(ActivationKey.formatEntry(code), code)
        XCTAssertEqual(ActivationKey.formatEntry(code, previous: String(code.dropLast())), code)
        let long = String(repeating: "eyJmZWF0dXJlIjoiZmllbGRfYXNzaXN0In0", count: 11) + ".c2lnbmF0dXJl-_A"
        XCTAssertEqual(ActivationKey.formatEntry(long), long, "a code of about 400 characters is never reshaped")
        XCTAssertEqual(ActivationKey.formatEntry("abc.def"), "abc.def", "a dot is never part of a key")
        XCTAssertEqual(ActivationKey.formatEntry("k7q3-x9pd-m2va-8rtz-k7q3-x9pd-m"), "k7q3-x9pd-m2va-8rtz-k7q3-x9pd-m",
                       "past the longest attempt it is not a key, whatever its characters")
    }

    func testAFormattedKeyStillReadsAsTheSameKey() {
        for _ in 0..<50 {
            let key = ActivationKey.generate()
            XCTAssertEqual(ActivationKey.formatEntry(key.canonical.lowercased()), key.display)
            XCTAssertEqual(ActivationKey.read(ActivationKey.formatEntry(key.canonical.lowercased())), .key(key))
        }
    }

    // MARK: - The sealed file

    func testTheFileNameMatchesTheVector() throws {
        XCTAssertEqual(try key(vector).fileName, vectorFile)
    }

    func testTheVectorFileOpensWithTheVectorKey() throws {
        let key = try key(vector)
        XCTAssertEqual(key.open(Data(vectorSealed.utf8)), "LICENCE.CODE")
        XCTAssertEqual(key.open(Data((vectorSealed + "\n").utf8)), "LICENCE.CODE", "a trailing newline is fine")
    }

    func testOnlyTheKeyThatSealedAFileCanOpenIt() throws {
        let key = try key(vector)
        let sealed = try key.seal("CODE.SIGNATURE")
        XCTAssertEqual(key.open(Data(sealed.utf8)), "CODE.SIGNATURE")
        XCTAssertNil(ActivationKey.generate().open(Data(sealed.utf8)))
        XCTAssertNil(key.open(Data("<html>not found</html>".utf8)))
    }

    // MARK: - Lookup

    private final class Host: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URL] = []
        var reply: Result<(status: Int, body: Data), Error>

        init(_ reply: Result<(status: Int, body: Data), Error>) { self.reply = reply }

        var requests: [URL] { lock.withLock { _requests } }

        func fetch(_ url: URL) throws -> (status: Int, body: Data) {
            lock.withLock { _requests.append(url) }
            return try reply.get()
        }
    }

    private func resolver(_ host: Host) -> ActivationKeyResolver {
        ActivationKeyResolver(directory: URL(string: "https://keys.example/activation/")!,
                              fetch: { try host.fetch($0) })
    }

    func testAKeyResolvesToTheLicenceItSealed() async throws {
        let key = try key(vector)
        let host = Host(.success((200, Data(vectorSealed.utf8))))
        let code = try await resolver(host).resolve(key)
        XCTAssertEqual(code, "LICENCE.CODE")
        XCTAssertEqual(host.requests, [URL(string: "https://keys.example/activation/\(vectorFile)")!])
    }

    func testAMissingFileIsAnUnknownKey() async throws {
        let key = try key(vector)
        for reply: Result<(status: Int, body: Data), Error> in [
            .success((404, Data())),
            .failure(BoundedHTTPClient.ClientError.unacceptableMIMEType),
        ] {
            do {
                _ = try await resolver(Host(reply)).resolve(key)
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(error as? ActivationKeyResolver.Failure, .unknownKey)
            }
        }
    }

    func testNoConnectionSaysTheInternetIsNeededOnce() async throws {
        let key = try key(vector)
        for reply: Result<(status: Int, body: Data), Error> in [
            .failure(URLError(.notConnectedToInternet)),
            .failure(BoundedHTTPClient.ClientError.resolutionFailed),
            .success((503, Data())),
        ] {
            do {
                _ = try await resolver(Host(reply)).resolve(key)
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(error as? ActivationKeyResolver.Failure, .unreachable)
                XCTAssertTrue(error.localizedDescription.contains("internet once"))
            }
        }
    }

    func testAFileThisKeyDidNotSealIsRefused() async throws {
        let key = try key(vector)
        let other = try ActivationKey.generate().seal("SOMEONE.ELSE")
        do {
            _ = try await resolver(Host(.success((200, Data(other.utf8))))).resolve(key)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? ActivationKeyResolver.Failure, .unreadable)
        }
    }

    // MARK: - Entry

    @MainActor
    func testEntryPassesACodeThroughRefusesATypoOfflineAndResolvesAKey() async throws {
        let host = Host(.success((200, Data(vectorSealed.utf8))))
        let service = OrgEnrolmentService(manager: OrgProfileManager(seams: OrgProfileManager.Seams()),
                                          fetch: { _ in Data() }, isPastOnboarding: { true },
                                          activationResolver: resolver(host))

        let code = "eyJmZWF0dXJlIjoiZmllbGRfYXNzaXN0In0.c2lnbmF0dXJl"
        let passed = await service.resolveEntry(code)
        XCTAssertEqual(passed, .licence(code))
        let typo = await service.resolveEntry("K7Q3-X9PD-M2VA-8RTY")
        XCTAssertEqual(typo, .refused("Check the key — one character looks wrong."))
        XCTAssertEqual(host.requests, [], "neither reaches the network")

        let resolved = await service.resolveEntry("k7q3 x9pd m2va 8rtz")
        XCTAssertEqual(resolved, .licence("LICENCE.CODE"))
        XCTAssertEqual(host.requests.count, 1)
    }
}
