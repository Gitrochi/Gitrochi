import SwiftUI
import AppKit
import CryptoKit
import Observation

/// 자동 업데이트(맥): GitHub Releases 의 최신 릴리스를 보고 새 버전이면 알린다.
/// 받은 zip 은 릴리스의 SHA-256 과 맞고(앱에 공개키가 있으면 Ed25519 서명까지), 같은 앱(번들 ID)이며 서명이 온전할 때만 설치한다.
/// 자동 확인에서 새 버전을 찾으면 미리 받아 확인해 두고 알려서, '지금 업데이트'는 바꿔 넣고 다시 시작하기만 한다.
@MainActor @Observable
final class UpdateCenter {
    static let shared = UpdateCenter()

    static let repo = "Gitrochi/Gitrochi"

    /// 릴리스 zip 서명을 확인할 Ed25519 공개키(Info.plist GitrochiUpdatePublicKey, base64). 없으면 SHA-256 만 본다 — 만들기: macos/Tools/updatekey.sh new
    static let publicKey: String? = {
        let key = (Bundle.main.object(forInfoDictionaryKey: "GitrochiUpdatePublicKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }()

    struct Release: Equatable {
        let version: String
        let notes: String
        let date: String?
        let zipURL: URL
        let zipName: String
        let checksumURL: URL?
        let signatureURL: URL?
        let pageURL: URL?
    }

    enum Phase: Equatable {
        case idle, checking, available, upToDate, downloading, installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var latest: Release?
    private(set) var progress: Double?
    /// 미리 받아 확인까지 끝낸 버전
    private(set) var readyVersion: String?
    /// 마지막으로 확인에 성공한 때(다시 켜도 하루 한 번 셈이 이어지게 저장)
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date {
        didSet { UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked") }
    }

    var autoCheck: Bool = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdate") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var window: NSWindow?
    private var timer: Timer?
    /// 받기·확인 작업(버전마다 한 번). 자동 확인의 미리 받기와 '지금 업데이트'가 같은 작업을 기다린다.
    private var preparing: (version: String, task: Task<URL, Error>)?

    /// 앱을 켤 때: 자동 확인이 켜져 있으면 조용히 확인하고, 그 뒤로는 마지막 확인이 하루 지났으면 다시.
    /// 한 시간마다 보므로 잠자기에서 깨어난 뒤나 확인에 실패한 뒤에도 곧 다시 확인한다.
    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.autoCheck else { return }
                Task { await self.check(manual: false) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoCheck,
                      Date().timeIntervalSince(self.lastChecked ?? .distantPast) >= 24 * 3600 else { return }
                await self.check(manual: false)
            }
        }
    }

    /// "0.10.0" > "0.9.3"
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func check(manual: Bool) async {
        guard phase != .checking, phase != .downloading, phase != .installing else { return }
        phase = .checking
        do {
            // 최근 릴리스 중 맥 파일이 있는 가장 새 것(Windows 만 고친 릴리스가 'latest' 일 수 있어서)
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=20")!, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Gitrochi", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AIError.failed("GitHub", String(localized: "Couldn't get release information (\((resp as? HTTPURLResponse)?.statusCode ?? 0))."))
            }
            lastChecked = Date()
            let macReleases = list.filter { r in
                r["draft"] as? Bool != true && r["prerelease"] as? Bool != true
                    && (r["assets"] as? [[String: Any]] ?? []).contains { ($0["name"] as? String ?? "").hasSuffix("-macOS.zip") }
            }
            let version = { (r: [String: Any]) in (r["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }
            guard let obj = macReleases.max(by: { Self.isNewer(version($1), than: version($0)) }) else {
                latest = nil
                phase = .upToDate
                if manual { showWindow() }
                return
            }
            let tag = (obj["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let assets = obj["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String ?? "").hasSuffix("-macOS.zip") }
            let sum = assets.first { ($0["name"] as? String ?? "").hasSuffix("macOS.sha256") }
            let sig = assets.first { ($0["name"] as? String) == (zip?["name"] as? String).map { $0 + ".sig" } }
            guard Self.isNewer(tag, than: Self.currentVersion),
                  let zip, let zipURL = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
                latest = nil
                phase = .upToDate
                if manual { showWindow() }
                return
            }
            let release = Release(version: tag, notes: obj["body"] as? String ?? "", date: (obj["published_at"] as? String).map { String($0.prefix(10)) },
                                  zipURL: zipURL, zipName: zip["name"] as? String ?? "",
                                  checksumURL: (sum?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                                  signatureURL: (sig?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                                  pageURL: (obj["html_url"] as? String).flatMap(URL.init(string:)))
            latest = release
            phase = .available
            if manual {
                showWindow()
                if !Self.isTranslocated(Bundle.main.bundleURL) { _ = preparation(for: release) }
            } else if UserDefaults.standard.string(forKey: "skippedUpdate") != tag {
                // 미리 받아 확인한 뒤 알린다. 실패해도 알리고, '지금 업데이트'에서 다시 받는다.
                if !Self.isTranslocated(Bundle.main.bundleURL), (try? await preparation(for: release).value) == nil { preparing = nil }
                showWindow()
            }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            if manual { showWindow() }
        }
    }

    func skip() {
        if let v = latest?.version { UserDefaults.standard.set(v, forKey: "skippedUpdate") }
        closeWindow()
    }

    /// 받기(미리 받았으면 그대로) → 확인 → 바꿔 넣고 다시 시작
    func install() async {
        guard let r = latest else { return }
        let dest = Bundle.main.bundleURL
        // 다운로드 폴더에서 바로 연 앱은 macOS 가 읽기 전용 임시 위치에서 띄워서 바꿔 넣을 수 없다
        guard !Self.isTranslocated(dest) else {
            phase = .failed(String(localized: "Gitrochi is running from a temporary location because it was opened straight from the download, so it can't replace itself. Move it to the Applications folder, open it again, then update."))
            return
        }
        phase = .downloading
        do {
            let newApp: URL
            do { newApp = try await preparation(for: r).value } catch { preparing = nil; throw error }
            phase = .installing
            let pid = ProcessInfo.processInfo.processIdentifier
            if FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) {
                try Self.replace(with: newApp, at: dest, afterPID: pid, relaunch: true)
            } else {
                // 쓸 권한이 없는 폴더(일반 사용자의 /Applications 등)면 관리자 암호를 받아 지금 바꿔 넣고, 끝난 뒤 다시 열기만 기다린다
                guard try await Self.replaceAsAdmin(with: newApp, at: dest) else { phase = .available; return }
                try Self.replace(with: nil, at: dest, afterPID: pid, relaunch: true)
            }
            NSApp.terminate(nil)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            progress = nil
        }
    }

    /// 이 버전의 받기·확인 작업. 이미 시작했으면(미리 받기) 같은 작업을 돌려준다.
    private func preparation(for r: Release) -> Task<URL, Error> {
        if let p = preparing, p.version == r.version { return p.task }
        progress = 0
        readyVersion = nil
        let task = Task {
            let app = try await self.prepare(r, bundleID: Bundle.main.bundleIdentifier)
            self.readyVersion = r.version
            return app
        }
        preparing = (r.version, task)
        return task
    }

    nonisolated static func isTranslocated(_ app: URL) -> Bool { app.path.contains("/AppTranslocation/") }


    /// 받아서 확인까지: SHA-256(공개키가 있으면 Ed25519 서명도)이 릴리스와 맞고, 같은 앱(번들 ID)이며, 서명이 온전한 새 앱의 위치
    func prepare(_ r: Release, bundleID: String?) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("gitrochi-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zipFile = work.appendingPathComponent(r.zipName.isEmpty ? "update.zip" : r.zipName)
        try await Self.download(r.zipURL, to: zipFile) { [weak self] p in Task { @MainActor in self?.progress = p } }
        let zipData = try Data(contentsOf: zipFile)
        // SHA-256 은 꼭 맞춰 본다(전에는 릴리스에 .sha256 이 없으면 확인 없이 설치했다)
        guard let cu = r.checksumURL else {
            throw AIError.failed(String(localized: "Update"), String(localized: "The release has no SHA-256 file. It wasn't installed."))
        }
        let (sumData, _) = try await URLSession.shared.data(from: cu)
        let expected = String(decoding: sumData, as: UTF8.self).split(separator: "\n")
            .first { $0.hasSuffix(r.zipName) }?.split(separator: " ").first.map(String.init)
        let actual = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        guard let expected, expected.lowercased() == actual else {
            throw AIError.failed(String(localized: "Update"), String(localized: "The downloaded file's SHA-256 doesn't match the release. It wasn't installed."))
        }
        // SHA-256 은 같은 릴리스에서 오니 릴리스 파일이 바뀌면 함께 바뀔 수 있다. 서명은 비밀키 없이 만들 수 없다.
        if let key = Self.publicKey {
            guard let su = r.signatureURL else {
                throw AIError.failed(String(localized: "Update"), String(localized: "The release has no update signature. It wasn't installed."))
            }
            let (sigData, _) = try await URLSession.shared.data(from: su)
            guard UpdateSignature.isValid(sigData, for: zipData, publicKey: key) else {
                throw AIError.failed(String(localized: "Update"), String(localized: "The update signature doesn't match. It wasn't installed."))
            }
        }
        let unzip = try await Shell.run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path], cwd: work, timeout: 120)
        guard unzip.status == 0 else { throw AIError.failed(String(localized: "Update"), String(localized: "Couldn't extract: \(unzip.stderr)")) }
        let newApp = work.appendingPathComponent("Gitrochi.app")
        guard let newID = Bundle(url: newApp)?.bundleIdentifier, newID == bundleID else {
            throw AIError.failed(String(localized: "Update"), String(localized: "The downloaded file isn't Gitrochi. It wasn't installed."))
        }
        let verify = try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path], cwd: work, timeout: 120)
        guard verify.status == 0 else { throw AIError.failed(String(localized: "Update"), String(localized: "The downloaded app's signature is invalid: \(verify.stderr)")) }
        return newApp
    }

    /// pid 가 끝나면 dest 를 newApp 으로 바꿔 넣는다(실패하면 원래 앱을 되돌림). newApp 이 nil 이면 바꿔 넣지 않는다. relaunch 면 다시 연다.
    nonisolated static func replace(with newApp: URL?, at dest: URL, afterPID pid: Int32, relaunch: Bool) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [try installScript().path, String(pid), newApp?.path ?? "-", dest.path, relaunch ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    /// 관리자 권한으로 지금 바로 dest 를 newApp 으로 바꿔 넣는다. 암호 창을 취소하면 false. prompt 는 암호 창에 보일 글(없으면 업데이트 안내)
    nonisolated static func replaceAsAdmin(with newApp: URL, at dest: URL, prompt: String? = nil) async throws -> Bool {
        let prompt = prompt ?? String(localized: "Enter an administrator password to update Gitrochi in \(dest.deletingLastPathComponent().path).")
        let r = try await Shell.run("/usr/bin/osascript", adminSwapArguments(newApp: newApp, dest: dest, prompt: prompt), cwd: URL(fileURLWithPath: "/"), timeout: 600)
        if r.status == 0 { return true }
        if r.stderr.contains("-128") { return false }   // 사용자가 취소
        throw AIError.failed(String(localized: "Update"), String(localized: "Couldn't replace the app: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
    }

    /// osascript 인자. root 로 돌릴 스크립트는 파일로 두지 않는다 — 암호 창이 떠 있는 동안 같은 사용자의 다른 프로세스가 그 파일을 바꿀 수 있다.
    /// 본문은 AppleScript 글자 안에, 경로는 인자로 넘겨 quoted form 으로 감싼다.
    nonisolated static func adminSwapArguments(newApp: URL, dest: URL, prompt: String) -> [String] {
        let body = appleScriptString(swapFunction + "\nswap \"$1\" \"$2\"")
        return [
            "-e", "on run argv",
            "-e", "do shell script \"/bin/sh -c \" & quoted form of \"\(body)\" & \" sh \" & quoted form of (item 1 of argv) & \" \" & quoted form of (item 2 of argv) with prompt (item 3 of argv) with administrator privileges",
            "-e", "end run",
            newApp.path, dest.path, prompt,
        ]
    }

    /// sh 함수 swap <새 앱> <설치 위치>: 바꿔 넣고, 넣다가 실패하면 원래 앱을 되돌린다. 옮기기(mv)부터 실패하면 원래 앱에 손대지 않는다.
    /// 설치 위치에 앱이 없으면(설치 디스크에서 처음 옮길 때) 그냥 넣는다.
    nonisolated static let swapFunction = """
    swap() {
        rm -rf "$2.old"
        if [ -e "$2" ]; then mv "$2" "$2.old" || return 1; fi
        if /usr/bin/ditto "$1" "$2"; then rm -rf "$2.old"; else rm -rf "$2"; [ -e "$2.old" ] && mv "$2.old" "$2"; return 1; fi
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        return 0
    }
    """

    /// AppleScript 글자 안에 넣을 수 있게 \ " 줄바꿈을 이스케이프한다
    nonisolated static func appleScriptString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// 앱이 끝난 뒤(사용자 권한으로) 돌 스크립트: $1 기다릴 pid $2 새 앱(- 이면 바꿔 넣지 않음) $3 설치 위치 $4 1 이면 다시 열기
    nonisolated private static func installScript() throws -> URL {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("gitrochi-install-\(UUID().uuidString.prefix(8)).sh")
        try """
        #!/bin/sh
        \(swapFunction)
        pid="$1"; new="$2"; dest="$3"; relaunch="$4"; status=0
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if [ "$new" != "-" ]; then swap "$new" "$dest" || status=1; fi
        [ "$relaunch" = "1" ] && /usr/bin/open "$dest"
        exit $status
        """.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    /// 바이트마다 도는 반복이 화면을 붙잡지 않게 메인 밖에서 받고, 1MB 마다 진행률만 알린다(미리 받기는 사용자가 일하는 중에 돈다)
    nonisolated private static func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AIError.failed(String(localized: "Update"), String(localized: "Couldn't download the file.")) }
        let total = resp.expectedContentLength > 0 ? Double(resp.expectedContentLength) : nil
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received = 0.0
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Double(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if let total { progress(received / total) }
            }
        }
        try handle.write(contentsOf: buffer)
        progress(1)
    }

    // MARK: 창

    func showWindow() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = String(localized: "Gitrochi update")
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: UpdateView())
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }
    }

    func closeWindow() {
        window?.close()
        window = nil
    }
}

