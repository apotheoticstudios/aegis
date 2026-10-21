import AegisKit
import Foundation
import ModelRuntime
import SharedIPC

// ModelService with the MLX model (step 2.12; ADR-0013, ADR-0014). launchd starts it when AegisCore
// connects to the `dev.aegis.model` Mach service, even with the app closed. It loads the model on the
// first job and exits 60 s after its last one (long enough for a conversation, #209), so the model's memory returns to the system.

let idle = IdleExit(seconds: 60)
let exporter = ModelXPCExporter(model: MLXModelClient(folder: ModelLocation.resolve()), activity: idle)
let host = XPCListenerHost(
    machServiceName: ServiceNames.model,
    interface: ModelXPCProtocol.self,
    exported: exporter,
    clients: [ServiceNames.core]
)
host.resume()
idle.arm()
dispatchMain()
