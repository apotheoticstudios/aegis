import AegisKit
import AegisStorage
import Foundation
import MacSources
import SharedIPC

// AegisCore: the always-on launch agent (ADR-0010, ADR-0013). launchd starts it at login and keeps it
// running; the app reaches it through the `dev.aegis.core` Mach service. It runs the brief engine
// (step 3.1): the scheduler, the store, the model over XPC, and the panel's requests, plus the collectors
// (step 2.10) and a minimal notification recorder. It never logs message content.

/// Private folder for the database and the schedule; only this user can read it.
func dataFolder() throws -> URL {
    let folder = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Aegis", isDirectory: true)
    try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    return folder
}

do {
    let folder = try dataFolder()
    let store = try GRDBEventStore(path: folder.appendingPathComponent("aegis.sqlite").path)
    let notifications = ReaderCollector.notifications(at: SourcePaths.notifications)
    let engine = try CoreEngine(
        store: store,
        collectors: [notifications, .messages(at: SourcePaths.messages), .mail(at: SourcePaths.mail)],
        model: ModelXPCClient(),
        persistence: ScheduleFile(url: folder.appendingPathComponent("schedule.json")),
        // Settings arrive with the setup wizard (step 2.14); until then, 07:00 local time.
        initial: BriefSchedule(openingHour: 7, openingMinute: 0, timeZone: .current),
        // The model follows the Mac's memory: the 9B with 24 GB or more, otherwise the 4B (#190).
        options: .init(modelName: ModelChoice.current.name),
        contacts: ContactsCache(),
        // The owner's Junk, Not junk and Mute choices (#175); the earlier "Not junk" list moves in on first load.
        rules: OwnerRulesFile(
            url: folder.appendingPathComponent("rules.json"),
            legacyTrusted: folder.appendingPathComponent("trusted-senders.json")
        ),
        // What the owner asks Aegis to remember, and past exchanges (#222): this Mac only.
        memory: MemoryFile(url: folder.appendingPathComponent("memory.json")),
        // Aegis's name and personality, chosen by the owner (#241).
        personality: PersonalityFile(url: folder.appendingPathComponent("personality.json")),
        // The morning routine and the owner's "always yes / always no" decisions (#286).
        routine: RoutineFile(url: folder.appendingPathComponent("routine.json")),
        // Memory recall by meaning (#305), with macOS's own on-device word model.
        meaning: WordMeaning()
    )
    let host = XPCListenerHost(
        machServiceName: ServiceNames.core,
        interface: CoreXPCProtocol.self,
        exported: CoreXPCExporter(service: engine),
        clients: [ServiceNames.app]
    )
    host.resume()
    Task {
        await engine.start()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await engine.tick()
        }
    }
    // Sleep, wake, heat and Low Power Mode (step 2.13).
    let power = PowerMonitor(engine: engine)
    power.start()
    // Apple Mail kept running, hidden, so new email reaches the brief (ADR-0008).
    Task { @MainActor in
        let mail = MailKeeper()
        while !Task.isCancelled {
            await mail.ensureRunning()
            // Cheap process-list check; recover within a minute of a quit or wake without opening a window.
            try? await Task.sleep(for: .seconds(60))
        }
    }
    // Today's schedule (step 2.11): Calendar and Reminders into the store every 5 minutes, for the panel.
    let schedule = ScheduleRefresher(store: store)
    Task {
        while !Task.isCancelled {
            await schedule.refresh()
            try? await Task.sleep(for: .seconds(300))
        }
    }
    // Notification recorder (steps 2.9 and 2.10): file events within about a second, and every 5 minutes.
    // Notifications only: the bigger Messages and Mail stores are read at brief time (#72).
    let recorder = NotificationRecorder(collector: notifications, store: store)
    let watcher = StoreWatcher(store: SourcePaths.notifications) { Task { await recorder.record() } }
    watcher.start()
    Task {
        while !Task.isCancelled {
            // Re-attach the file watch too, in case macOS replaced the folder or its files.
            watcher.rearm()
            await recorder.record()
            try? await Task.sleep(for: recorder.nextDelay())
        }
    }
    // Run the main thread's run loop rather than dispatchMain(), which exits the main thread: Contacts,
    // EventKit and NSWorkspace deliver some callbacks through it. The port keeps the loop from returning
    // when nothing else is attached; it sleeps in the kernel while idle, like dispatchMain().
    RunLoop.main.add(NSMachPort(), forMode: .default)
    RunLoop.main.run()
} catch {
    // Codes only. launchd restarts AegisCore (KeepAlive); the panel shows it as unreachable.
    FileHandle.standardError.write(Data("AegisCore: start failed (\((error as NSError).code))\n".utf8))
    exit(1)
}
