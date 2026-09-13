// CarPlayDiagnostics.swift — field diagnostics for the CarPlay connect path.
//
// A CarPlay failure is invisible in the field. When the car screen stays black
// nothing has crashed (an exception thrown by CarPlay's template presentation is
// not catchable from Swift, and a missing template is not an error at all), so
// there is no crash report to read; and a TrollStore / self-signed install cannot
// be attached to Xcode for a console session. `os_log` is equally unreachable
// when the phone is in a car.
//
// So the connect path records what it did into the app's Documents folder, which
// is user-visible in Files (the app ships `UIFileSharingEnabled`): the driver can
// read back whether the CarPlay scene was created, whether `didConnect` ran, the
// entitlements-derived tab limit CarPlay reported, and whether the root template
// was accepted. That distinguishes "CarPlay never handed us a scene" from "we
// never presented a template" from "CarPlay rejected our template" — the three
// causes of a black car screen.
//
// Keep this dependency-free and cheap: it runs on the connect path.

#if os(iOS)
import Foundation
import os

public enum CarPlayDiagnostics {

    private static let log = Logger(subsystem: "im.missuo.kumone", category: "carplay")

    /// The log is truncated before appending past this size, so repeated sessions
    /// can't fill the container.
    private static let maximumBytes = 64 * 1024

    /// Serialises appends: the CarPlay scene and the phone scene can both write.
    private static let queue = DispatchQueue(label: "im.missuo.kumone.carplay.diagnostics")

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// The log inside the app's Documents folder (Files ▸ On My iPhone ▸ Kumone).
    public static var fileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("carplay.log")
    }

    /// Records one line, both to the unified log and to the on-device file.
    public static func record(_ message: String) {
        log.notice("\(message, privacy: .public)")

        let line = Data("\(stamp.string(from: Date()))  \(message)\n".utf8)
        queue.async {
            guard let url = fileURL else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    if try handle.seekToEnd() > UInt64(maximumBytes) {
                        try handle.truncate(atOffset: 0)
                        try handle.write(contentsOf: Data("(log truncated)\n".utf8))
                    }
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: url, options: .atomic)
                }
            } catch {
                log.error("carplay diagnostics write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif
