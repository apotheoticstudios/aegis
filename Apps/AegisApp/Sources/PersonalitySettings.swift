import AegisKit
import AppKit
import SwiftUI

/// Aegis's name and personality (#241): set here now, and by the setup wizard later.
struct PersonalityView: View {
    let model: PanelModel
    @State private var name = ""
    @State private var style = Personality.Style.classic
    @State private var callOwner = ""
    @State private var notes = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Personality").font(.title3.weight(.semibold))
            HStack {
                Text("Your Aegis’s name").frame(width: 110, alignment: .leading)
                TextField("Aegis", text: $name).textFieldStyle(.roundedBorder)
            }
            Text("A one-word name also works as the wake word (“Hey \(name.isEmpty ? "Aegis" : name)”); “Hey Aegis” always does.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Style", selection: $style) {
                ForEach(Personality.Style.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(style.description.prefix(1).uppercased() + style.description.dropFirst())
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Call me").frame(width: 110, alignment: .leading)
                TextField("sir, boss, your name, or leave empty", text: $callOwner).textFieldStyle(.roundedBorder)
            }
            Text("Anything else about how \(name.isEmpty ? "Aegis" : name) should be").font(.callout)
            TextEditor(text: $notes)
                .font(.body).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("For example: “swear a bit”, “roast me”, “be more Australian”, “keep it really short”.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                Button("Save") {
                    Task {
                        let chosen = Personality(name: name, style: style, callOwner: callOwner, notes: notes)
                        notice = await model.savePersonality(chosen) ? "Saved." : "That name or those notes won't fit."
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            await model.loadPersonality()
            name = model.personality.name
            style = model.personality.style
            callOwner = model.personality.callOwner
            notes = model.personality.notes
        }
    }
}

/// The personality window, opened from the menu bar menu.
@MainActor
enum PersonalityWindow {
    private static var window: NSWindow?

    static func show(_ model: PanelModel) {
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: PersonalityView(model: model)))
            created.title = "Personality"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
