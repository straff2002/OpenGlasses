import Foundation

/// One spoken sentence per metric, from numbers the aggregators already computed.
///
/// Rounded for the ear — heart rate to the beat, sleep to ten minutes, steps to the hundred — and
/// locale-aware. It reports; it never interprets. Nothing here says whether a number is good, bad,
/// normal or worth seeing somebody about: "is that normal?" is a follow-up for the model, and only
/// when the wearer has let the model see the numbers.
///
/// Every phrase is computed against `now`, from absolute timestamps, so a summary read from the
/// locked-phone cache is phrased as truthfully as a fresh one: an old heart-rate reading stops
/// being "recent", yesterday's step count is not today's, and a count that may have moved since
/// it was read says when it was read ("As of 8:10 AM, …").
struct HealthSummaryPhraser {

    let locale: Locale
    let calendar: Calendar

    init(locale: Locale = .current, calendar: Calendar = .current) {
        var calendar = calendar
        calendar.locale = locale
        self.locale = locale
        self.calendar = calendar
    }

    // MARK: - Honest absences

    static let noHeartRate =
        "I don't have heart-rate readings in Apple Health; those come from a watch or another wearable."
    static let noSleep =
        "I don't have sleep data for last night; sleep comes from a watch, a sleep schedule or another sleep tracker."
    static let noSteps = "I don't have a step count for today yet."
    static let noData = "I don't have heart-rate, sleep or step data from Apple Health yet."
    static let healthUnavailable = "Apple Health isn't available on this device."
    static let needsPermission =
        "I need permission to read Apple Health first. Open Avenkin on your phone, then Settings, Privacy, Health."
    static let lockedNoCache = "I can read Apple Health once your phone is unlocked."
    static let readFailed = "I couldn't read Apple Health just now."

    /// A summary younger than this is spoken as current, without an "as of" lead.
    static let freshness: TimeInterval = 10 * 60

    // MARK: - Heart rate

    func heartRate(_ summary: HeartRateSummary?, now: Date) -> String {
        let latest = HeartRateSummary.recent(summary?.latest, now: now)
        let resting = restingReading(summary, now: now)
        switch (latest, resting) {
        case let (latest?, resting?):
            return "Your heart rate was \(bpm(latest)) beats per minute \(age(of: latest, now: now)); "
                + "resting \(bpm(resting)) \(dayName(resting.date, now: now))."
        case let (latest?, nil):
            return "Your heart rate was \(bpm(latest)) beats per minute \(age(of: latest, now: now))."
        case let (nil, resting?):
            return "There's no heart-rate reading from the last two hours; your resting rate was "
                + "\(bpm(resting)) \(dayName(resting.date, now: now))."
        case (nil, nil):
            return Self.noHeartRate
        }
    }

    // MARK: - Sleep

    func sleep(_ night: SleepNight?, now: Date) -> String {
        sleepSentence(night, now: now, detailed: true) ?? Self.noSleep
    }

    // MARK: - Steps

    func steps(_ steps: StepComparison?, now: Date) -> String {
        guard let steps, calendar.isDate(steps.asOf, inSameDayAs: now) else { return Self.noSteps }
        let comparison = stepComparison(steps)
        if let lead = asOfLead(steps.asOf, now: now) {
            return "\(lead), you'd taken \(stepCount(steps.today)) today\(comparison.map { ", \($0) by then" } ?? "")."
        }
        return "You've taken \(stepCount(steps.today)) so far today\(comparison.map { ", \($0) by now" } ?? "")."
    }

    // MARK: - Overview (at most two sentences)

    func overview(heartRate: HeartRateSummary?, sleep: SleepNight?, steps: StepComparison?,
                  now: Date) -> String {
        let first = sleepSentence(sleep, now: now, detailed: false)

        var fragments: [String] = []
        if let steps, calendar.isDate(steps.asOf, inSameDayAs: now) {
            if let lead = asOfLead(steps.asOf, now: now) {
                fragments.append("\(lead.lowercasedFirst) you'd taken \(stepCount(steps.today)) today")
            } else {
                fragments.append("you've taken \(stepCount(steps.today)) so far today")
            }
        }
        if let resting = restingReading(heartRate, now: now) {
            fragments.append("your resting heart rate was \(bpm(resting)) \(dayName(resting.date, now: now))")
        }
        let second = fragments.isEmpty ? nil : fragments.joined(separator: ", and ").capitalizedFirst + "."

        let sentences = [first, second].compactMap { $0 }
        return sentences.isEmpty ? Self.noData : sentences.joined(separator: " ")
    }

