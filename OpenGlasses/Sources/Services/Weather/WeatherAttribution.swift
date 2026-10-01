import Foundation
import UIKit
import WeatherKit

/// Apple requires the Apple Weather mark and a link to its legal attribution page wherever
/// WeatherKit data is displayed. These are the pieces that make that cheap to honour: the
/// attribution fetched once and cached, the mark images downloaded off the main thread and kept in
/// memory, and a record of which chat threads show a weather answer.

struct WeatherAttributionInfo: Equatable, Sendable {
    var serviceName: String
    var legalPageURL: URL
    /// The combined mark drawn for a light appearance.
    var lightMarkURL: URL?
    /// The combined mark drawn for a dark appearance.
    var darkMarkURL: URL?

    /// Shown until WeatherKit's own attribution arrives, and if it never does: the service name as
    /// text and Apple's published legal attribution page, so the credit and the link are never
    /// missing from a screen that shows weather.
    static let fallback = WeatherAttributionInfo(
        serviceName: "Apple Weather",
        legalPageURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!,
        lightMarkURL: nil,
        darkMarkURL: nil
    )

    func markURL(darkAppearance: Bool) -> URL? {
        darkAppearance ? darkMarkURL : lightMarkURL
    }
}

protocol WeatherAttributionSource: Sendable {
    func attribution() async throws -> WeatherAttributionInfo
}

/// WeatherKit's attribution. Like the forecast itself this is the framework's own request.
struct WeatherKitAttributionSource: WeatherAttributionSource {
    func attribution() async throws -> WeatherAttributionInfo {
        let attribution = try await WeatherService.shared.attribution
        return WeatherAttributionInfo(
            serviceName: attribution.serviceName,
            legalPageURL: attribution.legalPageURL,
            lightMarkURL: attribution.combinedMarkLightURL,
            darkMarkURL: attribution.combinedMarkDarkURL
        )
    }
}

protocol WeatherMarkLoading: Sendable {
    func image(at url: URL) async throws -> UIImage
}

/// Downloads a mark image once and keeps it for the life of the process. An actor, so the fetch
/// and the decode never run on the main thread. The only request Avenkin itself makes for weather
/// (`NetworkRoute.weatherAttributionMark`): a fixed image on Apple's host, carrying nothing about
/// the wearer.
actor WeatherAttributionMarkLoader: WeatherMarkLoading {

    enum LoadError: Error, Equatable {
        case notAnAppleImage
        case badResponse
    }

    private var cache: [URL: UIImage] = [:]
    private var inFlight: [URL: Task<UIImage, Error>] = [:]

    /// Only https on an Apple host: the URL comes from WeatherKit, but a mark from anywhere else
    /// is not the mark Apple asked for.
    static func isAcceptable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }

    func image(at url: URL) async throws -> UIImage {
        if let cached = cache[url] { return cached }
        if let running = inFlight[url] { return try await running.value }
        guard Self.isAcceptable(url) else { throw LoadError.notAnAppleImage }
        try MedicalEgressGuard.check(.weatherAttributionMark)

        let task = Task<UIImage, Error> {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data, scale: 3) else {
                throw LoadError.badResponse
            }
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let image = try await task.value
        cache[url] = image
        return image
    }
}

/// The attribution every weather surface draws. Loads once per launch; a failure leaves the
/// fallback (text name + legal link) in place, which is still a complete credit.
@MainActor
final class WeatherAttributionStore: ObservableObject {

    static let shared = WeatherAttributionStore()

    @Published private(set) var info: WeatherAttributionInfo = .fallback
    @Published private(set) var marks: [URL: UIImage] = [:]

    private let source: any WeatherAttributionSource
    private let loader: any WeatherMarkLoading
    private let isAllowed: () -> Bool
    private var loadTask: Task<Void, Never>?

    init(source: any WeatherAttributionSource = WeatherKitAttributionSource(),
         loader: any WeatherMarkLoading = WeatherAttributionMarkLoader(),
         isAllowed: @escaping () -> Bool = { !MedicalEgressGuard.currentMode().isEnforcing }) {
        self.source = source
        self.loader = loader
        self.isAllowed = isAllowed
    }

    func mark(darkAppearance: Bool) -> UIImage? {
        info.markURL(darkAppearance: darkAppearance).flatMap { marks[$0] }
    }

    /// Safe to call from every view that appears; only the first call does any work. Under Medical
    /// Local Only nothing is fetched — no weather is shown then either, and the fallback credit is
    /// what Settings draws.
    func load() async {
        if let loadTask { return await loadTask.value }
        guard isAllowed() else { return }
        let task = Task { [source, loader] in
            guard let fetched = try? await source.attribution() else { return }
            self.info = fetched
            for url in [fetched.lightMarkURL, fetched.darkMarkURL].compactMap({ $0 }) {
                if let image = try? await loader.image(at: url) {
                    self.marks[url] = image
                }
            }
        }
        loadTask = task
        await task.value
    }
}

/// Chat threads in which `get_weather` answered, so the thread can carry the attribution under
/// the answer. Thread ids only — nothing of the conversation — and bounded, oldest first out.
@MainActor
final class WeatherAttributionThreads: ObservableObject {

    static let shared = WeatherAttributionThreads()
    static let defaultsKey = "weatherAttributionThreadIDs"
    static let limit = 200

    @Published private(set) var threadIDs: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        threadIDs = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func contains(_ threadID: String) -> Bool { threadIDs.contains(threadID) }

    func record(_ threadID: String?) {
        guard let threadID, !threadID.isEmpty, !threadIDs.contains(threadID) else { return }
        threadIDs.append(threadID)
        if threadIDs.count > Self.limit {
            threadIDs.removeFirst(threadIDs.count - Self.limit)
        }
        defaults.set(threadIDs, forKey: Self.defaultsKey)
    }
}
