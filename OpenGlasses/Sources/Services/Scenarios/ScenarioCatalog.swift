import Foundation

/// What someone wants the app for first (Plan KH P1). The raw values are stored in
/// `ScenarioProgress`, so they never change.
enum ScenarioIntent: String, CaseIterable, Codable, Equatable, Sendable {
    case everyday
    case seeing
    case gettingAround
    case work
    case field

    /// The heading a person reads, on the Ready page and in Things to Try.
    var title: String {
        switch self {
        case .everyday: return String(localized: "Everyday life")
        case .seeing: return String(localized: "Reading and seeing")
        case .gettingAround: return String(localized: "Getting around")
        case .work: return String(localized: "Work")
        case .field: return String(localized: "On the job")
        }
    }

    /// One line under the title on the Ready page.
    var subtitle: String {
        switch self {
        case .everyday: return String(localized: "Your day, reminders, messages and home")
        case .seeing: return String(localized: "Notices, bills, signs and labels")
        case .gettingAround: return String(localized: "Places, parking and travel")
        case .work: return String(localized: "Meetings, email and research")
        case .field: return String(localized: "Jobs, manuals and readings")
        }
    }

    /// The intents the Ready page offers. `field` is not a choice: Field Assist decides it.
    static let offeredOnReadyPage: [ScenarioIntent] = [.everyday, .seeing, .gettingAround, .work]
}

/// What a scenario is about. Data only in Plan KH P1: nothing reads this yet. A later phase may rank
/// or swap scenarios by it, and that work is not here.
enum ScenarioTopic: String, CaseIterable, Codable, Equatable, Sendable {
    case calendar
    case errands
    case travel
    case home
    case health
    case work
    case people
    case reading
    case memory
    case goals
    case entertainment
}

/// One thing a scenario depends on, beyond a model that can answer. `ScenarioReadiness` reads these.
enum ScenarioNeed: Hashable, Sendable {
    /// A native tool, by the name it declares. `ScenarioCatalogTests` checks every one is real.
    case tool(String)
    /// Glasses added to this phone (Decision 5).
    case glasses
    /// User Memory on.
    case memoryOn
    /// Captions have run, so there is something to summarise.
    case captionHistory
    /// Field Assist on and licensed.
    case fieldAssist
    /// A Field Assist job open. Reading a value or searching the vault has no meaning without one.
    case fieldJobOpen
    /// A home the app can reach: Apple Home with a home in it, or Home Assistant.
    case homeControl
    /// My Manuals bought, with at least one manual in it.
    case myManuals
}

/// A situation, a result and what it needs (Plan KH): "A capability is something the app can do. A
/// feature is a situation, a result and what it needs."
///
/// **A scenario is a turn the wearer could have said** (Decision 2). `prompt` goes through the home
/// grid's seam exactly as a tile's does. Nothing here calls a tool, adds a capability or steps past
/// a tool's own confirmation: `reminder` and `goals` still read back, `send_message` still only
/// opens a message for the wearer to send, and acting tools still ask.
struct Scenario: Identifiable, Equatable, Sendable {
    /// Stable across releases: `ScenarioProgress` stores it, and the shelf's end depends on it.
    let id: String
    let intent: ScenarioIntent
    let title: String
    /// One line of situation, not a capability.
    let situation: String
    /// SF Symbol for the card.
    let icon: String
    let kind: HomeGridAction.Kind
    /// The user turn, in the app's language.
    let prompt: String
    let needs: Set<ScenarioNeed>
    let topics: Set<ScenarioTopic>
    /// Reaches a third party in a way its tools' `OfflineToolPolicy` class does not show, such as
    /// geocoding an address. HIPAA hides it (`ScenarioReadiness`).
    var reachesOutsidePhone: Bool = false

    /// The tools this scenario names.
    var toolNames: Set<String> {
        Set(needs.compactMap { need in
            if case .tool(let name) = need { return name }
            return nil
        })
    }

    /// The same shape a home grid tile has, so a scenario runs through `HomeGridDispatcher`.
    var action: HomeGridAction {
        HomeGridAction(id: "scenario-\(id)", label: title, icon: icon, kind: kind, prompt: prompt)
    }
}

