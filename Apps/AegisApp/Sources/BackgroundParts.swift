import Foundation
import ServiceManagement
import SharedIPC

/// Registers AegisCore and ModelService with launchd (ADR-0013).
///
/// It refuses unless this build is signed with a team: macOS remembers an agent's first signature, so
/// registering an ad hoc or unsigned build would stop the real, team-signed Aegis from launching later.
enum BackgroundParts {
    enum Outcome: Equatable {
        /// Not team-signed (e.g. `make build` or CI): nothing registered.
        case skippedUnsigned
        /// Both registered; `.enabled` or `.requiresApproval` (System Settings › Login Items).
        case registered(core: SMAppService.Status, model: SMAppService.Status)
        /// launchd refused; the error code only.
        case failed(code: Int)
    }

    @discardableResult
    static func register(team: String? = CodeSigning.ownTeamID()) -> Outcome {
        guard team != nil else {
            return .skippedUnsigned
        }
        let core = SMAppService.agent(plistName: ServiceNames.corePlist)
        let model = SMAppService.agent(plistName: ServiceNames.modelPlist)
        do {
            // ModelService first: AegisCore may connect to it as soon as it starts.
            try model.register()
            try core.register()
        } catch {
            DiagnosticLog.shared.record(.registrationFailed, number: (error as NSError).code)
            return .failed(code: (error as NSError).code)
        }
        return .registered(core: core.status, model: model.status)
    }
}
