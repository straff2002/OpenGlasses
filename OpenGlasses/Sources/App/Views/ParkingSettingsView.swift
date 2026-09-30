import MapKit
import PhotosUI
import SwiftUI

/// Parking memory (Plan GH): the current spot as a card — map, level and space, the sign photo,
/// walking directions — plus automatic capture and history settings. Lives in the general
/// services list, not the glasses section: phone, CarPlay and the phone speaker are enough.
struct ParkingSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store: ParkingStore

    @State private var autoSave = Config.parkingAutoSaveEnabled
    @State private var carPlay = Config.parkingAutoSaveCarPlay
    @State private var iDrive = Config.parkingIDrive
    @State private var keepHistory = Config.parkingKeepHistory
    @State private var pickerItem: PhotosPickerItem?
    @State private var photoMessage: String?
    @State private var directionsMessage: String?
    @State private var confirmForget = false

    init(appState: AppState) {
        self.appState = appState
        self._store = ObservedObject(wrappedValue: appState.parkingStore)
    }

    var body: some View {
        Form {
            currentSpotSection
            automaticSection
            historySection
        }
        .navigationTitle("Parking")
        .ogFormStyle()
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await addPhonePhoto(item) }
        }
    }

    // MARK: - Current spot

    @ViewBuilder
    private var currentSpotSection: some View {
        Section {
            if let spot = store.active {
                if let coordinate = spot.coordinate {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate, latitudinalMeters: 300, longitudinalMeters: 300))) {
                        Marker("Your car", systemImage: "car.fill", coordinate: coordinate)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Map showing where you parked")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(ParkingRecallPhraser.detailPhrase(spot).map { "Parked \($0)" }
                         ?? "Parked here")
                        .font(.headline)
                    Text(savedLine(spot))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let lag = spot.locationLag, lag >= ParkingRecallPhraser.staleFixThreshold {
                        Text("The position is from \(ParkingRecallPhraser.durationPhrase(lag)) before it was saved, so it may be off.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let note = spot.note, !note.isEmpty {
                        Text(note).font(.footnote)
                    }
                }
                .accessibilityElement(children: .combine)

                if let url = store.photoURL(for: spot), let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Photo of the parking sign")
                }

                if let coordinate = spot.coordinate {
                    Button {
                        Task { await startDirections(to: coordinate) }
                    } label: {
                        Label("Walking Directions", systemImage: "figure.walk")
                    }
                }
                if let directionsMessage {
                    Text(directionsMessage).font(.footnote).foregroundStyle(.secondary)
                }

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(spot.photoFile == nil ? "Add Sign Photo" : "Replace Sign Photo",
                          systemImage: "camera.viewfinder")
                }

                Button(role: .destructive) {
                    confirmForget = true
                } label: {
                    Label("Forget This Spot", systemImage: "trash")
                }
                .confirmationDialog("Forget where you parked?", isPresented: $confirmForget,
                                    titleVisibility: .visible) {
                    Button("Forget", role: .destructive) { store.clear() }
                }
            } else {
                Text("No spot saved. Say \u{201C}I parked on level 2, space 41\u{201D}, or add a photo of the sign.")
                    .foregroundStyle(.secondary)
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Add Sign Photo", systemImage: "camera.viewfinder")
                }
            }
            if let photoMessage {
                Text(photoMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Current Spot")
        } footer: {
            Text("Ask \u{201C}where did I park?\u{201D} for the level, space, distance and direction. The spot and its photo stay on this phone.")
        }
    }

    // MARK: - Automatic capture

    @ViewBuilder
    private var automaticSection: some View {
        Section {
            Toggle("Save When a Drive Ends", isOn: $autoSave)
                .onChange(of: autoSave) { _, value in Config.parkingAutoSaveEnabled = value }
            if autoSave {
                Toggle("After CarPlay Disconnects", isOn: $carPlay)
                    .onChange(of: carPlay) { _, value in Config.parkingAutoSaveCarPlay = value }
                Toggle("I Drive", isOn: $iDrive)
                    .onChange(of: iDrive) { _, value in Config.parkingIDrive = value }
            }
        } header: {
            Text("Automatic")
        } footer: {
            Text("Avenkin uses the last location it had during the drive — it doesn't track you in the background. \u{201C}I Drive\u{201D} also saves when your phone's motion goes from driving to walking; leave it off if you're often a passenger. Automatic saves arrive as a notification, and after CarPlay Avenkin also says \u{201C}Saved where you parked.\u{201D} A spot you gave yourself in the last ten minutes is never replaced.")
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        Section {
            Toggle("Keep History", isOn: $keepHistory)
                .onChange(of: keepHistory) { _, value in
                    Config.parkingKeepHistory = value
                    if !value { store.clearHistory() }
                }
            if keepHistory {
                if store.history.isEmpty {
                    Text("No earlier spots yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.history) { spot in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ParkingRecallPhraser.detailPhrase(spot).map { "Parked \($0)" } ?? "Map position only")
                            Text(savedLine(spot)).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } header: {
            Text("History")
        } footer: {
            Text("Off: only the current spot is kept, and it is deleted when replaced. On: the last ten are kept. Turning it off deletes them.")
        }
    }

    // MARK: - Actions

    private func savedLine(_ spot: ParkingSpot) -> String {
        let age = ParkingRecallPhraser.agePhrase(Date().timeIntervalSince(spot.savedAt))
        let how: String
        switch spot.capture {
        case .voice: how = "Saved by voice"
        case .photo: how = "Saved from a sign photo"
        case .carPlayDisconnect: how = "Saved when CarPlay disconnected"
        case .motion: how = "Saved automatically when your drive ended"
        }
        let certainty = spot.confidence == .probable ? " — probably" : ""
        return "\(how) \(age)\(certainty)"
    }

    private func startDirections(to coordinate: CLLocationCoordinate2D) async {
        do {
            directionsMessage = try await appState.walkingRoute.start(to: coordinate, label: "your car")
        } catch {
            directionsMessage = error.localizedDescription
        }
    }

    private func addPhonePhoto(_ item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            photoMessage = "That picture couldn't be read."
            return
        }
        let outcome = await appState.parkingPhotoFlow.acceptPhonePhoto(image)
        let location = appState.locationService.currentLocation.map(LocationFix.init)
        photoMessage = ParkingPhotoFlow.file(outcome, into: store, location: location, now: Date())
    }
}
