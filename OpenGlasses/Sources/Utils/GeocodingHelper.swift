import Foundation
import CoreLocation
import MapKit

/// Centralizes geocoding using the iOS 26 MKGeocodingRequest / MKReverseGeocodingRequest APIs.
enum GeocodingHelper {

    /// Result type for reverse geocoding.
    struct PlaceInfo {
        let locality: String?
        let administrativeArea: String?
        let isoCountryCode: String?
        let thoroughfare: String?
        let subThoroughfare: String?
        let fullAddress: String?
        let location: CLLocation?

        /// Formatted short address (e.g. "123 Main St")
        var streetAddress: String? {
            guard let street = thoroughfare else { return nil }
            let number = subThoroughfare ?? ""
            return "\(number) \(street)".trimmingCharacters(in: .whitespaces)
        }

        /// City + state (e.g. "San Francisco, CA")
        var cityState: String? {
            let parts = [locality, administrativeArea].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    // MARK: - Reverse Geocoding

    /// Reverse geocode a location to place info.
    static func reverseGeocode(_ location: CLLocation) async -> PlaceInfo? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            let items = try await request.mapItems
            guard let item = items.first else { return nil }
            let addr = item.address
            return PlaceInfo(
                locality: nil,
                administrativeArea: nil,
                isoCountryCode: nil,
                thoroughfare: nil,
                subThoroughfare: nil,
                fullAddress: addr?.fullAddress,
                location: item.location
            )
        } catch {
            return nil
        }
    }

    /// Reverse geocode coordinates to place info.
    static func reverseGeocode(latitude: Double, longitude: Double) async -> PlaceInfo? {
        await reverseGeocode(CLLocation(latitude: latitude, longitude: longitude))
    }

    // MARK: - Forward Geocoding

    /// Forward geocode an address string to a location.
    static func geocodeAddress(_ address: String) async -> CLLocation? {
        guard let request = MKGeocodingRequest(addressString: address) else { return nil }
        do {
            let items = try await request.mapItems
            return items.first?.location
        } catch {
            return nil
        }
    }

    // MARK: - Map Item Helpers

    /// Extract location and address from an MKMapItem.
    static func locationAndAddress(from item: MKMapItem) -> (location: CLLocation?, address: String?) {
        let loc = item.location
        let addr = item.address?.shortAddress ?? item.address?.fullAddress
        return (loc, addr)
    }

    /// Get just the country code for a location.
    static func countryCode(for location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            let items = try await request.mapItems
            guard let item = items.first else { return nil }
            // Extract country from the full address string as a fallback
            // MKAddress doesn't expose country code directly
            return item.address?.fullAddress.components(separatedBy: ", ").last
        } catch {
            return nil
        }
    }
}
