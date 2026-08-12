import AppKit
import ApplicationServices
import Foundation
import UserNotifications

private let vcmiClientPath = "/Applications/VCMI.app/Contents/MacOS/vcmiclient"
private let clientLogPath = "/tmp/vcmi-async-launch.log"
private let launcherLogPath = "/tmp/vcmi-async-launcher.log"
private let turnReadyNotificationID = "vcmi-async-turn-ready"
private let turnReadyCategoryID = "VCMI_ASYNC_TURN_READY"
private let playTurnActionID = "VCMI_ASYNC_PLAY_TURN"
private let startupTimeout: TimeInterval = 30
private let mainMenuDelay: TimeInterval = 2.5
private let stepDelay: TimeInterval = 0.8

private let menuSequence: [(CGKeyCode, String)] = [
    (37, "Load Game"),
    (46, "Multiplayer"),
    (4, "Hotseat"),
    (36, "confirm player names"),
    (36, "load selected save"),
]

private func prepareNotificationApplication() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
}

private func registerNotificationCategory() {
    let playAction = UNNotificationAction(
        identifier: playTurnActionID,
        title: "Грати хід",
        options: [.foreground]
    )
    let category = UNNotificationCategory(
        identifier: turnReadyCategoryID,
        actions: [playAction],
        intentIdentifiers: [],
        options: []
    )
    UNUserNotificationCenter.current().setNotificationCategories([category])
}

private func requestNotificationAuthorization() throws -> Bool {
    prepareNotificationApplication()
    registerNotificationCategory()
    let lock = NSLock()
    var finished = false
    var granted = false
    var requestError: Error?

    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { result, error in
        lock.lock()
        granted = result
        requestError = error
        finished = true
        lock.unlock()
    }
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        lock.lock()
        let isFinished = finished
        lock.unlock()
        if isFinished { break }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    lock.lock()
    let didFinish = finished
    lock.unlock()
    guard didFinish else {
        throw NSError(
            domain: "VCMIAsyncLauncher",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "macOS не відповіла на запит Notifications"]
        )
    }
    if let requestError { throw requestError }
    return granted
}

private func modernNotificationsAreUnavailable(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "UNErrorDomain" && nsError.code == 1
}

@available(macOS, deprecated: 11.0, message: "Fallback for locally signed builds")
private final class LegacyNotificationDelegate: NSObject, NSUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }
}

@available(macOS, deprecated: 11.0, message: "Fallback for locally signed builds")
private func scheduleLegacyTurnReadyNotification(title: String, subtitle: String, body: String) throws {
    prepareNotificationApplication()
    let center = NSUserNotificationCenter.default
    let delegate = LegacyNotificationDelegate()
    center.delegate = delegate
    defer { center.delegate = nil }
    for delivered in center.deliveredNotifications where delivered.identifier == turnReadyNotificationID {
        center.removeDeliveredNotification(delivered)
    }

    let notification = NSUserNotification()
    notification.identifier = turnReadyNotificationID
    notification.title = title
    notification.subtitle = subtitle
    notification.informativeText = body
    notification.soundName = NSUserNotificationDefaultSoundName
    notification.hasActionButton = true
    notification.actionButtonTitle = "Грати хід"
    center.deliver(notification)

    let deadline = Date().addingTimeInterval(2)
    while !notification.isPresented && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard notification.actualDeliveryDate != nil && notification.isPresented else {
        throw NSError(
            domain: "VCMIAsyncLauncher",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "macOS не показала сумісне notification"]
        )
    }
}

private func scheduleTurnReadyNotification(title: String, subtitle: String, body: String) throws {
    prepareNotificationApplication()
    registerNotificationCategory()
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [turnReadyNotificationID])
    center.removeDeliveredNotifications(withIdentifiers: [turnReadyNotificationID])

    let content = UNMutableNotificationContent()
    content.title = title
    content.subtitle = subtitle
    content.body = body
    content.sound = .default
    content.categoryIdentifier = turnReadyCategoryID

    let request = UNNotificationRequest(
        identifier: turnReadyNotificationID,
        content: content,
        trigger: nil
    )
    let lock = NSLock()
    var finished = false
    var schedulingError: Error?
    center.add(request) { error in
        lock.lock()
        schedulingError = error
        finished = true
        lock.unlock()
    }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        lock.lock()
        let isFinished = finished
        lock.unlock()
        if isFinished { break }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    lock.lock()
    let didFinish = finished
    lock.unlock()
    guard didFinish else {
        throw NSError(
            domain: "VCMIAsyncLauncher",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "macOS не підтвердила створення notification"]
        )
    }
    if let schedulingError { throw schedulingError }
}

private func clearTurnReadyNotification() {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [turnReadyNotificationID])
    center.removeDeliveredNotifications(withIdentifiers: [turnReadyNotificationID])
    let legacyCenter = NSUserNotificationCenter.default
    for delivered in legacyCenter.deliveredNotifications where delivered.identifier == turnReadyNotificationID {
        legacyCenter.removeDeliveredNotification(delivered)
    }
}

private func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let data = Data(line.utf8)

    if !FileManager.default.fileExists(atPath: launcherLogPath) {
        FileManager.default.createFile(atPath: launcherLogPath, contents: data)
        return
    }

    guard let handle = FileHandle(forWritingAtPath: launcherLogPath) else { return }
    defer { try? handle.close() }
    do {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } catch {
        // A diagnostics failure must not block the launcher.
    }
}

