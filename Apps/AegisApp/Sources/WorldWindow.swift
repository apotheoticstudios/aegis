import AegisKit
import AppKit
import Observation
import OSLog
import SwiftUI
import WebKit

/// The brief's WORLD lines and the panel's World screen (#265, #299).
@MainActor
@Observable
final class WorldPresence {
    static let shared = WorldPresence()
    /// Today's weather at home and flight status for the brief (#265), newest first fetched when the panel opens.
    var briefLines: [String] = []
    @ObservationIgnored var briefFetched = Date.distantPast
    private(set) var inPanel = false
    @ObservationIgnored var presentationChanged: (Bool) -> Void = { _ in }

    func show() {
        guard !inPanel else { return }
        inPanel = true
        presentationChanged(true)
    }

    func close() {
        guard inPanel else { return }
        inPanel = false
        presentationChanged(false)
    }

    /// Whether weather and flight status go in the brief (on unless turned off under World view settings).
    static var briefEnabled: Bool {
        get { UserDefaults.aegis.object(forKey: "worldBriefEnabled") as? Bool ?? true }
        set { UserDefaults.aegis.set(newValue, forKey: "worldBriefEnabled") }
    }
}

/// The World view (#265, #299, ADR-0024): God's Eye View's live globe of public data inside the Aegis panel
/// with God's Eye View's own interface. The owner's World commands steer it through the globe's local tools and the
/// page's own actions. Its server runs only while the panel is open.
@MainActor
final class WorldWindow {
    static let shared = WorldWindow()

    /// Opens the Aegis panel when a menu or World command needs it. Installed at launch.
    var openPanel: (() -> Void)?
    /// Starts Aegis listening: God's Eye View's own voice button now talks to Aegis (#311). Installed at launch.
    var talk: (() -> Void)?
    private lazy var voiceBridge = WorldVoiceBridge { [weak self] in
        guard WorldPresence.shared.inPanel else { return }
        self?.talk?()
    }

    private var web: WKWebView?
    private var starting: Task<URL?, Never>?
    /// The last World question with a place, for "what about Sydney?" and "ships there" (#272).
    private var last: (command: WorldCommand, at: Date)?

    /// The last question's place while the conversation is about the globe (the last 10 minutes, globe showing).
    var recentPlace: String? {
        guard isOpen, let last, Date().timeIntervalSince(last.at) < 600 else { return nil }
        return last.command.place
    }

    private let sidecar = WorldSidecar()
    private let log = Logger(subsystem: "dev.aegis.app", category: "world")

    var isOpen: Bool {
        WorldPresence.shared.inPanel
    }

    /// The Mac's time-zone city ("Brisbane"), for "where's the ISS?" without a place.
    static var homeCity: String? {
        TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
    }

    /// Opens the panel's World screen, retaining the globe when returning to the HUD.
    func show() {
        openPanel?()
        _ = prepare()
        WorldPresence.shared.show()
    }

    func close() {
        WorldPresence.shared.close()
    }

    /// Attaches the already loaded globe without reloading its page or changing its own interface.
    func present(in host: NSView) {
        guard let web, web.superview !== host else { return }
        web.removeFromSuperview()
        web.frame = host.bounds
        web.autoresizingMask = [.width, .height]
        host.addSubview(web)
    }

    /// Carries out the owner's World command and returns what to say. `schedule` reads the owner's calendar from
    /// AegisCore for "my trips" and "my flight"; those pins stay on this Mac.
    func run(_ command: WorldCommand, schedule: () async -> [CalendarOccurrence]) async -> String {
        switch command {
        case .open:
            show()
            return "Here's the world."
        case .close:
            close()
            return "World view closed."
        case let .declined(message):
            return message
        case .setHome:
            return await setHome()
        case .myHome:
            return await showHome()
        case .myTrips:
            return await showTrips(schedule())
        case .myFlight:
            return await followFlight(schedule())
        case let .tool(name, arguments):
            return await runTool(name, arguments)
        case let .action(name, arguments, said):
            return await runAction(name, arguments, said: said)
        case let .retarget(place):
            return await retarget(place)
        case let .alerts(kind):
            return await WorldFeeds.answer(kind)
        case .headlines:
            return await showHeadlines()
        }
    }

    /// World headlines, each pinned at the country it names (#116). Shown and read only, never acted on.
    private func showHeadlines() async -> String {
        guard let pins = await WorldFeeds.headlines() else { return "I couldn't get the world headlines just now." }
        guard !pins.isEmpty else { return WorldNews.answer(pins) }
        guard await opened(), let view = Self.object(WorldNews.view(pins)) else { return "The World view couldn't start." }
        await apply(view)
        return WorldNews.answer(pins)
    }

