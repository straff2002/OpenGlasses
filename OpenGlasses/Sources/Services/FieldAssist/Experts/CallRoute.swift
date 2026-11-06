import Foundation
import UIKit

/// How a call goes (Plan JI §6, built by Plan KM P0).
enum CallVia: String, Codable, CaseIterable, Sendable {
    case phone
    case faceTime = "facetime"
    case faceTimeAudio = "facetime_audio"

    /// The tool's spelling, forgiving of the ways a model writes it.
    init?(spoken raw: String?) {
        guard let raw else { return nil }
        let key = raw.lowercased().filter { $0.isLetter }
        switch key {
        case "phone", "call", "voice", "tel", "telephone": self = .phone
        case "facetime", "facetimevideo", "video": self = .faceTime
        case "facetimeaudio", "audio": self = .faceTimeAudio
        default: return nil
        }
    }

    var scheme: String {
        switch self {
        case .phone: return "tel"
        case .faceTime: return "facetime"
        case .faceTimeAudio: return "facetime-audio"
        }
    }
}

/// The URL that places a call to an expert. Pure.
///
/// **Only a cleaned number or handle ever reaches a URL.** A number is ASCII digits with an
/// optional leading `+` and the separators people write between digits; a handle is that, or a
/// plain email address. Anything else — another scheme, a query string, a path, a pause or a
/// tone (`,` `;` `*` `#`), percent-encoding, control or bidirectional characters, digits from
/// another script — is refused, so a list entry can never be a way to open something other than
/// a call to that person.
struct CallRoute: Equatable, Sendable {
    let via: CallVia
    let url: URL

    /// The route to `contact` by `via`, or nil when the contact has nothing that route can ring.
    /// FaceTime rings the handle, or the number when there is no handle.
    static func make(_ contact: EscalationContact, via: CallVia) -> CallRoute? {
        let target: String?
        switch via {
        case .phone:
            target = contact.phone.flatMap(cleanedNumber)
        case .faceTime, .faceTimeAudio:
            target = contact.faceTimeHandle.flatMap(cleanedHandle) ?? contact.phone.flatMap(cleanedNumber)
        }
        guard let target, let url = URL(string: "\(via.scheme):\(target)") else { return nil }
        return CallRoute(via: via, url: url)
    }

    /// The way a contact is called when nothing is said: by phone when there is a number, else
    /// FaceTime to the handle.
    static func defaultVia(for contact: EscalationContact) -> CallVia {
        contact.phone.flatMap(cleanedNumber) != nil ? .phone : .faceTime
    }

    private static let separators: Set<Character> = [" ", "-", ".", "(", ")", "\u{00A0}"]
    static let digitRange = 3...15

    /// The digits of a phone number, with its leading `+`, or nil when it is anything but one.
    static func cleanedNumber(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var result = ""
        for (index, character) in trimmed.enumerated() {
            if character == "+" && index == 0 {
                result.append(character)
            } else if character.isASCII, character.isNumber {
                result.append(character)
            } else if separators.contains(character) {
                continue
            } else {
                return nil
            }
        }
        let digits = result.filter(\.isNumber).count
        return digitRange.contains(digits) ? result : nil
    }

    /// A FaceTime handle: a plain email address, lower-cased, or a cleaned number.
    static func cleanedHandle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@") else { return cleanedNumber(trimmed) }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last,
              (1...64).contains(local.count), (3...190).contains(domain.count) else { return nil }
        let localAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        let domainAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard local.allSatisfy(localAllowed.contains), domain.allSatisfy(domainAllowed.contains),
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
              !domain.hasPrefix("."), !domain.hasPrefix("-"), !domain.hasSuffix("."), !domain.contains(".."),
              let tld = domain.split(separator: ".").last, domain.contains("."),
              tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return trimmed.lowercased()
    }
}

/// Opens a call route (Plan JI §6). A seam so the tool and the coordinator are testable without
/// opening anything; the result is whether iOS accepted the URL, never whether the call connected.
@MainActor
protocol CallPlacing {
    func place(_ route: CallRoute) async -> Bool
}

/// The real placement: `UIApplication.open`, which shows iOS's own confirmation before dialling.
/// `canOpenURL` is not asked first: it answers only for schemes listed in the Info.plist, and the
/// open's own completion already says whether iOS took the URL.
@MainActor
struct SystemCallPlacement: CallPlacing {
    func place(_ route: CallRoute) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(route.url, options: [:]) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }
}