/// Every scenario, in one place (Decision 1): the Ready page, the Voice tab's cards, Things to Try
/// and the spoken answer all read this.
///
/// Order matters twice: the shelf takes earlier scenarios first, and `ScenarioFirstRun` runs the
/// first ready prompt of an intent, so the first prompt of each intent must be safe to run from
/// a tap with nothing else said. Each prompt was written against its tool's description and
/// `execute`, so a wording here is usually doing a job:
///
///   - `day-ahead` names the calendar, reminders and weather instead of saying "brief me", because
///     `daily_briefing` refuses while My Day is off, and My Day is off by default.
///   - `arrive-reminder` asks for the address because `geofence` falls back to the *current* location
///     when it is given no address, which would silently arm the reminder where the wearer stands.
///   - `just-parked` saves the spot rather than asking for it, because `parking` has nothing to say
///     until a spot exists. `lights` lists before it acts, so a tap alone changes nothing at home.
///   - Reading and camera scenarios are `.photoPrompt`, which opens the phone's camera with a live
///     preview. A camera tool asked for by a `.prompt` on a phone shoots blind from the pocket.
enum ScenarioCatalog {

    /// The catalogue in the app's current language. Computed, so copy follows the language.
    static var all: [Scenario] {
        everyday + seeing + gettingAround + work + field
    }

    static func scenario(id: String) -> Scenario? {
        all.first { $0.id == id }
    }

    /// Every tool any scenario names.
    static var namedTools: Set<String> {
        all.reduce(into: Set<String>()) { $0.formUnion($1.toolNames) }
    }

    // MARK: - Everyday