/// 새 버전 안내 → 받기 → 설치 → 다시 시작
struct UpdateView: View {
    private let center = UpdateCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch center.phase {
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("Checking for a new version…") }
            case .upToDate, .idle:
                Label("Gitrochi \(UpdateCenter.currentVersion) is the latest version.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack { Spacer(); Button("OK") { center.closeWindow() }.keyboardShortcut(.defaultAction) }
            case .failed(let m):
                Label("Couldn't update", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(m).font(.callout).textSelection(.enabled)
                HStack {
                    if let u = center.latest?.pageURL { Link("Open releases page", destination: u) }
                    Spacer()
                    Button("Close") { center.closeWindow() }
                }
            case .available, .downloading, .installing:
                if let r = center.latest {
                    Text("Version \(r.version) is out").font(.title3.weight(.semibold))
                    Text(String(localized: "Current version \(UpdateCenter.currentVersion) → \(r.version)") + (r.date.map { " · \($0)" } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                    if !r.notes.isEmpty {
                        ScrollView {
                            ReleaseMarkdown(text: r.notes, target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: UpdateCenter.repo), tag: "v" + r.version)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    }
                    if center.phase == .available {
                        if center.readyVersion == r.version {
                            Label("Downloaded and verified — ready to install.", systemImage: "checkmark.seal")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Skip this version") { center.skip() }
                            Spacer()
                            Button("Later") { center.closeWindow() }
                            Button("Update now") { Task { await center.install() } }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ProgressView(value: center.progress ?? 0)
                        Text(center.phase == .installing ? "Installing… Gitrochi restarts when done" : "Downloading…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("A downloaded file is installed only if its SHA-256 and signature match the release. After updating, you may be asked again for Keychain access on first launch.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
