import Foundation

extension Config {
    static var myDayCalendarIncluded: Bool {
        get { storedBool("myDayCalendarIncluded", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "myDayCalendarIncluded") }
    }

    static var myDayRemindersIncluded: Bool {
        get { storedBool("myDayRemindersIncluded", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "myDayRemindersIncluded") }
    }

    static var myDayWeatherIncluded: Bool {
        get { storedBool("myDayWeatherIncluded", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "myDayWeatherIncluded") }
    }

    static var myDayTravelIncluded: Bool {
        get { storedBool("myDayTravelIncluded", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "myDayTravelIncluded") }
    }

    static var myDayDigestIncluded: Bool {
        get { storedBool("myDayDigestIncluded", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "myDayDigestIncluded") }
    }

    static var myDayMorningDeliveryEnabled: Bool {
        get { storedBool("myDayMorningDeliveryEnabled", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "myDayMorningDeliveryEnabled") }
    }

    static var myDayMorningDeliveryMinutes: Int {
        get { boundedDayMinutes(storedInt("myDayMorningDeliveryMinutes", default: 8 * 60)) }
        set { UserDefaults.standard.set(boundedDayMinutes(newValue), forKey: "myDayMorningDeliveryMinutes") }
    }

    static var myDayEveningDeliveryEnabled: Bool {
        get { storedBool("myDayEveningDeliveryEnabled", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "myDayEveningDeliveryEnabled") }
    }

    static var myDayEveningDeliveryMinutes: Int {
        get { boundedDayMinutes(storedInt("myDayEveningDeliveryMinutes", default: 19 * 60)) }
        set { UserDefaults.standard.set(boundedDayMinutes(newValue), forKey: "myDayEveningDeliveryMinutes") }
    }

    static var myDayScheduledSpeechEnabled: Bool {
        get { storedBool("myDayScheduledSpeechEnabled", default: false) }
        set { UserDefaults.standard.set(newValue, forKey: "myDayScheduledSpeechEnabled") }
    }

    static var myDayQuietHoursEnabled: Bool {
        get { storedBool("myDayQuietHoursEnabled", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "myDayQuietHoursEnabled") }
    }

    static var myDayQuietStartMinutes: Int {
        get { boundedDayMinutes(storedInt("myDayQuietStartMinutes", default: 22 * 60)) }
        set { UserDefaults.standard.set(boundedDayMinutes(newValue), forKey: "myDayQuietStartMinutes") }
    }

    static var myDayQuietEndMinutes: Int {
        get { boundedDayMinutes(storedInt("myDayQuietEndMinutes", default: 7 * 60)) }
        set { UserDefaults.standard.set(boundedDayMinutes(newValue), forKey: "myDayQuietEndMinutes") }
    }

    static var myDayLastMorningDeliveryDay: String {
        get { UserDefaults.standard.string(forKey: "myDayLastMorningDeliveryDay") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "myDayLastMorningDeliveryDay") }
    }

    static var myDayLastEveningDeliveryDay: String {
        get { UserDefaults.standard.string(forKey: "myDayLastEveningDeliveryDay") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "myDayLastEveningDeliveryDay") }
    }

    static func resetMyDayDeliveryHistory() {
        myDayLastMorningDeliveryDay = ""
        myDayLastEveningDeliveryDay = ""
        myDayLastDeliveredLeaveByID = ""
    }

    private static func storedBool(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    private static func storedInt(_ key: String, default defaultValue: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? defaultValue
    }

    private static func boundedDayMinutes(_ value: Int) -> Int {
        min(23 * 60 + 59, max(0, value))
    }
}
