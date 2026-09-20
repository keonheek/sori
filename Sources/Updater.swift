import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import IOKit.hid

// MARK: - Version + updates
// THE single source of truth for the version. install.sh and make-release.sh both grep this
// line for the bundle plist and the release zip name, so there is exactly one number to bump.
let soriVersion = "1.0.10"

// "Check for Updates…" — what it can actually do depends on how Sori was installed, because
// macOS ties Accessibility/Input Monitoring grants to the code signature:
//   • from source, with a stable self-signed identity → pull, rebuild, re-sign, restart, and
//     every grant survives. Fully automatic.
//   • from the prebuilt zip (ad-hoc signed) → every build has a new cdhash, so those two grants
//     go silently denied until the user re-toggles them. No amount of code fixes that; only a
//     paid Developer ID + notarization would. So that path just opens the release page and says
//     so honestly rather than pretending an in-app swap would be seamless.
enum Updater {
    static let repo = "keonheek/sori"
    static let releasesPage = "https://github.com/keonheek/sori/releases/latest"
    // Written by install.sh so the app knows where it was built from. Same convention as
    // ~/.sori-groq. Absent = not a source install.
    static var srcPathFile: String { (NSHomeDirectory() as NSString).appendingPathComponent(".sori-src") }

    // "v1.0.10" -> [1, 0, 10]. Compared as integers, never as strings: "1.0.10" < "1.0.9"
    // lexicographically, which would strand everyone on the older build.
    static func parse(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV \n\t"))
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = parse(remote), b = parse(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // The source checkout, if this install came from one and still looks like a git repo.
    static func sourceRepo() -> String? {
        guard let raw = try? String(contentsOfFile: srcPathFile, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")),
              FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("install.sh"))
        else { return nil }
        return path
    }

    struct Release { let tag: String, page: String, notes: String }

    // (release, nil) on success, (nil, human-readable reason) on failure.
    static func fetchLatest(_ done: @escaping (Release?, String?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            done(nil, "bad URL"); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Sori/\(soriVersion)", forHTTPHeaderField: "User-Agent")   // GitHub 403s without one
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { done(nil, err.localizedDescription); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String else {
                done(nil, "GitHub returned HTTP \(code)"); return
            }
            done(Release(tag: tag,
                         page: (j["html_url"] as? String) ?? releasesPage,
                         notes: (j["body"] as? String) ?? ""), nil)
        }.resume()
    }

    // Runs the update in a NEW Terminal window rather than as a child process: install.sh
    // boots out the launch agent and pkills this very app, which would take a child down with
    // it mid-build. Detaching also means the user watches the build output, which is the right
    // place to see a compile failure.
    static func runSourceUpdate(_ repo: String, to tag: String) -> String? {
        let script = """
        #!/bin/bash
        echo "== Sori update: \(soriVersion) -> \(tag) =="
        cd "\(repo)" || { echo "Source folder is gone: \(repo)"; read -n1 -p "Press any key…"; exit 1; }
        if [ -n "$(git status --porcelain)" ]; then
            echo ""
            echo "Your copy of the source has uncommitted changes, so this update stopped"
            echo "before touching anything. Commit or stash them, then run ./install.sh here."
            git status --short
            read -n1 -p "Press any key…"
            exit 1
        fi
        set -e
        git pull --ff-only
        ./install.sh
        echo ""
        echo "Sori \(tag) is installed and running."
        read -n1 -p "Press any key to close…"
        """
        let path = workPath("sori-update.sh")
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch { return "Could not write the update script: \(error.localizedDescription)" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", path]
        do { try p.run() } catch { return "Could not open Terminal: \(error.localizedDescription)" }
        wlog("update: handed off to Terminal (\(soriVersion) -> \(tag))")
        return nil
    }

    // `Sori --check-update` / `--version` from a terminal. Exists so the update path can be
    // tested on the real shipping binary without clicking a menu item.
    static func runCLICheck() -> Never {
        print("Sori \(soriVersion)")
        let sem = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        fetchLatest { r, err in
            if let r {
                if isNewer(r.tag, than: soriVersion) {
                    print("Update available: \(r.tag)")
                    print(sourceRepo().map { "Source install at \($0) — 'Check for Updates…' can update in place." }
                          ?? "Prebuilt install — download: \(r.page)")
                } else {
                    print("Up to date (latest release is \(r.tag)).")
                }
            } else {
                print("Could not check for updates: \(err ?? "unknown error")"); status = 1
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)
        exit(status)
    }
}
