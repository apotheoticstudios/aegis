import Foundation
import SpikeShared

/// ModelService stand-in: launchd starts it on demand when a client looks up its Mach service.
/// It serves bounded jobs and exits after `idleSeconds` with no job running (ChatGPT's research, #67:
/// launchd won't stop an idle agent by itself, so the service must exit on its own).
let idleSeconds = 5.0

final class Model: NSObject, SpikeModelProtocol, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "model")
    private var running = 0
    private var idleTimer: DispatchWorkItem?

    override init() {
        super.init()
        armIdleExit()
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(Spike.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: SpikeModelProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { Spike.log("model", "connection invalidated") }
        connection.resume()
        Spike.log("model", "accepted connection from pid \(connection.processIdentifier)")
        return true
    }

    func generate(job: Int, seconds: Double, reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            self.running += 1
            self.idleTimer?.cancel()
            Spike.log("model", "job \(job) start")
            self.queue.asyncAfter(deadline: .now() + seconds) {
                self.running -= 1
                Spike.log("model", "job \(job) done")
                let result = try? JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "job": job])
                reply(result, nil)
                self.armIdleExit()
            }
        }
    }

    private func armIdleExit() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, running == 0 else { return }
            Spike.log("model", "idle \(idleSeconds) s: exiting")
            exit(0)
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + idleSeconds, execute: item)
    }
}

Spike.log("model", "launched by launchd")
let model = Model()
let listener = NSXPCListener(machServiceName: Spike.modelService)
listener.setConnectionCodeSigningRequirement(Spike.clientRequirement)
listener.delegate = model
listener.resume()
RunLoop.main.run()
