import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut through Carbon's public `RegisterEventHotKey`, which needs no Accessibility
/// permission. Registration fails when another app already holds the combination, so callers try the
/// next choice.
@MainActor
final class GlobalHotKey {
    /// A key with modifiers, as Carbon wants them.
    struct Choice {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String

        static let preferred = [
            Choice(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥Space"),
            Choice(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey), label: "⌃⌥Space"),
            Choice(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘J"),
        ]

        /// "Talk to Aegis" (#178): opens the panel already listening.
        static let talk = [
            Choice(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧Space"),
            Choice(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey | cmdKey | shiftKey), label: "⌥⇧⌘J"),
        ]
    }

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void
    private let number: UInt32

    /// Nil when the combination is taken or Carbon refuses it. Each shortcut needs its own `number`.
    init?(_ choice: Choice, number: UInt32 = 1, action: @escaping @MainActor () -> Void) {
        self.action = action
        self.number = number
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            // Every shortcut's handler sees every press: act only on our own and pass the rest on.
            var pressedID = EventHotKeyID()
            let read = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &pressedID
            )
            guard read == noErr, pressedID.id == hotKey.number else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &pressed, context, &handler)
        guard installed == noErr else { return nil }
        let identifier = EventHotKeyID(signature: OSType(0x4A52_5653), id: number) // 'JRVS'
        guard RegisterEventHotKey(choice.keyCode, choice.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey) == noErr
        else {
            RemoveEventHandler(handler)
            return nil
        }
    }

    /// Gives the combination back to the system.
    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
        hotKey = nil
        handler = nil
    }
}