    // MARK: - Age of a cached number

    /// "As of 8:10 AM", "As of yesterday at 9:40 PM" — or nil when `asOf` is fresh enough to speak
    /// as current.
    func asOfLead(_ asOf: Date, now: Date) -> String? {
        guard now.timeIntervalSince(asOf) > Self.freshness else { return nil }
        let time = timeFormatter.string(from: asOf)
        if calendar.isDate(asOf, inSameDayAs: now) { return "As of \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(asOf, inSameDayAs: yesterday) {
            return "As of yesterday at \(time)"
        }
        return "As of \(weekdayFormatter.string(from: asOf)) at \(time)"
    }

    // MARK: - Pieces

    private func sleepSentence(_ night: SleepNight?, now: Date, detailed: Bool) -> String? {
        guard let night, let nightName = nightName(night, now: now) else { return nil }
        // A summary read before the window closed may be of a night that was still going on.
        let lead = night.asOf < night.windowEnd ? asOfLead(night.asOf, now: now) : nil

        var sentence: String
        if let asleep = night.asleep, roundedToTenMinutes(asleep) > 0 {
            sentence = "You slept \(duration(asleep)) \(nightName)"
            if detailed {
                if let stages = night.stages {
                    var parts: [String] = []
                    if roundedToTenMinutes(stages.deep) > 0 { parts.append("\(duration(stages.deep)) deep") }
                    if roundedToTenMinutes(stages.rem) > 0 { parts.append("\(duration(stages.rem)) REM") }
                    if !parts.isEmpty { sentence += ", including about " + parts.joined(separator: " and ") }
                }
                if night.awakenings > 0 { sentence += ", and woke \(times(night.awakenings))" }
            }
            sentence += "."
        } else if let inBed = night.inBed, roundedToTenMinutes(inBed) > 0 {
            sentence = "Apple Health recorded \(duration(inBed)) in bed \(nightName), but not time asleep."
        } else {
            return nil
        }
        guard let lead else { return sentence }
        let body = sentence.hasPrefix("You") ? sentence.lowercasedFirst : sentence
        return "\(lead), \(body)"
    }

    /// "last night" for the night that ended this morning, "the night before last" for the one
    /// before; anything older is not an answer to "how did I sleep".
    private func nightName(_ night: SleepNight, now: Date) -> String? {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(night.morning, inSameDayAs: today) { return "last night" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(night.morning, inSameDayAs: yesterday) {
            return "the night before last"
        }
        return nil
    }

    private func restingReading(_ summary: HeartRateSummary?, now: Date) -> HeartRateReading? {
        guard let resting = summary?.resting else { return nil }
        return HeartRateSummary.mostRecentResting([resting], now: now, calendar: calendar)
    }

    private func stepComparison(_ steps: StepComparison) -> String? {
        guard let usual = steps.usualByNow else { return nil }
        let difference = steps.today - usual
        let threshold = max(300, usual * 0.1)
        if abs(difference) < threshold { return "about your usual" }
        let amount = number(roundedToHundred(abs(difference)))
        return "about \(amount) \(difference > 0 ? "more" : "fewer") than usual"
    }

    private func stepCount(_ steps: Double) -> String {
        steps < 100 ? "fewer than 100 steps" : "\(number(roundedToHundred(steps))) steps"
    }

    private func bpm(_ reading: HeartRateReading) -> String {
        number(reading.beatsPerMinute.rounded())
    }

    private func age(of reading: HeartRateReading, now: Date) -> String {
        let minutes = now.timeIntervalSince(reading.date) / 60
        switch minutes {
        case ..<10: return "a few minutes ago"
        case ..<50: return "about \(number((minutes / 5).rounded() * 5)) minutes ago"
        case ..<90: return "about an hour ago"
        default: return "about two hours ago"
        }
    }

    private func dayName(_ date: Date, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        return "on \(weekdayFormatter.string(from: date))"
    }

    private func times(_ count: Int) -> String {
        switch count {
        case 1: return "once"
        case 2: return "twice"
        default: return "\(number(Double(count))) times"
        }
    }

    // MARK: - Rounding and formatting

    func roundedToTenMinutes(_ interval: TimeInterval) -> TimeInterval {
        (interval / 600).rounded() * 600
    }

    func roundedToHundred(_ value: Double) -> Double {
        (value / 100).rounded() * 100
    }

    func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: roundedToTenMinutes(interval)) ?? ""
    }

    func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private var weekdayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