    private func retarget(_ place: String) async -> String {
        guard let again = last?.command.retargeted(to: place), case let .tool(name, arguments) = again else {
            return "What would you like to see there?"
        }
        return await runTool(name, arguments)
    }

    /// One of the globe's own controls, run in the page (#272).
    private func runAction(_ name: String, _ arguments: WorldValue, said: String) async -> String {
        guard await opened(), await ready(), let web, let object = Self.object(arguments) else {
            return "The World view couldn't start."
        }
        let script = "const result = await window.__gevVoiceCommands.runner(name, args, {}); return !(result && result.ok === false);"
        let done = try? await web.callAsyncJavaScript(script, arguments: ["name": name, "args": object], contentWorld: .page)
        return (done as? Bool) == false ? "The globe couldn't do that just now." : said
    }

    /// Runs actions the local model picked from God's Eye View's catalogue (#296), each through the page's own runner,
    /// and returns what God's Eye View says it did. A step that hangs gives up after 20 seconds.
    func run(_ actions: [WorldAction], fallback: String?) async -> String {
        guard await opened(), await ready(), let web else { return "The World view couldn't start." }
        var said: [String] = []
        var failed = false
        for action in actions {
            guard let arguments = Self.object(action.arguments) else { continue }
            let result = try? await web.callAsyncJavaScript(
                Self.runStep, arguments: ["name": action.name, "args": arguments], contentWorld: .page
            ) as? [String: Any]
            failed = failed || (result?["ok"] as? Bool) != true
            if let say = result?["say"] as? String, !say.isEmpty {
                said.append(say)
            }
        }
        if said.isEmpty {
            return failed ? "The globe couldn't do that just now." : fallback ?? "Done."
        }
        return said.prefix(3).joined(separator: " ")
    }

    private static let runStep = """
    const timeout = new Promise((done) => setTimeout(() => done({ ok: false, say: '' }), 20000));
    const step = Promise.resolve(window.__gevVoiceCommands.runner(name, args, {})).catch(() => ({ ok: false, say: '' }));
    const result = await Promise.race([step, timeout]);
    return { ok: !!result && result.ok !== false, say: result && typeof result.say === 'string' ? result.say : '' };
    """

    /// Shows the owner's latest question and Aegis's answer in God's Eye View's own voice card.
    func showCaption(question: String, answer: String) {
        guard WorldPresence.shared.inPanel, let web else { return }
        Task {
            _ = try? await web.callAsyncJavaScript(
                Self.voiceCard, arguments: ["question": question, "answer": answer], contentWorld: .page
            )
        }
    }

    private static let voiceButton = """
    document.addEventListener('click', (event) => {
      const button = event.target instanceof Element ? event.target.closest('#gev-voice-button') : null;
      if (!button || !event.isTrusted) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      window.webkit.messageHandlers.aegis.postMessage('talk');
    }, true);
    """

    private static let voiceCard = """
    const card = document.getElementById('gev-voice-card');
    if (!card) return false;
    const show = (id, text) => {
      const node = document.getElementById(id);
      if (!node) return;
      node.textContent = text;
      node.parentElement.hidden = !text;
    };
    show('gev-voice-card-user-text', question);
    show('gev-voice-card-assistant-text', answer);
    card.hidden = !question && !answer;
    return true;
    """

    /// The panel opened: if the World view was used in the last week, its server starts now so WORLD opens at once.
    func prewarm() {
        guard web == nil, WorldSidecar.isInstalled,
              Date().timeIntervalSince1970 - UserDefaults.aegis.double(forKey: "worldLastUsed") < 7 * 86400
        else { return }
        Task { _ = try? await sidecar.start() }
    }

    /// The panel closed: release the globe and stop even a warmed server.
    func panelClosed() {
        close()
        shutDownGlobe()
    }

