import UIKit
import XCTest
@testable import OpenGlasses

@MainActor
final class WeatherAttributionTests: XCTestCase {

    private final class FakeSource: WeatherAttributionSource, @unchecked Sendable {
        var calls = 0
        var result: Result<WeatherAttributionInfo, Error>
        init(_ result: Result<WeatherAttributionInfo, Error>) { self.result = result }
        func attribution() async throws -> WeatherAttributionInfo {
            calls += 1
            return try result.get()
        }
    }

    private final class FakeLoader: WeatherMarkLoading, @unchecked Sendable {
        var requested: [URL] = []
        func image(at url: URL) async throws -> UIImage {
            requested.append(url)
            return UIImage()
        }
    }

    private static let info = WeatherAttributionInfo(
        serviceName: "Weather",
        legalPageURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!,
        lightMarkURL: URL(string: "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_blk_en_3X_090122.png")!,
        darkMarkURL: URL(string: "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_wht_en_3X_090122.png")!
    )

    func testTheFallbackIsAFullCreditBeforeAnythingLoads() {
        let store = WeatherAttributionStore(source: FakeSource(.success(Self.info)), loader: FakeLoader())
        XCTAssertEqual(store.info, .fallback)
        XCTAssertEqual(store.info.serviceName, "Apple Weather")
        XCTAssertEqual(store.info.legalPageURL.host, "weatherkit.apple.com")
        XCTAssertNil(store.mark(darkAppearance: false))
    }

    func testLoadsOnceAndFetchesBothMarks() async {
        let source = FakeSource(.success(Self.info))
        let loader = FakeLoader()
        let store = WeatherAttributionStore(source: source, loader: loader)
        await store.load()
        await store.load()
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(store.info, Self.info)
        XCTAssertEqual(Set(loader.requested), [Self.info.lightMarkURL!, Self.info.darkMarkURL!])
        XCTAssertNotNil(store.mark(darkAppearance: true))
        XCTAssertNotNil(store.mark(darkAppearance: false))
    }

    func testAFailedAttributionKeepsTheFallback() async {
        let store = WeatherAttributionStore(source: FakeSource(.failure(URLError(.notConnectedToInternet))),
                                            loader: FakeLoader())
        await store.load()
        XCTAssertEqual(store.info, .fallback)
    }

    func testNothingIsFetchedUnderLocalOnly() async {
        let source = FakeSource(.success(Self.info))
        let loader = FakeLoader()
        let store = WeatherAttributionStore(source: source, loader: loader, isAllowed: { false })
        await store.load()
        XCTAssertEqual(source.calls, 0)
        XCTAssertTrue(loader.requested.isEmpty)
        XCTAssertEqual(store.info, .fallback)
    }

    func testTheMarkLoaderOnlyAcceptsAppleHostsOverHTTPS() {
        XCTAssertTrue(WeatherAttributionMarkLoader.isAcceptable(Self.info.lightMarkURL!))
        XCTAssertFalse(WeatherAttributionMarkLoader.isAcceptable(URL(string: "http://weatherkit.apple.com/a.png")!))
        XCTAssertFalse(WeatherAttributionMarkLoader.isAcceptable(URL(string: "https://apple.com.example.net/a.png")!))
        XCTAssertFalse(WeatherAttributionMarkLoader.isAcceptable(URL(string: "https://notapple.com/a.png")!))
    }

    // MARK: - Chat threads

    private func freshDefaults() -> UserDefaults {
        let name = "WeatherAttributionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testThreadsAreRecordedOncePersistedAndBounded() {
        let defaults = freshDefaults()
        let threads = WeatherAttributionThreads(defaults: defaults)
        threads.record("a")
        threads.record("a")
        threads.record(nil)
        threads.record("")
        XCTAssertEqual(threads.threadIDs, ["a"])
        XCTAssertTrue(WeatherAttributionThreads(defaults: defaults).contains("a"), "survives a relaunch")

        for index in 0..<(WeatherAttributionThreads.limit + 5) { threads.record("t\(index)") }
        XCTAssertEqual(threads.threadIDs.count, WeatherAttributionThreads.limit)
        XCTAssertFalse(threads.contains("a"), "oldest out first")
        XCTAssertTrue(threads.contains("t\(WeatherAttributionThreads.limit + 4)"))
    }
}
