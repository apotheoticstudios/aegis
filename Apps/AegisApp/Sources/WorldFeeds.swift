import AegisKit
import Foundation

/// Air quality, eruptions and other disasters, space weather and Bureau of Meteorology warnings around home (ADR-0024),
/// for the brief and the owner's questions. Only the air-quality request carries a place, home rounded to about 10 km;
/// the rest are fetched whole and matched against home here.
enum WorldFeeds {
    /// The answer to "how's the air?", "any volcano alerts?", "any weather warnings?", "any aurora tonight?" or
    /// "any disasters near me?".
    static func answer(_ kind: WorldAlerts.Kind) async -> String {
        // App tests run inside Aegis: they stay offline.
        guard !WorldSidecar.isTestHost else { return "That isn't checked while testing." }
        guard let home = WorldHome.point else { return WorldWindow.noHome }
        switch kind {
        case .air:
            return await air(home) ?? "I couldn't get the air quality just now."
        case .volcanoes:
            guard let found = await disasters(home, only: "VO", days: 30) else { return "I couldn't get the eruption alerts just now." }
            let region = Int(WorldAlerts.regionKm).formatted()
            return found.isEmpty ? "No major eruptions within \(region) km of home in the last month." : found.map(\.text)
                .joined(separator: " ")
        case .disasters:
            guard let found = await disasters(home, days: 7) else { return "I couldn't get the disaster alerts just now." }
            let region = Int(WorldAlerts.regionKm).formatted()
            return found.isEmpty
                ? "No orange or red disaster alerts within \(region) km of home this week."
                : found.prefix(5).map(\.text).joined(separator: " ")
        case .space:
            return await space(home)?.answer ?? "I couldn't get NOAA's space weather just now."
        case .warnings:
            switch await warnings(home) {
            case .failed: return "I couldn't reach the Bureau of Meteorology just now."
            case .outside:
                return "Weather warnings come from Australia's Bureau of Meteorology, so they only work for a home in Australia."
            case let .found(found):
                return found.isEmpty ? "No Bureau of Meteorology warnings for your area right now." : found.joined(separator: ". ") + "."
            }
        }
    }

    /// The brief's lines: the air, any warnings for home (three at most), then what's new (#115): a storm that may show
    /// aurora at home, and disasters in the region this week, each for 12 hours after it first appears.
    static func briefLines(_ home: WorldHome.Point) async -> [String] {
        async let airLine = air(home)
        async let warned = warnings(home)
        async let regional = disasters(home, days: 7)
        async let spaceWeather = space(home)
        var lines = await airLine.map { [$0] } ?? []
        if case let .found(found) = await warned {
            lines += found.prefix(3)
        }
        let alerts = await [spaceWeather?.alert].compactMap(\.self) + (regional ?? [])
        let seen = UserDefaults.aegis.dictionary(forKey: "worldAlertsSeen") as? [String: Date] ?? [:]
        let fresh = WorldAlerts.fresh(alerts, firstSeen: seen, now: Date())
        UserDefaults.aegis.set(fresh.firstSeen, forKey: "worldAlertsSeen")
        return lines + fresh.alerts.map(\.text)
    }

    /// The world headlines (#116), the two feeds interleaved, pinned at the countries they name; nil when neither answers.
    static func headlines() async -> [WorldNews.Pin]? {
        guard !WorldSidecar.isTestHost else { return nil }
        async let bbc = feed(WorldNews.feeds[0])
        async let aljazeera = feed(WorldNews.feeds[1])
        let lists = await [bbc, aljazeera].compactMap(\.self).map(WorldNews.headlines)
        guard !lists.isEmpty, let table = try? Data(contentsOf: WorldNews.zoneTable) else { return nil }
        let mixed = (0 ..< (lists.map(\.count).max() ?? 0)).flatMap { index in lists.compactMap { index < $0.count ? $0[index] : nil } }
        return WorldNews.pins(mixed, countries: WorldNews.countries(zoneTab: table))
    }

    private static func feed(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return data
    }

    private static let session = URLSession(configuration: .ephemeral) // privacy-guard: allow-network air, disasters, Kp and news, ADR-0024

    private static func air(_ home: WorldHome.Point) async -> String? {
        guard let url = WorldAlerts.airURL(latitude: home.latitude, longitude: home.longitude),
              let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return WorldAlerts.air(data, now: Date())
    }

    private static func disasters(_ home: WorldHome.Point, only: String? = nil, days: Double) async -> [WorldAlerts.Alert]? {
        guard let url = WorldAlerts.disastersURL(now: Date()), let (data, response) = try? await session.data(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode, status == 200 || status == 204
        else { return nil }
        return WorldAlerts.disasters(data, only: only, latitude: home.latitude, longitude: home.longitude, now: Date(), days: days)
    }

    private static func space(_ home: WorldHome.Point) async -> (answer: String, alert: WorldAlerts.Alert?)? {
        guard let (data, response) = try? await session.data(from: WorldAlerts.spaceURL), (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return WorldAlerts.space(data, latitude: home.latitude, longitude: home.longitude, now: Date())
    }

    private enum Warnings {
        case found([String]), outside, failed
    }

    private static func warnings(_ home: WorldHome.Point) async -> Warnings {
        guard let towns = await table(WorldAlerts.bureauTowns), let gauges = await table(WorldAlerts.bureauGauges) else { return .failed }
        guard let area = WorldAlerts.bureauArea(towns: towns, gauges: gauges, latitude: home.latitude, longitude: home.longitude) else {
            return .outside
        }
        guard let listing = await ftp([WorldAlerts.bureauWarnings], list: true) else { return .failed }
        let files = WorldAlerts.bureauFiles(listing: String(bytes: listing, encoding: .utf8) ?? "", area: area)
        guard !files.isEmpty else { return .found([]) }
        // One connection for all of them; each file is its own XML document.
        guard let joined = await ftp(files.map { WorldAlerts.bureauWarnings.appendingPathComponent($0) }) else { return .failed }
        let found = (String(bytes: joined, encoding: .utf8) ?? "").components(separatedBy: "<?xml").flatMap {
            WorldAlerts.bureauWarnings(Data($0.utf8), area: area, now: Date())
        }
        return .found(found.reduce(into: []) {
            if !$0.contains($1) {
                $0.append($1)
            }
        })
    }

    /// The Bureau's towns or gauges table, kept a month in Aegis's World folder; the last copy if a refresh fails.
    private static func table(_ url: URL) async -> Data? {
        let folder = WorldSidecar.folder.deletingLastPathComponent().appendingPathComponent("bureau")
        let file = folder.appendingPathComponent(url.lastPathComponent)
        let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let saved, Date().timeIntervalSince(saved) < 30 * 86400, let data = try? Data(contentsOf: file) {
            return data
        }
        if let data = await ftp([url]), data.count > 1000 {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        }
        return try? Data(contentsOf: file)
    }

    /// Files or a folder listing from the Bureau's public FTP server. Apple's networking no longer speaks FTP, so macOS's own
    /// curl fetches them, FTP only, in one connection.
    private static func ftp(_ urls: [URL], list: Bool = false) async -> Data? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            // privacy-guard: allow-network Bureau of Meteorology public FTP, ADR-0024
            process.arguments = ["--silent", "--fail", "--proto", "=ftp", "--max-time", "60", "--max-filesize", "8000000"]
                + (list ? ["--list-only"] : []) + urls.map(\.absoluteString)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
    }
}
