import Foundation

/// An empty background agent: roughly the smallest AegisCore could be before any collector runs.
/// It wakes once a minute and does nothing, like a launch agent waiting for work.
let timer = Timer(timeInterval: 60, repeats: true) { _ in }
RunLoop.main.add(timer, forMode: .default)
RunLoop.main.run()
