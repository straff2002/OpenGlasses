import MapKit
import SwiftUI

// Plan GM P1a — map cards on the wrist. The phone resolves and measures; the watch only draws the
// payload it was sent. Every card is useful with a blank map: the name, the distance and the
// bearing arrow are payload text, never tiles. The map is hidden from VoiceOver; each card speaks
// one summary instead.

/// "Now showing" in the main list while the phone has a card on the wrist.
struct WatchNowShowingRow: View {
    @ObservedObject var connectivity: WatchConnectivityService
    let accent: Color

    var body: some View {
        if let set = connectivity.surfaces, let surface = set.current {
            NavigationLink {
                WatchSurfaceView(connectivity: connectivity, surface: surface, usesMetric: set.usesMetric)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(for: surface.kind))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Now showing")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(Self.title(for: surface.kind))
                            .font(.caption)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
    }

    static func symbol(for kind: GlanceSurface.Kind) -> String {
        switch kind {
        case .place: return "mappin.and.ellipse"
        case .whereAmI: return "location.fill"
        case .places: return "list.bullet"
        case .route: return "figure.walk"
        case .list: return "checklist"
        case .image: return "photo"
        }
    }

    static func title(for kind: GlanceSurface.Kind) -> String {
        switch kind {
        case .place(let card): return card.name
        case .whereAmI(let card): return card.street ?? card.locality ?? String(localized: "Where you are")
        case .places(let card): return card.query
        case .route(let card): return card.destinationName
        case .list(let card): return card.title ?? String(localized: "List")
        case .image(let card): return card.caption
        }
    }
}

/// One surface, by kind.
struct WatchSurfaceView: View {
    @ObservedObject var connectivity: WatchConnectivityService
    let surface: GlanceSurface
    let usesMetric: Bool

    var body: some View {
        switch surface.kind {
        case .place(let card):
            WatchPlaceCardView(connectivity: connectivity, card: card, surfaceId: surface.id, placeId: nil,
                               mapAllowed: surface.mapAllowed, usesMetric: usesMetric)
        case .whereAmI(let card):
            WatchWhereCardView(card: card, mapAllowed: surface.mapAllowed)
        case .places(let card):
            WatchPlacesListView(connectivity: connectivity, card: card, surfaceId: surface.id,
                                mapAllowed: surface.mapAllowed, usesMetric: usesMetric)
        case .route, .list, .image:
            // Sent by later phases; an older watch app says so rather than drawing nothing.
            WatchUnavailableCard(text: String(localized: "Open Avenkin on your iPhone to see this."))
        }
    }
}

// MARK: - Place

struct WatchPlaceCardView: View {
    @ObservedObject var connectivity: WatchConnectivityService
    let card: PlaceCard
    let surfaceId: String
    /// The row's id when this card was opened from a nearby list.
    let placeId: String?
    let mapAllowed: Bool
    let usesMetric: Bool