    private static var everyday: [Scenario] {
        [
            Scenario(id: "day-ahead", intent: .everyday,
                     title: String(localized: "Before you leave the house"),
                     situation: String(localized: "Hear what today holds before you head out."),
                     icon: "sunrise", kind: .prompt,
                     prompt: String(localized: "Check my calendar for today and my reminders that are due, and tell me the weather here. Keep it short."),
                     needs: [.tool("calendar"), .tool("reminder"), .tool("get_weather")],
                     topics: [.calendar, .errands]),
            Scenario(id: "add-event", intent: .everyday,
                     title: String(localized: "Something for the calendar"),
                     situation: String(localized: "Say it while you remember it, and it goes in your calendar."),
                     icon: "calendar.badge.plus", kind: .prompt,
                     prompt: String(localized: "I want to add something to my calendar. Ask me what it is and when, add it, then tell me exactly what you added."),
                     needs: [.tool("calendar")], topics: [.calendar]),
            Scenario(id: "add-reminder", intent: .everyday,
                     title: String(localized: "A job you will forget"),
                     situation: String(localized: "Hand it over now and get reminded later."),
                     icon: "checklist", kind: .prompt,
                     prompt: String(localized: "Remind me about something. Ask me what it is and when, add it to my reminders, then read back what you added."),
                     needs: [.tool("reminder")], topics: [.errands]),
            Scenario(id: "quick-note", intent: .everyday,
                     title: String(localized: "A thought worth keeping"),
                     situation: String(localized: "Note it out loud before it goes."),
                     icon: "note.text", kind: .prompt,
                     prompt: String(localized: "I want to save a note. Ask me what to note, then save it and confirm in one line."),
                     needs: [.tool("save_note")], topics: [.memory]),
            Scenario(id: "what-to-wear", intent: .everyday,
                     title: String(localized: "Deciding what to wear"),
                     situation: String(localized: "Find out if you need a jacket or an umbrella."),
                     icon: "cloud.sun", kind: .prompt,
                     prompt: String(localized: "What's the weather here today, and will I need a jacket or an umbrella?"),
                     needs: [.tool("get_weather")], topics: [.errands]),
            Scenario(id: "text-someone", intent: .everyday,
                     title: String(localized: "A quick message"),
                     situation: String(localized: "Say what you mean, then check it and send it yourself."),
                     icon: "message", kind: .prompt,
                     prompt: String(localized: "Help me text someone. Ask me who it's for and what to say, then open the message so I can review it and send it myself."),
                     needs: [.tool("send_message")], topics: [.people]),
            Scenario(id: "remember-fact", intent: .everyday,
                     title: String(localized: "Something you keep looking up"),
                     situation: String(localized: "Tell it once, then ask for it in any conversation."),
                     icon: "brain", kind: .prompt,
                     prompt: String(localized: "I want you to remember something about me. Ask me what it is, remember it, then tell me in one line what you saved."),
                     needs: [.memoryOn], topics: [.memory]),
            Scenario(id: "what-you-know", intent: .everyday,
                     title: String(localized: "What it knows about you"),
                     situation: String(localized: "Hear what it remembers, and correct anything wrong."),
                     icon: "person.text.rectangle", kind: .prompt,
                     prompt: String(localized: "What do you remember about me?"),
                     needs: [.memoryOn, .tool("my_memory")], topics: [.memory]),
            Scenario(id: "remember-person", intent: .everyday,
                     title: String(localized: "A detail about someone"),
                     situation: String(localized: "Keep a birthday or a kid's name for next time you meet."),
                     icon: "person.2", kind: .prompt,
                     prompt: String(localized: "I want you to remember something about someone I know. Ask me who it is and what to remember, save it, then confirm in one line."),
                     needs: [.tool("social_context")], topics: [.people, .memory]),
            Scenario(id: "remember-object", intent: .everyday,
                     title: String(localized: "Somewhere safe"),
                     situation: String(localized: "Say where you put it, and ask when you can't find it."),
                     icon: "key", kind: .prompt,
                     prompt: String(localized: "I've just put something somewhere I'll want to find later. Ask me what it is and where I put it, then save it and confirm."),
                     needs: [.tool("object_memory")], topics: [.memory, .home]),
            Scenario(id: "play-music", intent: .everyday,
                     title: String(localized: "Music with your hands full"),
                     situation: String(localized: "Ask for what you feel like hearing."),
                     icon: "music.note", kind: .prompt,
                     prompt: String(localized: "Put some music on. Ask me what I feel like hearing, then play it."),
                     needs: [.tool("music_control")], topics: [.entertainment]),
            Scenario(id: "name-that-song", intent: .everyday,
                     title: String(localized: "What is this song?"),
                     situation: String(localized: "Find out what's playing around you."),
                     icon: "waveform", kind: .prompt,
                     prompt: String(localized: "What song is this? Listen and tell me the title and the artist."),
                     needs: [.tool("identify_song")], topics: [.entertainment]),
            Scenario(id: "split-bill", intent: .everyday,
                     title: String(localized: "Splitting the bill"),
                     situation: String(localized: "Work out each share without opening a calculator."),
                     icon: "percent", kind: .prompt,
                     prompt: String(localized: "Help me split a bill. Ask me the total, the tip and how many people, then tell me what each person pays."),
                     needs: [.tool("calculate")], topics: [.errands, .people]),
            Scenario(id: "how-i-slept", intent: .everyday,
                     title: String(localized: "How you slept"),
                     situation: String(localized: "Hear last night's sleep from Apple Health."),
                     icon: "bed.double", kind: .prompt,
                     prompt: String(localized: "How did I sleep last night?"),
                     needs: [.tool("health_summary")], topics: [.health]),
            Scenario(id: "start-workout", intent: .everyday,
                     title: String(localized: "Starting a workout"),
                     situation: String(localized: "Track it without touching your phone."),
                     icon: "figure.run", kind: .prompt,
                     prompt: String(localized: "I'm starting a workout. Ask me what kind, then start tracking it and tell me how to stop."),
                     needs: [.tool("fitness_coach")], topics: [.health]),
            Scenario(id: "lights", intent: .everyday,
                     title: String(localized: "Hands full at home"),
                     situation: String(localized: "Turn off the lights in your own words."),
                     icon: "lightbulb", kind: .prompt,
                     prompt: String(localized: "List the lights and rooms you can control at home, then ask me which ones to turn off."),
                     needs: [.tool("smart_home"), .homeControl], topics: [.home]),
            Scenario(id: "goal-make", intent: .everyday,
                     title: String(localized: "Something you want done"),
                     situation: String(localized: "Turn it into a goal with a few steps."),
                     icon: "flag", kind: .prompt,
                     prompt: String(localized: "Let's make a goal. Ask me what I want to get done and by when, suggest a few steps, and read it back before you save it."),
                     needs: [.tool("goals")], topics: [.goals]),
            Scenario(id: "goal-progress", intent: .everyday,
                     title: String(localized: "How your goals are going"),
                     situation: String(localized: "Check where things stand."),
                     icon: "flag.checkered", kind: .prompt,
                     prompt: String(localized: "How are my goals going? Give me one line for each."),
                     needs: [.tool("goals")], topics: [.goals]),
            Scenario(id: "whats-next", intent: .everyday,
                     title: String(localized: "What's next?"),
                     situation: String(localized: "Hear the next goal step and anything waiting on you."),
                     icon: "arrow.forward.circle", kind: .prompt,
                     prompt: String(localized: "What's next?"),
                     needs: [.tool("activity")], topics: [.goals]),
            Scenario(id: "what-done", intent: .everyday,
                     title: String(localized: "What it did for you"),
                     situation: String(localized: "Hear what it has added or sent today."),
                     icon: "list.bullet.clipboard", kind: .prompt,
                     prompt: String(localized: "What have you done today?"),
                     needs: [.tool("activity")], topics: [.goals, .memory]),
            Scenario(id: "where-it-goes", intent: .everyday,
                     title: String(localized: "Where your words go"),
                     situation: String(localized: "Hear what stays on this phone and what doesn't."),
                     icon: "hand.raised", kind: .prompt,
                     prompt: String(localized: "How are my requests processed right now? Tell me where what I say and what I show you goes."),
                     needs: [.tool("processing_summary")], topics: [.memory]),
        ]
    }

