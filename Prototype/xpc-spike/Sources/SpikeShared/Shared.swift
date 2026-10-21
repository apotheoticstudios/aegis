import Foundation
import Security

/// Names shared by the spike's processes. Nothing here touches personal data.
public enum Spike {
    public static let appID = "dev.aegis.xpcsigned"
    public static let coreID = "dev.aegis.xpcsigned.core"
    public static let modelID = "dev.aegis.xpcsigned.model"
    /// The Mach service the ModelService stand-in publishes through launchd.
    public static let modelService = "dev.aegis.xpcsigned.model"
    /// Who may call ModelService: Core or the app, signed by the same team as this process.
    public static var clientRequirement: String {
        requirement(identifiers: [coreID, appID])
    }

    /// Who AegisCore accepts as ModelService.
    public static var serverRequirement: String {
        requirement(identifiers: [modelID])
    }

    /// A code-signing requirement for the given identifiers. Signed with a team (Apple Development or
    /// Developer ID), it also pins Apple's anchor and this process's own team, so ad hoc code that copies
    /// an identifier is refused. Ad hoc builds have no team and fall back to identifiers only (spoofable).
    public static func requirement(identifiers: [String]) -> String {
        let names = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        guard let team = ownTeamID() else { return names }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(names))"
    }

    /// The team ID in this process's own signature, or nil for ad hoc or unsigned code.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let fields = info as? [String: Any] else { return nil }
        return fields[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public static let folder = URL(fileURLWithPath: "/private/tmp/aegis-xpc-spike")

    /// Appends one line (timestamp, process, event) to the spike's log. Events are fixed strings and numbers.
    public static func log(_ process: String, _ event: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(process)[\(getpid())] \(event)\n"
        let url = folder.appendingPathComponent("spike.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// The ModelService stand-in's XPC interface: a bounded job in, a small JSON result out.
@objc public protocol SpikeModelProtocol {
    /// `seconds` simulates generation time. The reply is JSON: {"pid": Int, "job": Int}.
    func generate(job: Int, seconds: Double, reply: @escaping (Data?, String?) -> Void)
}