    @State private var isStarting = false
    @State private var message: String?
    @State private var startedFeedback = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let freshness = card.wearer.map { WearerDotFreshness.forCard(fixAt: $0.fixAt, now: context.date) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.name)
                        .font(.headline)
                        .lineLimit(2)
                    if let subtitle = card.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if mapAllowed {
                        WatchGlanceMap(place: (card.name, card.coordinate), wearer: card.wearer,
                                       freshness: freshness)
                            .frame(height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if card.wearer != nil {
                        WatchBearingArrow(degrees: card.bearingDegrees)
                            .frame(maxWidth: .infinity)
                    }

                    if card.wearer != nil {
                        distanceBlock(freshness: freshness, now: context.date)
                    }
                    if !mapAllowed {
                        Text("Maps are off while Medical Local Only is on.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        go()
                    } label: {
                        HStack {
                            Image(systemName: "figure.walk")
                            Text("Go")
                            if isStarting { ProgressView().scaleEffect(0.6) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AccentColors.aiCoral)
                    .disabled(isStarting || !connectivity.isReachable)
                    .accessibilityHint("Starts walking directions on your iPhone.")

                    if !connectivity.isReachable {
                        Text("iPhone not reachable")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let message {
                        Text(message)
                            .font(.caption2)
                    }
                }
                .padding(.horizontal, 4)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(summary(freshness: freshness, now: context.date))
        }
        .sensoryFeedback(.start, trigger: startedFeedback)
    }

    private func distanceBlock(freshness: WearerDotFreshness?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(GlanceDistanceText.short(meters: card.shownMeters, metric: usesMetric))
                    .font(.title3.bold())
                    .foregroundStyle(freshness == .stale ? .secondary : .primary)
                Text(GlanceGeometry.compassPoint(forBearing: card.bearingDegrees).words)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if card.isStraightLine {
                Text("in a straight line")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let age = WatchGlanceText.ageLabel(freshness, fixAt: card.wearer?.fixAt) {
                Text(age)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(card.etas, id: \.mode) { eta in
                Text(WatchGlanceText.eta(eta))
                    .font(.caption2)
            }
        }
    }

    private func summary(freshness: WearerDotFreshness?, now: Date) -> String {
        var parts = [card.name]
        if card.wearer != nil {
            var distance = GlanceDistanceText.short(meters: card.shownMeters, metric: usesMetric)
            distance += " " + GlanceGeometry.compassPoint(forBearing: card.bearingDegrees).words
            if card.isStraightLine { distance += " " + String(localized: "in a straight line") }
            parts.append(distance)
        }
        if let age = WatchGlanceText.ageLabel(freshness, fixAt: card.wearer?.fixAt) { parts.append(age) }
        return parts.joined(separator: ", ")
    }

    private func go() {
        message = nil
        isStarting = true
        connectivity.startGuidance(surfaceId: surfaceId, placeId: placeId) { error in
            isStarting = false
            if let error {
                message = error
            } else {
                message = String(localized: "Directions started on your iPhone.")
                startedFeedback += 1
            }
        }
    }
}

// MARK: - Where am I

struct WatchWhereCardView: View {
    let card: WhereCard
    let mapAllowed: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let freshness = WearerDotFreshness.forCard(fixAt: card.wearer.fixAt, now: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.street ?? String(localized: "Where you are"))
                        .font(.headline)
                        .lineLimit(2)
                    if let locality = card.locality {
                        Text(locality)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if mapAllowed {
                        WatchGlanceMap(place: nil, wearer: card.wearer, freshness: freshness)
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("Maps are off while Medical Local Only is on.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let age = WatchGlanceText.ageLabel(freshness, fixAt: card.wearer.fixAt) {
                        Text(age)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([card.street, card.locality,
                                 WatchGlanceText.ageLabel(freshness, fixAt: card.wearer.fixAt)]
                .compactMap { $0 }.joined(separator: ", "))
        }
    }
}

// MARK: - Nearby places

struct WatchPlacesListView: View {
    @ObservedObject var connectivity: WatchConnectivityService
    let card: PlacesCard
    let surfaceId: String
    let mapAllowed: Bool
    let usesMetric: Bool

    var body: some View {
        List {
            ForEach(card.rows) { row in
                NavigationLink {
                    WatchPlaceCardView(connectivity: connectivity,
                                       card: PlaceCard.from(row: row, wearer: card.wearer),
                                       surfaceId: surfaceId, placeId: row.id,
                                       mapAllowed: mapAllowed, usesMetric: usesMetric)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.caption)
                            .lineLimit(2)
                        HStack(spacing: 4) {
                            if card.wearer != nil {
                                Text(GlanceDistanceText.short(meters: row.meters, metric: usesMetric))
                            }
                            if let category = row.category { Text(category) }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if card.droppedRows > 0 {
                Text("\(card.droppedRows) more on your iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(card.query)
    }
}

// MARK: - Pieces

/// A small, non-interactive map: a coral marker for the place, a blue dot for the wearer (grey
/// and hollow once stale), framed by `GlanceGeometry`.
struct WatchGlanceMap: View {
    let place: (name: String, coordinate: GlancePoint)?
    let wearer: WearerFix?
    let freshness: WearerDotFreshness?

    var body: some View {
        let points = [place?.coordinate, wearer?.coordinate].compactMap { $0 }
        if let region = GlanceGeometry.region(framing: points) {
            Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: region.centerLatitude,
                                                   longitude: region.centerLongitude),
                    span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta,
                                           longitudeDelta: region.longitudeDelta))),
                interactionModes: []) {
                if let place {
                    Marker(place.name, coordinate: Self.coordinate(place.coordinate))
                        .tint(AccentColors.aiCoral)
                }
                if let wearer {
                    Annotation("", coordinate: Self.coordinate(wearer.coordinate)) {
                        WatchWearerDot(stale: freshness == .stale)
                    }
                    if wearer.horizontalAccuracy > 50 {
                        MapCircle(center: Self.coordinate(wearer.coordinate), radius: wearer.horizontalAccuracy)
                            .foregroundStyle(.blue.opacity(0.15))
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }

    static func coordinate(_ point: GlancePoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
}

struct WatchWearerDot: View {
    let stale: Bool

    var body: some View {
        if stale {
            Circle()
                .strokeBorder(.gray, lineWidth: 2)
                .frame(width: 12, height: 12)
        } else {
            Circle()
                .fill(.blue)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .frame(width: 12, height: 12)
        }
    }
}

/// The direction to the place, relative to north — the card without a map.
struct WatchBearingArrow: View {
    let degrees: Double

    var body: some View {
        Image(systemName: "location.north.fill")
            .font(.title2)
            .foregroundStyle(AccentColors.aiCoral)
            .rotationEffect(.degrees(degrees))
            .accessibilityHidden(true)
    }
}

struct WatchUnavailableCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
    }
}

/// The wording the cards share.
enum WatchGlanceText {
    /// "2 min ago" while aged, "as of 10:42" once stale, nothing while fresh.
    static func ageLabel(_ freshness: WearerDotFreshness?, fixAt: Date?) -> String? {
        switch freshness {
        case .aged(let seconds):
            return String(localized: "\(WearerDotFreshness.minutesAgo(seconds)) min ago")
        case .stale:
            guard let fixAt else { return nil }
            return String(localized: "as of \(fixAt.formatted(date: .omitted, time: .shortened))")
        case .fresh, .none:
            return nil
        }
    }

    static func eta(_ eta: GlanceETA) -> String {
        let minutes = max(1, Int((Double(eta.seconds) / 60).rounded()))
        switch eta.mode {
        case .walking: return String(localized: "\(minutes) min walk")
        case .cycling: return String(localized: "\(minutes) min by bike")
        case .driving: return String(localized: "\(minutes) min drive")
        }
    }
}
