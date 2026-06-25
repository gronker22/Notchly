//
//  NotificationInterceptor.swift
//  Notchly — Incoming notification peek
//
//  macOS exposes NO public API to read other apps' notifications. The only way
//  is to poll the private Notification Center database
//  (~/Library/Group Containers/group.com.apple.usernoted/db2/db), which requires
//  FULL DISK ACCESS and is undocumented (Apple may change the schema). This is
//  therefore best-effort: if access is denied, `needsFullDiskAccess` is set and
//  the feature simply does nothing.
//

import Foundation
import AppKit
import Combine
import SQLite3

struct NotificationItem: Equatable {
    let id: Int64
    let bundleID: String
    let title: String
    let body: String
}

@MainActor
final class NotificationInterceptor: ObservableObject {

    @Published private(set) var latest: NotificationItem?
    @Published private(set) var needsFullDiskAccess = false

    private let dbPath: String
    private var lastRecID: Int64 = 0
    private var timer: Timer?

    init() {
        dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
            .path
    }

    func start() {
        // Prime to the current max so we don't replay historical notifications.
        lastRecID = currentMaxRecID() ?? 0
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - DB

    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        // immutable=1 lets us read while the OS holds a write lock.
        let uri = "file:\(dbPath)?immutable=1"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            needsFullDiskAccess = false
            return db
        }
        needsFullDiskAccess = true        // most likely Full Disk Access denial
        if let db { sqlite3_close(db) }
        return nil
    }

    private func currentMaxRecID() -> Int64? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(rec_id) FROM record", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func poll() {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT rec_id, app_id, data FROM record WHERE rec_id > ? ORDER BY rec_id ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastRecID)

        var newest: NotificationItem?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recID = sqlite3_column_int64(stmt, 0)
            let appID = sqlite3_column_int64(stmt, 1)
            lastRecID = max(lastRecID, recID)

            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let size = Int(sqlite3_column_bytes(stmt, 2))
            let data = Data(bytes: blob, count: size)

            guard let (title, body) = parse(data) else { continue }
            let bundle = bundleID(for: appID, db: db) ?? ""
            newest = NotificationItem(id: recID, bundleID: bundle, title: title, body: body)
        }
        if let newest { latest = newest }
    }

    private func bundleID(for appID: Int64, db: OpaquePointer) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT identifier FROM app WHERE app_id = ?", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, appID)
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            return String(cString: c)
        }
        return nil
    }

    /// The `data` blob is a binary plist; the title/body live under keys
    /// "titl"/"body" somewhere inside. Search recursively for robustness.
    private func parse(_ data: Data) -> (String, String)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }

        var title = ""
        var body = ""
        func search(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                for (key, value) in dict {
                    if key == "titl", title.isEmpty, let s = value as? String { title = s }
                    else if key == "body", body.isEmpty, let s = value as? String { body = s }
                    else { search(value) }
                }
            } else if let arr = obj as? [Any] {
                arr.forEach(search)
            }
        }
        search(plist)

        if title.isEmpty && body.isEmpty { return nil }
        return (title, body)
    }

    deinit { timer?.invalidate() }
}
