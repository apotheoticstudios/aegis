import Foundation

/// Maps, System Settings pages, volume and dark mode (#45), from the owner's own words.
extension ActionCommand {
    private static let fixedSystem: [(String, AppAutomation)] = [
        (
            #"^(?:turn|crank|bump) (?:it|the volume|the sound|the music) up(?: a bit| a little)?$|"#
                + #"^(?:turn up|increase|raise) the (?:volume|sound)$|^(?:volume|sound) up$|^louder$"#,
            .volumeUp
        ),
        (
            #"^(?:turn|bring) (?:it|the volume|the sound|the music) down(?: a bit| a little)?$|"#
                + #"^(?:turn down|decrease|lower|reduce) the (?:volume|sound)$|^(?:volume|sound) down$|^quieter$"#,
            .volumeDown
        ),
        (#"^unmute(?: the| my)?(?: sound| volume| audio| mac| computer)?$|^(?:turn|switch) (?:the )?sound (?:back )?on$"#, .unmute),
        (#"^mute(?: the| my)?(?: sound| volume| audio| mac| computer)?$|^(?:turn|switch) (?:the )?sound off$"#, .mute),
        (#"^(?:turn on|switch to|change to|use|enable|go to|go) dark mode$|^(?:turn|switch) dark mode on$|^dark mode(?: on)?$"#, .darkMode),
        (
            #"^(?:turn on|switch to|change to|use|enable|go to|go) light mode$|^(?:turn off|disable) dark mode$|"#
                + #"^(?:turn|switch) dark mode off$|^light mode(?: on)?$"#,
            .lightMode
        ),
    ]

    /// Maps, a Settings page, volume and dark mode, or nil.
    static func system(_ line: String) -> ActionCommand? {
        let page = #"^(?:open|show(?: me)?|go to|bring up|pull up)(?: up)?(?: the| my)? (.+?) (?:settings|preferences|pane|page)"#
            + #"(?: in system settings)?$"#
        if let name = capture(page, line) ?? capture(#"^(?:open )?(?:system )?settings (?:for|on) (.+)$"#, line),
           let key = SettingsPage.key(name)
        {
            return .automate(.settingsPage, argument: key)
        }
        let route = #"^(?:(?:get|give me|show me|find) )?directions to (.+?)(?: (?:in|on|with) (?:apple )?maps)?$"#
        if let place = capture(route, line) ?? capture(#"^navigate to (.+?)(?: (?:in|on|with) (?:apple )?maps)?$"#, line),
           website(place) == nil
        {
            return .automate(.mapsDirections, argument: place)
        }
        if let query = capture(#"^(?:find|search for|look up|search|show(?: me)?|open|locate) (.+?) (?:in|on) (?:apple )?maps$"#, line) {
            return .automate(.mapsSearch, argument: query)
        }
        let level = capture(
            #"^(?:set|turn|change|put) (?:the )?(?:volume|sound) (?:to|at|down to|up to) (\d{1,3})(?: ?%| percent)?$"#,
            line
        )
            ?? capture(#"^volume (?:to )?(\d{1,3})(?: ?%| percent)?$"#, line)
        if let level, let number = Int(level), number <= 100 {
            return .automate(.volumeSet, argument: String(number))
        }
        return fixedSystem.first { line.range(of: $0.0, options: [.regularExpression, .caseInsensitive]) != nil }
            .map { .automate($0.1, argument: "") }
    }
}

/// The System Settings pages Aegis may open by name (#45). Opening a page changes nothing; the owner does that.
public struct SettingsPage: Sendable {
    public let key: String
    public let name: String
    /// What the owner may call it, as a regular expression over the whole name.
    public let spoken: String
    /// The page's System Settings identifier.
    public let id: String

    public static let pages: [SettingsPage] = [
        .init(key: "wifi", name: "Wi-Fi", spoken: "wi-?fi|wireless|internet", id: "com.apple.wifi-settings-extension"),
        .init(key: "bluetooth", name: "Bluetooth", spoken: "bluetooth", id: "com.apple.BluetoothSettings"),
        .init(key: "network", name: "Network", spoken: "network|vpn", id: "com.apple.Network-Settings.extension"),
        .init(key: "sound", name: "Sound", spoken: "sound|audio|volume", id: "com.apple.Sound-Settings.extension"),
        .init(
            key: "displays",
            name: "Displays",
            spoken: "displays?|screen|monitors?|brightness",
            id: "com.apple.Displays-Settings.extension"
        ),
        .init(key: "battery", name: "Battery", spoken: "battery|energy|power", id: "com.apple.Battery-Settings.extension"),
        .init(key: "notifications", name: "Notifications", spoken: "notifications?", id: "com.apple.Notifications-Settings.extension"),
        .init(key: "focus", name: "Focus", spoken: "focus|do not disturb", id: "com.apple.Focus-Settings.extension"),
        .init(key: "keyboard", name: "Keyboard", spoken: "keyboard|dictation", id: "com.apple.Keyboard-Settings.extension"),
        .init(key: "trackpad", name: "Trackpad", spoken: "trackpad", id: "com.apple.Trackpad-Settings.extension"),
        .init(key: "mouse", name: "Mouse", spoken: "mouse", id: "com.apple.Mouse-Settings.extension"),
        .init(
            key: "privacy",
            name: "Privacy & Security",
            spoken: "privacy(?: (?:and|&) security)?|security|permissions",
            id: "com.apple.settings.PrivacySecurity.extension"
        ),
        .init(
            key: "update",
            name: "Software Update",
            spoken: "software ?updates?|updates?",
            id: "com.apple.Software-Update-Settings.extension"
        ),
        .init(
            key: "appearance",
            name: "Appearance",
            spoken: "appearance|dark mode|light mode",
            id: "com.apple.Appearance-Settings.extension"
        ),
        .init(key: "wallpaper", name: "Wallpaper", spoken: "wallpaper|background", id: "com.apple.Wallpaper-Settings.extension"),
        .init(key: "accessibility", name: "Accessibility", spoken: "accessibility", id: "com.apple.Accessibility-Settings.extension"),
        .init(key: "general", name: "General", spoken: "general", id: "com.apple.systempreferences.GeneralSettings"),
        .init(key: "storage", name: "Storage", spoken: "storage|disk space", id: "com.apple.settings.Storage"),
        .init(
            key: "dock",
            name: "Desktop & Dock",
            spoken: "desktop(?: (?:and|&) dock)?|dock|mission control",
            id: "com.apple.Desktop-Settings.extension"
        ),
        .init(key: "lockscreen", name: "Lock Screen", spoken: "lock ?screen|screen ?saver", id: "com.apple.Lock-Screen-Settings.extension"),
        .init(key: "screentime", name: "Screen Time", spoken: "screen ?time", id: "com.apple.Screen-Time-Settings.extension"),
        .init(
            key: "users",
            name: "Users & Groups",
            spoken: "users?(?: (?:and|&) groups)?",
            id: "com.apple.Users-Groups-Settings.extension"
        ),
        .init(
            key: "controlcenter",
            name: "Control Center",
            spoken: "control (?:center|centre)|menu bar",
            id: "com.apple.ControlCenter-Settings.extension"
        ),
        .init(key: "siri", name: "Siri", spoken: "siri|apple intelligence", id: "com.apple.Siri-Settings.extension"),
        .init(key: "spotlight", name: "Spotlight", spoken: "spotlight", id: "com.apple.Spotlight-Settings.extension"),
        .init(key: "timemachine", name: "Time Machine", spoken: "time machine|backups?", id: "com.apple.Time-Machine-Settings.extension"),
        .init(
            key: "printers",
            name: "Printers & Scanners",
            spoken: "printers?(?: (?:and|&) scanners?)?|scanners?",
            id: "com.apple.Print-Scan-Settings.extension"
        ),
    ]

    /// The page's key for what the owner called it ("Wi-Fi", "privacy and security") or for a key, or nil.
    public static func key(_ spoken: String) -> String? {
        let name = spoken.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: #"^(?:the|my) "#, with: "", options: .regularExpression)
        return pages.first { $0.key == name || name.range(of: "^(?:" + $0.spoken + ")$", options: .regularExpression) != nil }?.key
    }

    /// The page for a key.
    public static func page(_ key: String) -> SettingsPage? {
        pages.first { $0.key == key }
    }
}
