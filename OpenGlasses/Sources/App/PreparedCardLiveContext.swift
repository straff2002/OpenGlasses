import CoreLocation
import Foundation

/// Plan KT P1 — the facts the My Day cards read beyond My Day's own gathering, from the phone's
/// own services: where the wearer is and how far from the event, the forecast at the event, who
/// at the event is in Contacts, last night's sleep (only with short night on and Health allowed),
/// the latest meeting summary, and the job day.
///
/// Everything is read on the phone. Under Medical Local Only nothing that sends a location out —
/// the place name, the destination's forecast — is fetched, the same rule My Day's weather keeps.
@MainActor
final class LivePreparedCardContextSource: PreparedCardContextSource {

    private let location: LocationService
    private let travel: MapKitTravelTimeDaySource
    private let jobFeed: () -> JobDayFeed?
    private let fieldAssistOn: () -> Bool
    private lazy var health = HealthKitSampleReader()
    private var healthState: HealthAuthorizationState = .notDetermined
    private var lastPlace: (location: CLLocation, place: CardPlace?)?
    private var lastJobTravel: CardJobTravel?

    init(location: LocationService, travel: MapKitTravelTimeDaySource,
         jobFeed: @escaping () -> JobDayFeed?, fieldAssistOn: @escaping () -> Bool) {
        self.location = location
        self.travel = travel
        self.jobFeed = jobFeed
        self.fieldAssistOn = fieldAssistOn
    }

    var isFieldAssistDay: Bool { fieldAssistOn() }

    var healthAvailable: Bool {
        AIFeatureGate.isEnabled(.healthSummaries) && healthState == .requested
    }

    private var mayReachOut: Bool { !MedicalEgressGuard.currentMode().isEnforcing }

    func context(for inputs: MyDayInputs, settings: PreparedCardSettings, now: Date) async -> PreparedCardContext {
        var context = PreparedCardContext()
        if AIFeatureGate.isEnabled(.healthSummaries) { healthState = await health.authorizationState() }

        if let estimate = inputs.travel {
            context.travelDistanceMeters = travel.distanceFromHere(eventID: estimate.eventID)
            if mayReachOut, Config.myDayWeatherIncluded,
               let coordinate = travel.destinationCoordinate(eventID: estimate.eventID),
               let event = inputs.events.first(where: { $0.id == estimate.eventID }) {
                context.destinationWeather = (try? await WeatherKitProvider.hours(
                    at: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    from: event.startDate.addingTimeInterval(-3600),
                    to: max(event.endDate, event.startDate.addingTimeInterval(3600)))) ?? []
            }
        }
        context.here = await place()
        context.contacts = Self.contacts(for: inputs.events, now: now)
        if settings.isEnabled(.shortNight), healthAvailable {
            let calendar = Calendar.autoupdatingCurrent
            let window = SleepNightAggregator.window(endingOn: now, calendar: calendar)
            if let samples = try? await health.sleepSamples(from: window.start, to: window.end) {
                context.sleep = SleepNightAggregator.aggregate(samples, now: now, calendar: calendar)
            }
        }
        if settings.isEnabled(.meetingFollowUp) { context.meeting = LatestMeetingSummary.shared.latest }
        context.wearer = CardWearer(name: Config.technicianFullName,
                                    company: fieldAssistOn() ? Config.organizationDisplayName : nil)
        if fieldAssistOn() { await refreshJobTravel(now: now) }
        context.jobs = jobFacts(now: now)
        return context
    }

    func jobFacts(now: Date) -> CardJobFacts? {
        guard fieldAssistOn(), var facts = jobFeed()?.cardFacts else { return nil }
        if let lastJobTravel, facts.upcoming.contains(where: { $0.id == lastJobTravel.jobID }) {
            facts.travel = lastJobTravel
        }
        return facts
    }

    // MARK: - Pieces

    /// The neighbourhood or street the wearer is in, reused while they stay within 250 m.
    private func place() async -> CardPlace? {
        guard mayReachOut, let here = location.currentLocation else { return nil }
        if let lastPlace, lastPlace.location.distance(from: here) < MyDayTravelCachePolicy.materialLocationChangeMeters {
            return lastPlace.place
        }
        let place = await GeocodingHelper.reverseGeocode(here).map(CardPlace.init)
        lastPlace = (here, place)
        return place
    }

    /// The next job today with an address and a time: travel to it from here.
    private func refreshJobTravel(now: Date) async {
        guard let facts = jobFeed()?.cardFacts else { lastJobTravel = nil; return }
        let calendar = Calendar.autoupdatingCurrent
        let next = facts.upcoming
            .filter { job in
                guard let when = job.scheduledFor else { return false }
                return calendar.isDate(when, inSameDayAs: now) && when > now && job.address != nil
            }
            .min { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
        guard let next, let address = next.address, let when = next.scheduledFor else { lastJobTravel = nil; return }
        lastJobTravel = await travel.jobTravel(jobID: next.id, address: address, scheduledFor: when, now: now)
    }

    /// Contacts for today's attendees, by lower-cased address. Only the other people at today's
    /// events, and only while Contacts access is already granted — nothing here asks.
    static func contacts(for events: [MyDayCalendarEvent], now: Date) -> [String: CardContact] {
        let calendar = Calendar.autoupdatingCurrent
        var result: [String: CardContact] = [:]
        let addresses = Set(events
            .filter { calendar.isDate($0.startDate, inSameDayAs: now) }
            .flatMap(\.attendees)
            .filter { !$0.isSelf }
            .compactMap { $0.email?.lowercased() })
        for address in addresses.sorted().prefix(20) {
            guard let contact = ContactLookupHelper.resolve(email: address) else { continue }
            result[address] = CardContact(name: contact.name, phone: contact.textablePhone)
        }
        return result
    }
}