    // MARK: - Reading and seeing

    private static var seeing: [Scenario] {
        [
            Scenario(id: "notice-to-calendar", intent: .seeing,
                     title: String(localized: "A notice or invitation"),
                     situation: String(localized: "Photograph it, and the date goes in your calendar."),
                     icon: "calendar.badge.plus", kind: .photoPrompt,
                     prompt: String(localized: "Read this image and create a calendar event from the date, time, place and title you find in it. Ask me only if the date or time is genuinely unclear, then tell me what you created."),
                     needs: [.tool("calendar")], topics: [.calendar, .reading]),
            Scenario(id: "bill-to-reminder", intent: .seeing,
                     title: String(localized: "A bill with a due date"),
                     situation: String(localized: "Photograph it, and get reminded before it's due."),
                     icon: "doc.text", kind: .photoPrompt,
                     prompt: String(localized: "Read this bill and add a reminder to pay it on its due date, with who it's to and the amount in the title. Ask me only if the due date is unclear, then tell me what you added."),
                     needs: [.tool("reminder")], topics: [.errands, .reading]),
            Scenario(id: "translate-sign", intent: .seeing,
                     title: String(localized: "A sign or menu in another language"),
                     situation: String(localized: "Show it and read it in your own."),
                     icon: "character.bubble", kind: .photoPrompt,
                     prompt: String(localized: "Translate the sign or menu in this image into the language I'm speaking to you in. Keep the line order."),
                     needs: [.tool("translate_sign_menu")], topics: [.travel, .reading]),
            Scenario(id: "read-aloud", intent: .seeing,
                     title: String(localized: "Small print"),
                     situation: String(localized: "Have it read to you, word for word."),
                     icon: "text.magnifyingglass", kind: .photoPrompt,
                     prompt: String(localized: "Read out the text in this image exactly as written, in reading order. Don't summarise or add commentary."),
                     needs: [], topics: [.reading]),
            Scenario(id: "whats-this", intent: .seeing,
                     title: String(localized: "What am I looking at?"),
                     situation: String(localized: "Show it something you can't name."),
                     icon: "eye", kind: .photoPrompt,
                     prompt: String(localized: "What is this? Tell me in two short sentences."),
                     needs: [], topics: [.reading]),
            Scenario(id: "receipt-note", intent: .seeing,
                     title: String(localized: "A receipt to keep"),
                     situation: String(localized: "Keep the shop, date and total without keeping the paper."),
                     icon: "receipt", kind: .photoPrompt,
                     prompt: String(localized: "Read this receipt and save a note with the shop, the date and the total. Then tell me what you saved."),
                     needs: [.tool("save_note")], topics: [.errands, .reading]),
            Scenario(id: "card-note", intent: .seeing,
                     title: String(localized: "A business card"),
                     situation: String(localized: "Keep the details from a card someone gave you."),
                     icon: "person.crop.rectangle", kind: .photoPrompt,
                     prompt: String(localized: "Read this business card and tell me the name, company, phone and email. Then ask me if you should save them as a note."),
                     needs: [.tool("save_note")], topics: [.people, .work]),
            Scenario(id: "meal-estimate", intent: .seeing,
                     title: String(localized: "What's on your plate"),
                     situation: String(localized: "Get a rough idea of a meal. It's an estimate."),
                     icon: "fork.knife", kind: .photoPrompt,
                     prompt: String(localized: "Give me a rough estimate of the calories and protein in this meal, and say it's an estimate."),
                     needs: [.tool("analyze_food")], topics: [.health]),
            Scenario(id: "remember-label", intent: .seeing,
                     title: String(localized: "A label to remember"),
                     situation: String(localized: "A Wi-Fi code or a paint colour you'll want again."),
                     icon: "tag", kind: .photoPrompt,
                     prompt: String(localized: "Read this image and remember what it says for later, then tell me in one line what you saved."),
                     needs: [.memoryOn], topics: [.memory, .reading]),
            // These three are registered only with Accessibility on, so they appear only then.
            Scenario(id: "which-note", intent: .seeing,
                     title: String(localized: "Which banknote is this?"),
                     situation: String(localized: "Check a note you can't make out."),
                     icon: "banknote", kind: .photoPrompt,
                     prompt: String(localized: "Identify this banknote: tell me the currency and the amount in one short sentence. If it isn't clearly a banknote, say so and don't guess."),
                     needs: [.tool("identify_money")], topics: [.reading]),
            Scenario(id: "which-colour", intent: .seeing,
                     title: String(localized: "What colour is this?"),
                     situation: String(localized: "Check a colour before you wear it or match it."),
                     icon: "paintpalette", kind: .photoPrompt,
                     prompt: String(localized: "What colour is the main thing in this picture?"),
                     needs: [.tool("identify_color")], topics: [.reading]),
            Scenario(id: "label-question", intent: .seeing,
                     title: String(localized: "A date on a label"),
                     situation: String(localized: "Find the one thing you need from the packet."),
                     icon: "calendar.circle", kind: .photoPrompt,
                     prompt: String(localized: "Read this label and tell me the expiry or best-before date. If you can't see one, say so."),
                     needs: [.tool("reading_assist")], topics: [.reading, .errands]),
            // Needs the glasses' camera: the coach watches a live picture, which a phone in a
            // pocket cannot give it.
            Scenario(id: "live-coach", intent: .seeing,
                     title: String(localized: "Practising something"),
                     situation: String(localized: "Get feedback as you go, through your glasses."),
                     icon: "figure.strengthtraining.traditional", kind: .prompt,
                     prompt: String(localized: "Coach me through what I'm practising. Ask me what it is, then start live coaching and tell me how to stop."),
                     needs: [.tool("live_coach"), .glasses], topics: [.health]),
        ]
    }

