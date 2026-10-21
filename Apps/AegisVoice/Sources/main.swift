import Foundation
import SharedIPC
import VoiceRuntime

/// One app owns this embedded service. Invalidating its connection exits even during CoreML prediction.
final class VoiceService: NSObject, VoiceXPCProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let voice: LocalSpeech

    override init() {
        // Aegis.app/Contents/XPCServices/AegisVoice.xpc → Aegis.app/Contents/Resources/VoiceModels.
        let resources = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/VoiceModels")
        voice = LocalSpeech(models: resources)
        super.init()
    }

    func prepare(reply: @escaping @Sendable (Bool) -> Void) {
        Task { await reply(voice.prepare()) }
    }

    func synthesize(_ text: String, reply: @escaping @Sendable (Data?) -> Void) {
        Task { await reply(voice.audio(for: text)) }
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement = CodeSigning.requirement(identifiers: [ServiceNames.app]) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = NSXPCInterface(with: VoiceXPCProtocol.self)
        connection.exportedObject = self
        // Includes parent exit/crash. No always-on helper, model or CoreML cache remains after disconnect.
        connection.invalidationHandler = { exit(0) }
        connection.interruptionHandler = { exit(0) }
        connection.resume()
        return true
    }
}

let service = VoiceService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
dispatchMain()
