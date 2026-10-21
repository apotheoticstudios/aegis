import AegisKit
import Foundation

/// Where ModelService finds the model files. Never downloads: setup puts them in place.
public enum ModelLocation {
    /// The pinned model for this Mac's memory (ADR-0009; 24 GB or more runs the 9B, #190).
    public static var choice: ModelChoice {
        ModelChoice.current
    }

    public static var name: String {
        choice.name
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Aegis's own folder (a copy or link made by `make app`).
    public static func aegisFolder(_ model: ModelChoice) -> URL {
        home.appendingPathComponent("Library/Application Support/Aegis/Models").appendingPathComponent(model.folderName)
    }

    /// The pinned Hugging Face download, used until setup puts the model in Aegis's folder.
    public static func pinnedSnapshot(_ model: ModelChoice) -> URL {
        home.appendingPathComponent(".cache/huggingface/hub/models--" + model.repository.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots").appendingPathComponent(model.revision)
    }

    /// The memory meaning model (#309), put in place by scripts/fetch-meaning-model.sh.
    public static var meaningFolder: URL {
        home.appendingPathComponent("Library/Application Support/Aegis/Models/bge-small-en-v1.5")
    }

    /// The first folder that holds this Mac's model; the 4B when the larger one isn't installed yet.
    public static func resolve() -> URL? {
        let candidates = [choice, .small].flatMap { [aegisFolder($0), pinnedSnapshot($0)] }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path)
        }
    }
}