    // MARK: - Getting around

    private static var gettingAround: [Scenario] {
        [
            Scenario(id: "where-am-i", intent: .gettingAround,
                     title: String(localized: "Not sure where you are"),
                     situation: String(localized: "Hear the name of the place you're in."),
                     icon: "location", kind: .prompt,
                     prompt: String(localized: "Where am I right now?"),
                     needs: [.tool("where_am_i")], topics: [.travel]),
            Scenario(id: "find-nearby", intent: .gettingAround,
                     title: String(localized: "Looking for something close by"),
                     situation: String(localized: "A pharmacy, a cafe, somewhere to fill up."),
                     icon: "mappin.and.ellipse", kind: .prompt,
                     prompt: String(localized: "Help me find something nearby. Ask me what I'm looking for, then tell me the closest few."),
                     needs: [.tool("find_nearby")], topics: [.travel, .errands]),
            Scenario(id: "walk-there", intent: .gettingAround,
                     title: String(localized: "Walking somewhere new"),
                     situation: String(localized: "Turn-by-turn directions, spoken as you walk."),
                     icon: "figure.walk", kind: .prompt,
                     prompt: String(localized: "Walk me somewhere. Ask me where to, then start walking directions."),
                     needs: [.tool("navigate")], topics: [.travel]),
            Scenario(id: "drive-there", intent: .gettingAround,
                     title: String(localized: "Heading out in the car"),
                     situation: String(localized: "Directions open in your maps app."),
                     icon: "car", kind: .prompt,
                     prompt: String(localized: "I need directions. Ask me where to, then open them in my maps app."),
                     needs: [.tool("get_directions")], topics: [.travel]),
            Scenario(id: "just-parked", intent: .gettingAround,
                     title: String(localized: "Just parked"),
                     situation: String(localized: "Save the spot, then ask where you parked when you're back."),
                     icon: "parkingsign", kind: .prompt,
                     prompt: String(localized: "Remember where I parked. Ask me for the level or space if there is one, then save the spot here and confirm."),
                     needs: [.tool("parking")], topics: [.travel, .errands]),
            Scenario(id: "arrive-reminder", intent: .gettingAround,
                     title: String(localized: "An errand you will forget"),
                     situation: String(localized: "Get reminded when you arrive, not at a set time."),
                     icon: "bell.badge", kind: .prompt,
                     prompt: String(localized: "I want a reminder when I arrive somewhere. Ask me for the place's address and what to remind me, set it up for that address, then tell me the address you used."),
                     needs: [.tool("geofence")], topics: [.errands, .travel],
                     reachesOutsidePhone: true),
            Scenario(id: "translate-phrase", intent: .gettingAround,
                     title: String(localized: "Saying something in another language"),
                     situation: String(localized: "Get the words you need."),
                     icon: "globe", kind: .prompt,
                     prompt: String(localized: "Translate something for me. Ask me what I want to say and which language, then give me the translation."),
                     needs: [.tool("translate")], topics: [.travel, .people]),
            Scenario(id: "local-phrases", intent: .gettingAround,
                     title: String(localized: "Somewhere new"),
                     situation: String(localized: "Learn a polite hello and thank you for where you are."),
                     icon: "airplane", kind: .prompt,
                     prompt: String(localized: "Teach me how to say hello and thank you in the local language here, with how to pronounce them."),
                     needs: [.tool("ask_local_phrase")], topics: [.travel, .people]),
            Scenario(id: "currency", intent: .gettingAround,
                     title: String(localized: "Prices in another currency"),
                     situation: String(localized: "Know what it costs in your own money."),
                     icon: "dollarsign.arrow.circlepath", kind: .prompt,
                     prompt: String(localized: "Convert some money for me. Ask me the amount and the two currencies, then tell me the result."),
                     needs: [.tool("convert_currency")], topics: [.travel, .errands]),
            // Registered only with Accessibility on.
            Scenario(id: "walk-guide", intent: .gettingAround,
                     title: String(localized: "Help on an unfamiliar path"),
                     situation: String(localized: "Hear steps, doors and obstacles as you walk."),
                     icon: "figure.walk.motion", kind: .prompt,
                     prompt: String(localized: "Start guiding me as I walk, and tell me how to stop."),
                     needs: [.tool("navigation_assist")], topics: [.travel]),
        ]
    }

