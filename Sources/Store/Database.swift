import Foundation
import SQLite3

// MARK: - Local store (SQLite via the C API — no SPM, keeps plain `swiftc` builds)
// One file: ~/Library/Application Support/Sori/sori.sqlite. Every access goes through a
// serial queue: the transcribe queue inserts while the Hub reads on the main thread.
// Schema versions live in PRAGMA user_version; migrations only ever ADD.
final class Database {
    static let shared = Database()
    static let dictationsChanged = Notification.Name("sori.dictationsChanged")
    static let dictionaryChanged = Notification.Name("sori.dictionaryChanged")
    static let snippetsChanged = Notification.Name("sori.snippetsChanged")

    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "sori.db")
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var path: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sori", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("sori.sqlite").path
    }

    private init() {
        q.sync { open() }
    }

    private func open() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(Database.path, &db, flags, nil) == SQLITE_OK else {
            wlog("db OPEN FAILED: \(String(cString: sqlite3_errmsg(db)))"); db = nil; return
        }
        execRaw("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        migrate()
    }

    private func migrate() {
        let v = Int(scalarRaw("PRAGMA user_version") ?? 0)
        if v < 1 {
            execRaw("""
            CREATE TABLE IF NOT EXISTS dictations(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts REAL NOT NULL,
              bundle_id TEXT NOT NULL DEFAULT '',
              app_name TEXT NOT NULL DEFAULT '',
              window_title TEXT NOT NULL DEFAULT '',
              kind TEXT NOT NULL DEFAULT 'general',
              raw TEXT NOT NULL,
              final TEXT NOT NULL,
              provider TEXT NOT NULL DEFAULT '',
              audio_ms INTEGER NOT NULL DEFAULT 0,
              asr_ms INTEGER NOT NULL DEFAULT 0,
              rewrite_ms INTEGER NOT NULL DEFAULT 0,
              total_ms INTEGER NOT NULL DEFAULT 0,
              words INTEGER NOT NULL DEFAULT 0,
              pasted INTEGER NOT NULL DEFAULT 0,
              audio_path TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS dictations_ts ON dictations(ts DESC);
            CREATE TABLE IF NOT EXISTS dictionary(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              word TEXT NOT NULL,
              replacement TEXT NOT NULL DEFAULT '',
              starred INTEGER NOT NULL DEFAULT 0,
              source TEXT NOT NULL DEFAULT 'manual',
              created_ts REAL NOT NULL,
              UNIQUE(word COLLATE NOCASE)
            );
            CREATE TABLE IF NOT EXISTS snippets(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              trigger TEXT NOT NULL,
              expansion TEXT NOT NULL,
              created_ts REAL NOT NULL,
              UNIQUE(trigger COLLATE NOCASE)
            );
            CREATE TABLE IF NOT EXISTS app_styles(
              bundle_id TEXT PRIMARY KEY,
              category TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            PRAGMA user_version=1;
            """)
            wlog("db migrated to v1 at \(Database.path)")
        }
    }

    // MARK: raw helpers (call on q)
    private func execRaw(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            wlog("db exec FAILED: \(err.map { String(cString: $0) } ?? "?") — \(sql.prefix(80))")
            sqlite3_free(err)
        }
    }
    private func scalarRaw(_ sql: String) -> Int64? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : nil
    }

    enum Value { case int(Int64), real(Double), text(String), null }

    private func bind(_ st: OpaquePointer?, _ args: [Value]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .real(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, Database.SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
    }

    // MARK: public API (thread-safe, synchronous)
    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) -> Int64 {
        q.sync {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                wlog("db prepare FAILED: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(80))"); return -1
            }
            defer { sqlite3_finalize(st) }
            bind(st, args)
            let rc = sqlite3_step(st)
            if rc != SQLITE_DONE && rc != SQLITE_ROW {
                wlog("db step FAILED: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(80))"); return -1
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    struct Row {
        let cols: [String: Value]
        func int(_ k: String) -> Int64 { if case .int(let v)? = cols[k] { return v }; if case .real(let v)? = cols[k] { return Int64(v) }; return 0 }
        func real(_ k: String) -> Double { if case .real(let v)? = cols[k] { return v }; if case .int(let v)? = cols[k] { return Double(v) }; return 0 }
        func text(_ k: String) -> String { if case .text(let v)? = cols[k] { return v }; return "" }
    }

    func query(_ sql: String, _ args: [Value] = []) -> [Row] {
        q.sync {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                wlog("db prepare FAILED: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(80))"); return []
            }
            defer { sqlite3_finalize(st) }
            bind(st, args)
            var rows: [Row] = []
            let n = sqlite3_column_count(st)
            while sqlite3_step(st) == SQLITE_ROW {
                var cols: [String: Value] = [:]
                for i in 0..<n {
                    let name = String(cString: sqlite3_column_name(st, i))
                    switch sqlite3_column_type(st, i) {
                    case SQLITE_INTEGER: cols[name] = .int(sqlite3_column_int64(st, i))
                    case SQLITE_FLOAT: cols[name] = .real(sqlite3_column_double(st, i))
                    case SQLITE_TEXT: cols[name] = .text(String(cString: sqlite3_column_text(st, i)))
                    default: cols[name] = .null
                    }
                }
                rows.append(Row(cols: cols))
            }
            return rows
        }
    }

    func scalar(_ sql: String, _ args: [Value] = []) -> Double {
        guard let r = query(sql, args).first, let v = r.cols.values.first else { return 0 }
        switch v { case .int(let i): return Double(i); case .real(let d): return d; default: return 0 }
    }

    func meta(_ key: String) -> String? { query("SELECT value FROM meta WHERE key=?", [.text(key)]).first?.text("value") }
    func setMeta(_ key: String, _ value: String) {
        run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }
}
