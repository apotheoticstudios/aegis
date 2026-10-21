// fda-agent: the launch agent half of the Full Disk Access check (Stage 0, issue #11).
//
// launchd starts it every 15 seconds. It tries to OPEN a folder that macOS protects with Full Disk
// Access (the system's privacy-permissions folder, which holds no personal data) and closes it
// straight away without reading any entry. It writes only whether opening worked, and the error if
// not, to a small JSON file the test app shows. It never touches messages, mail or notifications.

import Foundation

let protectedFolder = "/Library/Application Support/com.apple.TCC"
let home = FileManager.default.homeDirectoryForCurrentUser.path
let resultFolder = home + "/Library/Application Support/AegisAgentFDATest"

var result: [String: String] = [
    "time": ISO8601DateFormatter().string(from: Date()),
    "pid": String(getpid()),
    "parent_pid": String(getppid()), // 1 = started by launchd
    "target": protectedFolder,
]

if let folder = opendir(protectedFolder) {
    closedir(folder) // opened and closed; no entry is read
    result["readable"] = "yes"
} else {
    let code = errno
    // A missing folder says nothing about permissions: the experiment is invalid, not negative.
    result["readable"] = code == ENOENT || code == ENOTDIR ? "invalid" : "no"
    result["error"] = "\(code) (\(String(cString: strerror(code))))"
}

do {
    try FileManager.default.createDirectory(atPath: resultFolder, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: resultFolder + "/agent-result.json"), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("fda-agent: could not write result: \(error)\n".utf8))
    exit(1)
}