    // MARK: - Work

    private static var work: [Scenario] {
        [
            Scenario(id: "meeting-prep", intent: .work,
                     title: String(localized: "Your next meeting"),
                     situation: String(localized: "Hear what's coming up and how long you have."),
                     icon: "calendar", kind: .prompt,
                     prompt: String(localized: "What's my next calendar event, when does it start and where is it?"),
                     needs: [.tool("calendar")], topics: [.work, .calendar]),
            Scenario(id: "week-ahead", intent: .work,
                     title: String(localized: "Planning the week"),
                     situation: String(localized: "See the shape of the next seven days."),
                     icon: "calendar.day.timeline.left", kind: .prompt,
                     prompt: String(localized: "What's on my calendar for the next seven days? Group it by day, in short lines."),
                     needs: [.tool("calendar")], topics: [.work, .calendar]),
            Scenario(id: "draft-email", intent: .work,
                     title: String(localized: "An email you've been putting off"),
                     situation: String(localized: "Say the gist, then check it and send it yourself."),
                     icon: "envelope", kind: .prompt,
                     prompt: String(localized: "Help me write an email. Ask me who it's to and what it should say, then open it so I can review it and send it myself."),
                     needs: [.tool("send_via")], topics: [.work, .people]),
            Scenario(id: "record-meeting", intent: .work,
                     title: String(localized: "A meeting worth keeping"),
                     situation: String(localized: "Record it with a live transcript. Let people know first."),
                     icon: "waveform.circle", kind: .prompt,
                     prompt: String(localized: "Ask me to confirm everyone here knows they're being recorded. If I say yes, start an audio recording of this meeting and tell me how to stop it."),
                     needs: [.tool("audio_recording")], topics: [.work]),
            Scenario(id: "meeting-summary", intent: .work,
                     title: String(localized: "After a meeting with captions on"),
                     situation: String(localized: "Turn what was said into notes and actions."),
                     icon: "text.bubble", kind: .prompt,
                     prompt: String(localized: "Summarise that meeting: the key points, the decisions and the action items."),
                     needs: [.tool("meeting_summary"), .captionHistory], topics: [.work]),
            Scenario(id: "quick-research", intent: .work,
                     title: String(localized: "A question you need answered"),
                     situation: String(localized: "Get a short answer with sources."),
                     icon: "magnifyingglass", kind: .prompt,
                     prompt: String(localized: "Look something up for me. Ask me what I want to know, then search the web and give me three short points with sources."),
                     needs: [.tool("web_search")], topics: [.work]),
            Scenario(id: "focus-session", intent: .work,
                     title: String(localized: "Getting your head down"),
                     situation: String(localized: "Twenty-five minutes of focus, then a break."),
                     icon: "timer", kind: .prompt,
                     prompt: String(localized: "Start a focus session."),
                     needs: [.tool("pomodoro")], topics: [.work]),
            Scenario(id: "ask-my-manual", intent: .work,
                     title: String(localized: "An appliance or gadget manual"),
                     situation: String(localized: "Ask your own manuals and get the page."),
                     icon: "book", kind: .prompt,
                     prompt: String(localized: "I have a question for my manuals. Ask me what it is, look it up, and tell me the page."),
                     needs: [.tool("manual_lookup"), .myManuals], topics: [.home, .reading]),
            Scenario(id: "study-deck", intent: .work,
                     title: String(localized: "Something you need to learn"),
                     situation: String(localized: "Turn your notes into flashcards and a quiz."),
                     icon: "rectangle.on.rectangle", kind: .prompt,
                     prompt: String(localized: "Help me study. Ask me for the text I need to learn, make flashcards from it, then quiz me one card at a time."),
                     needs: [.tool("study")], topics: [.work, .reading]),
        ]
    }

