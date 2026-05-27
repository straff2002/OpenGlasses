import Foundation
import CoreLocation

/// Golf mode: shot tracking, club recommendations, course awareness, and scoring.
/// Uses GPS for distance tracking between shots and provides strategic advice.
struct GolfModeTool: NativeTool {
    let name = "golf_mode"
    let description = "Golf assistant: track shots with GPS distance, get club recommendations, log scores per hole, view round summary, and get course strategy advice."

    let locationService: LocationService

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: start_round, end_round, track_shot, club_recommendation, log_score, round_summary, strategy",
                "enum": ["start_round", "end_round", "track_shot", "club_recommendation", "log_score", "round_summary", "strategy"]
            ],
            "club": [
                "type": "string",
                "description": "Club used (e.g., 'driver', '7-iron', 'putter', 'sand wedge')"
            ],
            "hole_number": [
                "type": "integer",
                "description": "Hole number (1-18)"
            ],
            "score": [
                "type": "integer",
                "description": "Strokes taken on the hole"
            ],
            "par": [
                "type": "integer",
                "description": "Par for the hole (3, 4, or 5)"
            ],
            "distance_yards": [
                "type": "integer",
                "description": "Distance to pin/target in yards (for club recommendation)"
            ],
            "lie": [
                "type": "string",
                "description": "Ball lie: 'fairway', 'rough', 'bunker', 'tee', 'fringe', 'green'"
            ],
            "wind": [
                "type": "string",
                "description": "Wind condition: 'calm', 'light', 'moderate', 'strong', 'headwind', 'tailwind', 'crosswind'"
            ],
            "elevation": [
                "type": "string",
                "description": "Elevation change: 'uphill', 'downhill', 'flat'"
            ]
        ],
        "required": ["action"]
    ]

    // MARK: - Static State

    private static var activeRound: GolfRound?
    private static var lastShotLocation: CLLocation?

    struct GolfRound {
        let startDate: Date
        var courseName: String?
        var holes: [HoleScore]
        var shotLog: [(hole: Int, club: String, distanceYards: Double, timestamp: Date)]
    }

    struct HoleScore {
        let number: Int
        let par: Int
        var strokes: Int
    }

    // MARK: - Execute

    func execute(args: [String: Any]) async throws -> String {
        let action = args["action"] as? String ?? ""

        switch action {
        case "start_round":
            return startRound()
        case "end_round":
            return endRound()
        case "track_shot":
            return await trackShot(club: args["club"] as? String)
        case "club_recommendation":
            return clubRecommendation(
                distanceYards: args["distance_yards"] as? Int,
                lie: args["lie"] as? String,
                wind: args["wind"] as? String,
                elevation: args["elevation"] as? String
            )
        case "log_score":
            return logScore(
                hole: args["hole_number"] as? Int,
                strokes: args["score"] as? Int,
                par: args["par"] as? Int
            )
        case "round_summary":
            return roundSummary()
        case "strategy":
            return strategyAdvice(
                distanceYards: args["distance_yards"] as? Int,
                lie: args["lie"] as? String,
                par: args["par"] as? Int
            )
        default:
            return "Unknown action '\(action)'. Use: start_round, end_round, track_shot, club_recommendation, log_score, round_summary, strategy."
        }
    }

    // MARK: - Actions

    private func startRound() -> String {
        guard Self.activeRound == nil else {
            return "A round is already in progress. End it first with action='end_round'."
        }
        Self.activeRound = GolfRound(startDate: Date(), holes: [], shotLog: [])
        Self.lastShotLocation = nil
        return "Golf round started! I'll track your shots and scores. Say 'track shot' after each swing, and 'log score' at the end of each hole."
    }

    private func endRound() -> String {
        guard let round = Self.activeRound else {
            return "No active round. Start one with action='start_round'."
        }
        let summary = buildSummary(round)
        Self.activeRound = nil
        Self.lastShotLocation = nil
        return "Round complete!\n\n\(summary)"
    }

    private func trackShot(club: String?) async -> String {
        guard Self.activeRound != nil else {
            return "No active round. Start one with action='start_round'."
        }

        let currentLocation = await MainActor.run { locationService.currentLocation }

        var result = ""
        if let lastLoc = Self.lastShotLocation, let currentLoc = currentLocation {
            let distanceMeters = currentLoc.distance(from: lastLoc)
            let distanceYards = distanceMeters * 1.09361
            let clubName = club ?? "unknown club"
            let holeNum = (Self.activeRound?.holes.count ?? 0) + 1

            Self.activeRound?.shotLog.append((
                hole: holeNum,
                club: clubName,
                distanceYards: distanceYards,
                timestamp: Date()
            ))

            result = "Shot tracked: \(Int(distanceYards)) yards with \(clubName)."
        } else if let club = club {
            result = "First shot of the hole marked with \(club). I'll measure the distance on your next shot."
        } else {
            result = "Shot position marked. Tell me which club you used, and I'll track the distance on your next shot."
        }

        Self.lastShotLocation = currentLocation
        return result
    }

    private func clubRecommendation(distanceYards: Int?, lie: String?, wind: String?, elevation: String?) -> String {
        guard let distance = distanceYards else {
            return "I need the distance to the target in yards. How far are you from the pin?"
        }

        let adjustedDistance = adjustDistance(
            base: distance,
            wind: wind ?? "calm",
            elevation: elevation ?? "flat",
            lie: lie ?? "fairway"
        )

        let club = recommendClub(yards: adjustedDistance)
        var response = "For \(distance) yards"

        var adjustments: [String] = []
        if let wind = wind, wind != "calm" {
            adjustments.append(wind)
        }
        if let elevation = elevation, elevation != "flat" {
            adjustments.append(elevation)
        }
        if let lie = lie, lie != "fairway" && lie != "tee" {
            adjustments.append("from the \(lie)")
        }

        if !adjustments.isEmpty {
            response += " (\(adjustments.joined(separator: ", ")))"
        }

        if adjustedDistance != distance {
            response += ", playing like \(adjustedDistance) yards"
        }

        response += ": I'd recommend a **\(club)**."

        // Add swing tip based on lie
        if let lie = lie {
            switch lie {
            case "bunker":
                response += " Open the face, aim slightly left, and hit 1-2 inches behind the ball."
            case "rough":
                response += " Take one more club and grip down slightly. The grass will grab the hosel."
            case "fringe":
                response += " Consider putting or a bump-and-run with a 7 or 8 iron."
            default:
                break
            }
        }

        return response
    }

    private func logScore(hole: Int?, strokes: Int?, par: Int?) -> String {
        guard Self.activeRound != nil else {
            return "No active round. Start one with action='start_round'."
        }

        let holeNum = hole ?? (Self.activeRound!.holes.count + 1)
        guard let score = strokes else {
            return "How many strokes did you take on hole \(holeNum)?"
        }
        let holePar = par ?? 4

        let holeScore = HoleScore(number: holeNum, par: holePar, strokes: score)
        Self.activeRound?.holes.append(holeScore)
        Self.lastShotLocation = nil  // Reset for new hole

        let diff = score - holePar
        let scoreName: String
        switch diff {
        case ...(-3): scoreName = "Albatross! 🦅🦅"
        case -2: scoreName = "Eagle! 🦅"
        case -1: scoreName = "Birdie! 🐦"
        case 0: scoreName = "Par"
        case 1: scoreName = "Bogey"
        case 2: scoreName = "Double bogey"
        default: scoreName = "+\(diff)"
        }

        let totalStrokes = Self.activeRound!.holes.reduce(0) { $0 + $1.strokes }
        let totalPar = Self.activeRound!.holes.reduce(0) { $0 + $1.par }
        let totalDiff = totalStrokes - totalPar
        let totalStr = totalDiff == 0 ? "Even" : (totalDiff > 0 ? "+\(totalDiff)" : "\(totalDiff)")

        return "Hole \(holeNum): \(score) strokes (par \(holePar)) — \(scoreName). Running total: \(totalStrokes) (\(totalStr)) through \(Self.activeRound!.holes.count) holes."
    }

    private func roundSummary() -> String {
        guard let round = Self.activeRound else {
            return "No active round. Start one with action='start_round'."
        }
        if round.holes.isEmpty {
            return "No holes completed yet. Use action='log_score' after each hole."
        }
        return buildSummary(round)
    }

    private func strategyAdvice(distanceYards: Int?, lie: String?, par: Int?) -> String {
        let holePar = par ?? 4

        var advice: [String] = []

        switch holePar {
        case 3:
            advice.append("Par 3: Focus on hitting the green. Aim for the center — don't get greedy with pin positions near hazards.")
            if let dist = distanceYards {
                if dist > 200 {
                    advice.append("Long par 3 (\(dist) yards). Consider a hybrid or fairway wood. Landing short of the green is better than going long.")
                } else if dist < 130 {
                    advice.append("Short par 3. Great scoring opportunity — commit to your wedge and trust your distance.")
                }
            }
        case 4:
            advice.append("Par 4: Get your tee shot in play first. A fairway at 230 yards beats rough at 280.")
            if let dist = distanceYards {
                if dist > 400 {
                    advice.append("Long par 4 (\(dist) yards). Don't force it in two — a good layup leaves a comfortable wedge.")
                }
            }
        case 5:
            advice.append("Par 5: Three good shots beats two hero shots. Think backwards from the pin: what wedge distance do you want?")
        default:
            advice.append("Play smart, manage risk, and aim for the fat part of the green.")
        }

        if let lie = lie {
            switch lie {
            case "bunker":
                advice.append("From the bunker: Take your medicine and get it out. Don't try to be a hero — center of the green is fine.")
            case "rough":
                advice.append("From the rough: Club up, aim for the safe part of the green. Rough reduces spin so expect more roll.")
            default:
                break
            }
        }

        return advice.joined(separator: " ")
    }

    // MARK: - Helpers

    private func adjustDistance(base: Int, wind: String, elevation: String, lie: String) -> Int {
        var adjusted = Double(base)

        switch wind {
        case "headwind", "strong":
            adjusted *= 1.10
        case "tailwind":
            adjusted *= 0.90
        case "moderate":
            adjusted *= 1.05
        default:
            break
        }

        switch elevation {
        case "uphill":
            adjusted *= 1.08
        case "downhill":
            adjusted *= 0.92
        default:
            break
        }

        switch lie {
        case "rough":
            adjusted *= 1.05  // Grass grabs, ball doesn't carry as far
        case "bunker":
            adjusted *= 1.10  // Hard to get full distance from sand
        default:
            break
        }

        return Int(adjusted)
    }

    private func recommendClub(yards: Int) -> String {
        // Average amateur distances
        switch yards {
        case ...30: return "putter or chip with a pitching wedge"
        case 31...50: return "sand wedge (56°)"
        case 51...70: return "gap wedge (52°)"
        case 71...90: return "pitching wedge"
        case 91...110: return "9-iron"
        case 111...125: return "8-iron"
        case 126...140: return "7-iron"
        case 141...155: return "6-iron"
        case 156...170: return "5-iron or hybrid"
        case 171...185: return "4-iron or hybrid"
        case 186...200: return "3-hybrid or 5-wood"
        case 201...220: return "3-wood"
        case 221...: return "driver"
        default: return "7-iron (safe default)"
        }
    }

    private func buildSummary(_ round: GolfRound) -> String {
        let totalStrokes = round.holes.reduce(0) { $0 + $1.strokes }
        let totalPar = round.holes.reduce(0) { $0 + $1.par }
        let diff = totalStrokes - totalPar
        let diffStr = diff == 0 ? "Even par" : (diff > 0 ? "+\(diff)" : "\(diff)")

        let birdies = round.holes.filter { $0.strokes < $0.par }.count
        let pars = round.holes.filter { $0.strokes == $0.par }.count
        let bogeys = round.holes.filter { $0.strokes == $0.par + 1 }.count
        let doubles = round.holes.filter { $0.strokes >= $0.par + 2 }.count

        let duration = Date().timeIntervalSince(round.startDate)
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60

        var summary = "Round Summary — \(round.holes.count) holes\n"
        summary += "Total: \(totalStrokes) (\(diffStr))\n"
        summary += "Scoring: \(birdies) birdies, \(pars) pars, \(bogeys) bogeys, \(doubles) doubles+\n"
        summary += "Duration: \(hours)h \(minutes)m\n"

        if !round.shotLog.isEmpty {
            let avgDist = round.shotLog.reduce(0.0) { $0 + $1.distanceYards } / Double(round.shotLog.count)
            summary += "Average shot: \(Int(avgDist)) yards (\(round.shotLog.count) tracked shots)\n"

            // Best shot
            if let best = round.shotLog.max(by: { $0.distanceYards < $1.distanceYards }) {
                summary += "Longest: \(Int(best.distanceYards)) yards with \(best.club)"
            }
        }

        // Per-hole breakdown
        summary += "\n\nHole-by-hole:\n"
        for hole in round.holes {
            let d = hole.strokes - hole.par
            let emoji: String
            switch d {
            case ...(-2): emoji = "🦅"
            case -1: emoji = "🐦"
            case 0: emoji = "✅"
            case 1: emoji = "⬜"
            default: emoji = "🟥"
            }
            summary += "  #\(hole.number): \(hole.strokes) (par \(hole.par)) \(emoji)\n"
        }

        return summary
    }
}