    private func setHome() async -> String {
        guard let location = await HomeLocator().locate() else {
            return "I couldn't get this Mac's location. Allow Aegis under Location Services in System Settings, then try again."
        }
        let saved = WorldHome.save(.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
        return saved ? "Got it. This is home on the World view. It stays on this Mac." : "I couldn't save home. Try again?"
    }

    /// A pin at home, on the local globe only.
    private func showHome() async -> String {
        guard let home = WorldHome.point else { return Self.noHome }
        guard await opened() else { return "The World view couldn't start." }
        await apply([
            "camera": ["lat": home.latitude, "lon": home.longitude, "altitude_m": 25000, "heading_deg": 0, "pitch_deg": -90],
            "layers": [String](),
            "annotations": [["type": "pin", "latitude": home.latitude, "longitude": home.longitude, "label": "Home", "color": "primary"]],
        ])
        return "Here's home."
    }

    private func showTrips(_ events: [CalendarOccurrence]) async -> String {
        guard let view = OwnerPlaces.tripsView(events, now: Date(), calendar: .current), let object = Self.object(view) else {
            return "Nothing in your calendar for the next four weeks has a map location. Events whose place was "
                + "picked from Maps show up here."
        }
        guard await opened() else { return "The World view couldn't start." }
        await apply(object)
        let count = ((object["annotations"] as? [Any])?.count) ?? 0
        return count == 1 ? "Here's your next place." : "Here are your next \(count) places."
    }

    private func followFlight(_ events: [CalendarOccurrence]) async -> String {
        guard let flight = OwnerPlaces.nextFlight(events, now: Date()) else {
            return "I can't see a flight in your calendar in the next three days."
        }
        guard await opened(), let address = sidecar.address else { return "The World view couldn't start." }
        let arguments: WorldValue = .object(["callsign": .string(flight.callsign), "limit": .number(1)])
        guard let (summary, view) = await WorldClient.call("find_aircraft", arguments: arguments, at: address) else {
            return "The World view didn't answer that. Try again in a moment."
        }
        guard let view, view["follow"] != nil else {
            let time = flight.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return "\(flight.number) isn't in the air right now. It's in your calendar for \(time)."
        }
        await apply(view)
        return "\(flight.number) is in the air. " + summary
    }

    private func runTool(_ name: String, _ given: WorldValue) async -> String {
        var arguments = given
        if WorldCommand.needsHome(given) {
            guard let home = WorldHome.point else { return Self.noHome }
            arguments = WorldCommand.fillingHome(given, latitude: home.latitude, longitude: home.longitude)
        }
        guard await opened(), let address = sidecar.address else { return "The World view couldn't start." }
        guard let (summary, view) = await WorldClient.call(name, arguments: arguments, at: address) else {
            return "The World view didn't answer that. Try again in a moment."
        }
        if let view {
            await apply(view)
        }
        let command = WorldCommand.tool(name: name, arguments: given)
        if command.place != nil {
            last = (command, Date())
        }
        return summary
    }

    nonisolated static let noHome = "I don't know where home is yet. Say “set my home here” while you're at home."

    private func opened() async -> Bool {
        show()
        return await starting?.value != nil
    }

    /// The web view and its server, made once per open panel session.
    private func prepare() -> WKWebView {
        if let web {
            return web
        }
        UserDefaults.aegis.set(Date().timeIntervalSince1970, forKey: "worldLastUsed")
        let configuration = WKWebViewConfiguration()
        // God's Eye View keeps its own settings (welcome seen, layers, styles) in this Mac's web storage (#295).
        configuration.websiteDataStore = .default()
        // Aegis is God's Eye View's voice: its voice button starts Aegis listening instead of an OpenAI session.
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.voiceButton, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        configuration.userContentController.add(voiceBridge, name: "aegis")
        let created = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        created.loadHTMLString(Self.page("Starting the World view…"), baseURL: nil)
        web = created
        starting = Task { [weak self] in
            guard let self else { return nil }
            do {
                if !WorldSidecar.isInstalled {
                    try await sidecar.setUp { step in
                        created.loadHTMLString(
                            Self.page("Setting up the World view, one time only (about a minute)…<br><br>\(step)"),
                            baseURL: nil
                        )
                    }
                }
                guard !Task.isCancelled else { return nil }
                let address = try await sidecar.start()
                guard web === created else {
                    if web == nil {
                        sidecar.stop()
                    }
                    return nil
                }
                load(address)
                return address
            } catch let WorldSidecar.Problem.setupFailed(step) {
                created.loadHTMLString(
                    Self.page("The World view couldn't be set up (\(step)). Check the internet connection, then close it and try again."),
                    baseURL: nil
                )
            } catch WorldSidecar.Problem.noNode {
                created.loadHTMLString(Self.page("The World view needs Node.js 24 or 26 (brew install node)."), baseURL: nil)
            } catch {
                created.loadHTMLString(Self.page("The World view couldn't start. Close it and try again."), baseURL: nil)
            }
            return nil
        }
        return created
    }

    /// Shows a tool's view on the globe without reloading it. God's Eye View only
    /// takes posted views in its embed mode, so the view's steps run through the page's own actions instead (#295).
    private func apply(_ view: [String: Any]) async {
        guard await ready(), let web else { return }
        var view = view
        view["url"] = nil
        _ = try? await web.callAsyncJavaScript(Self.applyView, arguments: ["view": view], contentWorld: .page)
    }

    /// God's Eye View's own `applyView` (src/app/embed.js, MIT), on the page's actions and viewer: style and map,
    /// exactly the view's layers, annotations, then the camera or the followed aircraft or satellite.
    private static let applyView = """
    const gev = window.__godsEyeView, voice = window.__gevVoiceCommands;
    if (!gev || !voice) return false;
    const run = (name, args) => Promise.resolve(voice.runner(name, args, {})).catch(() => null);
    if (view.style) await run('set_visual_style', { style: view.style });
    if (view.map) await run('set_map_stack', { stack: view.map });
    const wanted = new Set(view.layers || []);
    for (const layer of gev.dataManager.getAll())
      if (layer.enabled && !wanted.has(layer.id)) await run('set_layer_visibility', { layerId: layer.id, enabled: false });
    for (const layerId of wanted)
      if (!gev.dataManager.isEnabled(layerId)) await run('set_layer_visibility', { layerId, enabled: true });
    if (!view.follow) await run('stop_tracking', {});
    await run('clear_annotations', {});
    if ((view.annotations || []).length) await run('annotate_map', { annotations: view.annotations });
    const camera = view.camera;
    if (camera) {
      window.dispatchEvent(new CustomEvent('gev:navigation-authority-taken', { detail: { reason: 'aegis-view', cancelPendingSelection: true } }));
      const Cartesian3 = gev.viewer.camera.position.constructor;
      gev.viewer.camera.flyTo({
        destination: Cartesian3.fromDegrees(camera.lon, camera.lat, camera.altitude_m),
        orientation: { heading: camera.heading_deg * Math.PI / 180, pitch: camera.pitch_deg * Math.PI / 180, roll: 0 },
        duration: 2,
      });
    }
    if (view.follow) {
      const layerId = { aircraft: 'flights', military_aircraft: 'military', satellite: 'satellites' }[view.follow.kind];
      for (let attempt = 0; attempt < 20; attempt++) {
        if ((await run('track_entity', { query: view.follow.id, layerId }))?.ok === true) break;
        await new Promise((done) => setTimeout(done, 1000));
      }
    }
    return true;
    """

    /// Waits until the globe takes views (its app actions are installed), up to about 30 seconds.
    private func ready() async -> Bool {
        guard await starting?.value != nil, let web else { return false }
        for _ in 0 ..< 120 {
            guard !Task.isCancelled, self.web === web else { return false }
            if let ok = try? await web.evaluateJavaScript("typeof window.__gevVoiceCommands !== 'undefined'") as? Bool, ok {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        log.notice("world: globe not ready in time")
        return false
    }

    private func load(_ address: URL) {
        web?.load(URLRequest(url: address)) // privacy-guard: allow-network World view on this Mac only
    }

    private static func object(_ value: WorldValue) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func shutDownGlobe() {
        web?.stopLoading()
        web?.loadHTMLString("", baseURL: nil)
        web?.removeFromSuperview()
        web = nil
        starting?.cancel()
        starting = nil
        sidecar.stop()
    }

    /// Aegis is quitting.
    func shutDown() {
        panelClosed()
        WorldSidecar.stopJob()
    }

    private static func page(_ message: String) -> String {
        "<html><body style=\"background:#05080c;color:#5ad8ff;font:15px -apple-system;display:flex;"
            + "align-items:center;justify-content:center;height:100vh;margin:0\">\(message)</body></html>"
    }
}

/// The globe's local tools (`/mcp` on 127.0.0.1, #265): one JSON-RPC call per command.
enum WorldClient {
    /// The tool's summary (without bracketed notes) and the view it suggests, or nil when it didn't answer.
    static func call(_ name: String, arguments: WorldValue, at address: URL) async -> (String, [String: Any]?)? {
        guard let encoded = try? JSONEncoder().encode(arguments),
              let object = try? JSONSerialization.jsonObject(with: encoded),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": object],
              ])
        else { return nil }
        let endpoint = address.appendingPathComponent("mcp")
        var request = URLRequest(url: endpoint, timeoutInterval: 30) // privacy-guard: allow-network World view on this Mac only
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let session = URLSession.shared // privacy-guard: allow-network World view on this Mac only
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = reply["result"] as? [String: Any]
        else { return nil }
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.first ?? ""
        let summary = text.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let structured = result["structuredContent"] as? [String: Any]
        let view = (structured?["view"] ?? (structured?["data"] as? [String: Any])?["view"]) as? [String: Any]
        return (summary.isEmpty ? "Done." : summary, view)
    }
}

/// Receives God's Eye View's voice-button presses (#311). Only the word "talk" is accepted, from the main frame.
final class WorldVoiceBridge: NSObject, WKScriptMessageHandler {
    private let talk: @MainActor () -> Void

    init(talk: @escaping @MainActor () -> Void) {
        self.talk = talk
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.body as? String == "talk" else { return }
        MainActor.assumeIsolated { talk() }
    }
}