    // MARK: - Field Assist

    private static var field: [Scenario] {
        [
            Scenario(id: "field-start-job", intent: .field,
                     title: String(localized: "First job"),
                     situation: String(localized: "Open a job and keep the record as you work."),
                     icon: "wrench.and.screwdriver", kind: .prompt,
                     prompt: String(localized: "I want to start a job. Ask me for the job number and what we're working on first, then start it."),
                     needs: [.tool("field_session"), .fieldAssist], topics: [.work]),
            Scenario(id: "field-ask-vault", intent: .field,
                     title: String(localized: "A question on site"),
                     situation: String(localized: "Ask the manuals and get an answer with its page."),
                     icon: "book.pages", kind: .prompt,
                     prompt: String(localized: "I have a question for the manuals. Ask me what it is, look it up, and cite the page."),
                     needs: [.tool("manual_lookup"), .fieldAssist, .fieldJobOpen], topics: [.work, .reading]),
            Scenario(id: "field-nameplate", intent: .field,
                     title: String(localized: "A nameplate or fault code"),
                     situation: String(localized: "Photograph it and go straight to the manual."),
                     icon: "barcode.viewfinder", kind: .photoPrompt,
                     prompt: String(localized: "This is a nameplate or a fault display. Read the model and any fault code, look them up in the manuals, and cite the page."),
                     needs: [.tool("manual_lookup"), .fieldAssist, .fieldJobOpen], topics: [.work, .reading]),
            Scenario(id: "field-log-reading", intent: .field,
                     title: String(localized: "A reading off the machine"),
                     situation: String(localized: "Say it and it goes on the job record."),
                     icon: "gauge.with.dots.needle.33percent", kind: .prompt,
                     prompt: String(localized: "Record a reading on this job. Ask me what it is and the value, then read it back."),
                     needs: [.tool("reading"), .fieldAssist, .fieldJobOpen], topics: [.work]),
            Scenario(id: "field-van-stock", intent: .field,
                     title: String(localized: "What's running low on the van"),
                     situation: String(localized: "Check your stock before you leave the shop."),
                     icon: "shippingbox", kind: .prompt,
                     prompt: String(localized: "What has run out or is low on my van?"),
                     needs: [.tool("van_stock"), .fieldAssist], topics: [.work, .errands]),
            Scenario(id: "field-safety", intent: .field,
                     title: String(localized: "A check before you start"),
                     situation: String(localized: "Look for high-energy hazards without a control. It's advisory."),
                     icon: "exclamationmark.triangle", kind: .prompt,
                     prompt: String(localized: "Run a safety assessment on what the camera can see, and tell me anything without a direct control."),
                     needs: [.tool("safety_assessment"), .fieldAssist], topics: [.work]),
        ]
    }
}
