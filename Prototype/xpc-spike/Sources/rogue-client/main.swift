import Foundation
import SpikeShared

/// A client ModelService must refuse: run it signed with a different identifier and check the reply never
/// comes. Signed with a spoofed identifier, it shows why a real build needs the team anchor too.
let connection = NSXPCConnection(machServiceName: Spike.modelService, options: [])
connection.remoteObjectInterface = NSXPCInterface(with: SpikeModelProtocol.self)
connection.resume()
let done = DispatchSemaphore(value: 0)
var result = "no answer"
let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    result = "refused: \((error as NSError).domain) \((error as NSError).code)"
    done.signal()
} as? SpikeModelProtocol
proxy?.generate(job: 99, seconds: 0.1) { data, _ in
    result = data == nil ? "empty reply" : "ACCEPTED (served a job)"
    done.signal()
}

_ = done.wait(timeout: .now() + 15)
print(result)
Spike.log("rogue", result)