private func showAlert(title: String, message: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

private func accessibilityIsAvailable() -> Bool {
    let options = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
    ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

private func runningVCMI() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.executableURL?.path == vcmiClientPath
    }
}

@discardableResult
private func activate(_ application: NSRunningApplication) -> Bool {
    let deadline = Date().addingTimeInterval(3)

    repeat {
        _ = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline

    return false
}

private func launchVCMI() throws -> NSRunningApplication {
    FileManager.default.createFile(atPath: clientLogPath, contents: nil)
    guard let clientLog = FileHandle(forWritingAtPath: clientLogPath) else {
        throw NSError(
            domain: "VCMIAsyncLauncher",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Не вдалося відкрити \(clientLogPath)"]
        )
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: vcmiClientPath)
    process.arguments = ["--nointro"]
    process.standardOutput = clientLog
    process.standardError = clientLog
    try process.run()
    log("started vcmiclient pid=\(process.processIdentifier)")

    let deadline = Date().addingTimeInterval(startupTimeout)
    repeat {
        if let application = NSRunningApplication(processIdentifier: process.processIdentifier) {
            return application
        }
        if !process.isRunning {
            throw NSError(
                domain: "VCMIAsyncLauncher",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "VCMI завершилася під час запуску"]
            )
        }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline

    throw NSError(
        domain: "VCMIAsyncLauncher",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "VCMI не з’явилася протягом 30 секунд"]
    )
}

private func pressKey(_ keyCode: CGKeyCode, to processIdentifier: pid_t) throws {
    guard
        let source = CGEventSource(stateID: .hidSystemState),
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else {
        throw NSError(
            domain: "VCMIAsyncLauncher",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Не вдалося створити клавіатурну подію"]
        )
    }

    keyDown.postToPid(processIdentifier)
    Thread.sleep(forTimeInterval: 0.05)
    keyUp.postToPid(processIdentifier)
}

private func run() throws {
    log("launcher started")
    registerNotificationCategory()
    clearTurnReadyNotification()

    guard accessibilityIsAvailable() else {
        log("Accessibility is not authorized")
        showAlert(
            title: "Потрібен дозвіл Accessibility",
            message: "Відкрий System Settings → Privacy & Security → Accessibility, увімкни «Грати VCMI Async», а потім запусти застосунок ще раз."
        )
        return
    }

    if let existingApplication = runningVCMI() {
        log("vcmiclient already running; activating only")
        _ = activate(existingApplication)
        return
    }

    let application = try launchVCMI()
    Thread.sleep(forTimeInterval: mainMenuDelay)

    guard activate(application) else {
        throw NSError(
            domain: "VCMIAsyncLauncher",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Не вдалося активувати вікно VCMI"]
        )
    }

    for (index, step) in menuSequence.enumerated() {
        try pressKey(step.0, to: application.processIdentifier)
        log("sent key \(step.0): \(step.1)")
        if index < menuSequence.count - 1 {
            Thread.sleep(forTimeInterval: stepDelay)
        }
    }

    log("launcher completed")
}

if CommandLine.arguments.contains("--check-accessibility") {
    let available = accessibilityIsAvailable()
    print(available ? "PASS: Accessibility authorized" : "FAIL: Accessibility not authorized")
    exit(available ? 0 : 1)
}

if CommandLine.arguments.contains("--request-accessibility") {
    let available = accessibilityIsAvailable()
    print(available ? "PASS: Accessibility authorized" : "INFO: Accessibility permission requested")
    exit(0)
}

if CommandLine.arguments.contains("--request-notifications") {
    do {
        let granted = try requestNotificationAuthorization()
        print(granted ? "PASS: Notifications authorized" : "FAIL: Notifications not authorized")
        exit(granted ? 0 : 1)
    } catch {
        if modernNotificationsAreUnavailable(error) {
            print("INFO: using compatible AppKit notifications for locally signed launcher")
            exit(0)
        }
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let notificationIndex = CommandLine.arguments.firstIndex(of: "--notify-turn-ready") {
    let values = Array(CommandLine.arguments.dropFirst(notificationIndex + 1))
    guard values.count == 3 else {
        fputs("FAIL: --notify-turn-ready requires title, subtitle and body\n", stderr)
        exit(2)
    }
    do {
        do {
            try scheduleTurnReadyNotification(title: values[0], subtitle: values[1], body: values[2])
        } catch {
            guard modernNotificationsAreUnavailable(error) else { throw error }
            try scheduleLegacyTurnReadyNotification(title: values[0], subtitle: values[1], body: values[2])
        }
        print("PASS: turn-ready notification scheduled")
        exit(0)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--clear-turn-ready") {
    clearTurnReadyNotification()
    print("PASS: turn-ready notification cleared")
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    guard menuSequence.map(\.0) == [37, 46, 4, 36, 36],
          turnReadyNotificationID == "vcmi-async-turn-ready",
          playTurnActionID == "VCMI_ASYNC_PLAY_TURN" else {
        fputs("FAIL: unexpected menu sequence\n", stderr)
        exit(1)
    }
    print("PASS: launcher menu sequence")
    exit(0)
}

do {
    try run()
} catch {
    log("ERROR: \(error.localizedDescription)")
    showAlert(
        title: "Не вдалося автоматично відкрити сейв",
        message: "\(error.localizedDescription)\n\nДеталі: \(launcherLogPath)"
    )
}
