import AppKit
import Security
import SwiftUI

/// The World view's optional keys (#265), in the Mac's Keychain only: Cesium ion (3D cities), AISStream (ships),
/// NASA FIRMS (fires) and TomTom (traffic). They go only to God's Eye View's local server, which uses them with
/// those providers.
enum WorldKeys {
    enum Key: String, CaseIterable {
        case cesium, aisstream, firms, tomtom

        var title: String {
            switch self {
            case .cesium: "Cesium ion token (3D cities)"
            case .aisstream: "AISStream key (ships)"
            case .firms: "NASA FIRMS map key (fires)"
            case .tomtom: "TomTom key (traffic)"
            }
        }

        var site: String {
            switch self {
            case .cesium: "cesium.com/ion"
            case .aisstream: "aisstream.io"
            case .firms: "firms.modaps.eosdis.nasa.gov/api/map_key"
            case .tomtom: "my.tomtom.com/keys"
            }
        }

        /// The environment name God's Eye View reads.
        var environment: String {
            switch self {
            case .cesium: "CESIUM_ION_TOKEN"
            case .aisstream: "AISSTREAM_API_KEY"
            case .firms: "FIRMS_MAP_KEY"
            case .tomtom: "TOMTOM_API_KEY"
            }
        }
    }

    private static let service = "dev.jarvis.world" // kept: existing Keychain items (ADR-0028)
    /// Set when the Cesium token changed: it's built into the globe, so the next start rebuilds it.
    static let rebuildKey = "worldNeedsRebuild"

    static func value(_ key: Key) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    static func has(_ key: Key) -> Bool {
        UserDefaults.standard.bool(forKey: "worldKeySaved." + key.rawValue)
    }

    /// Saves a key, or removes it when empty. False when the Keychain refused.
    @discardableResult
    static func set(_ text: String, for key: Key) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved = true
        if !trimmed.isEmpty {
            var add = base
            add[kSecValueData as String] = Data(trimmed.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Aegis World view: " + key.title
            saved = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        UserDefaults.standard.set(saved && !trimmed.isEmpty, forKey: "worldKeySaved." + key.rawValue)
        if key == .cesium {
            UserDefaults.standard.set(true, forKey: rebuildKey)
        }
        return saved
    }

    /// The saved keys as God's Eye View's environment.
    static var environment: [String: String] {
        Dictionary(uniqueKeysWithValues: Key.allCases.compactMap { key in
            has(key) ? value(key).map { (key.environment, $0) } : nil
        })
    }
}

/// World view keys (#265): all optional; the globe works without them.
struct WorldKeysView: View {
    @State private var entries: [WorldKeys.Key: String] = [:]
    @State private var saved: [WorldKeys.Key: Bool] = [:]
    @State private var brief = WorldPresence.briefEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("World view").font(.title3.weight(.semibold))
            Toggle("Weather at home and today's flight in the brief", isOn: $brief)
                .onChange(of: brief) { _, on in
                    WorldPresence.briefEnabled = on
                    WorldPresence.shared.briefFetched = .distantPast
                }
            Text("Uses public data: home is sent rounded to about 10 km (to Open-Meteo), a flight only as its number "
                + "(to adsb.lol). Say “set my home here” at home first.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Keys").font(.headline)
            Text("All optional and free to get. They're kept in the Keychain and used only by the World view's own "
                + "server on this Mac. Changes apply the next time the World view opens.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(WorldKeys.Key.allCases, id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key.title + " · " + key.site).font(.callout)
                    HStack {
                        SecureField(saved[key] == true ? "Saved" : "Paste the key", text: Binding(
                            get: { entries[key] ?? "" }, set: { entries[key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            WorldKeys.set(entries[key] ?? "", for: key)
                            saved[key] = WorldKeys.has(key)
                            entries[key] = ""
                        }
                        .disabled((entries[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Remove") {
                            WorldKeys.set("", for: key)
                            saved[key] = false
                        }
                        .disabled(saved[key] != true)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            for key in WorldKeys.Key.allCases {
                saved[key] = WorldKeys.has(key)
            }
        }
    }
}

/// The World view keys window, opened from the menu bar menu.
@MainActor
enum WorldKeysWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: WorldKeysView()))
            created.title = "World view"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
