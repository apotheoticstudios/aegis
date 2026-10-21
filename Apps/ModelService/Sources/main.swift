import AegisKit
import Foundation
import SharedIPC

// ModelService: an on-demand launch agent (ADR-0013). launchd starts it when AegisCore connects to the
// `dev.aegis.model` Mach service, even with the app closed. It exits by itself 10 s after its last job,
// so the model's memory returns to the system. This is the Stage 1 skeleton (#65): the MLX model arrives
// in step 2.12, so every job fails with `model_missing` for now.

/// Placeholder until MLX generation lands (step 2.12).
struct SkeletonModel: ModelClient {
    func run(_ job: ModelJob) async throws -> ModelJobResult {
        ModelJobResult(jobID: job.id, status: .failed, failure: .modelMissing)
    }

    func cancel(jobID _: String) async {}
}

let idle = IdleExit(seconds: 10)
let exporter = ModelXPCExporter(model: SkeletonModel(), activity: idle)
let host = XPCListenerHost(
    machServiceName: ServiceNames.model,
    interface: ModelXPCProtocol.self,
    exported: exporter,
    clients: [ServiceNames.core]
)
host.resume()
idle.arm()
dispatchMain()
