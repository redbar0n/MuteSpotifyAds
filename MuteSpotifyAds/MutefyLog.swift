//
//  MutefyLog.swift
//  Mutefy
//
//  Copyright © 2026 countnine. Licensed under GPL-3.0.
//

import Foundation

/// Append-only diagnostic log at ~/Library/Logs/Mutefy/mutefy.log.
///
/// This exists because the interesting failures are not crashes — they are "the volume
/// stayed at zero" and "the filler never started", both of which are silent and both of
/// which happened during Windows development. A menu bar app has nowhere to show that,
/// and the person debugging is often not the person listening.
///
/// Writes are serialised on a private queue and the file is trimmed when it gets large,
/// so leaving this on permanently costs nothing.
final class MutefyLog {

    static let shared = MutefyLog()

    /// Trim once the file passes this size, keeping the newest half.
    private static let maxBytes = 512 * 1024

    private let queue = DispatchQueue(label: "com.countnine.mutefy.log")
    private let fileURL: URL?
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs")
            .appendingPathComponent("Mutefy")

        if let logs = logs {
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            fileURL = logs.appendingPathComponent("mutefy.log")
        } else {
            fileURL = nil
        }
    }

    /// Path shown in the UI so the user can find the log without knowing the convention.
    var path: String { fileURL?.path ?? "(unavailable)" }

    func write(_ message: String) {
        guard let fileURL = fileURL else { return }
        let stamped = "\(formatter.string(from: Date())) \(message)\n"

        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: fileURL)
            }

            self.trimIfNeeded(fileURL)
        }
    }

    private func trimIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > MutefyLog.maxBytes,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Free function so call sites stay short enough to add liberally.
func mutefyLog(_ message: String) {
    MutefyLog.shared.write(message)
}
