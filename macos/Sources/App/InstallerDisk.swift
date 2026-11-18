import AppKit

/// 설치 디스크(배포용 dmg: 앱과 응용 프로그램 폴더 바로가기가 나란히 든 읽기 전용 볼륨) 뒷정리.
/// dmg 는 끌어다 넣는 순간 아무것도 실행할 수 없어서, 앱이 열릴 때 정리한다.
/// - 설치한 앱을 열면: 같은 빌드가 든 설치 디스크를 꺼낸다. Finder 의 그 창도 닫혀 다시 끌어 넣는 실수가 없다.
/// - 설치 디스크 안의 앱을 바로 열면: 응용 프로그램 폴더로 옮길지 묻는다. 옮기면 그쪽 앱이 열리고, 그 앱이 디스크를 꺼낸다.
@MainActor
enum InstallerDisk {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// 앱을 켤 때 한 번
    static func check() {
        let here = Bundle.main.bundleURL
        if let source = installer(running: here) {
            // 시작 처리를 막지 않게 다음 차례에 묻는다(알림 창은 스플래시보다 위에 뜬다)
            Task { offerMove(from: source) }
        } else {
            Task.detached(priority: .utility) { ejectInstalled(matching: here) }
        }
    }

    /// 꽂혀 있는 설치 디스크 안의 앱들: 읽기 전용 볼륨 맨 위에 app 과 같은 이름·번들 ID 의 앱과 /Applications 바로가기가 함께 있는 것
    nonisolated static func installers(of app: URL) -> [URL] {
        let fm = FileManager.default
        guard let id = info(app)?.id else { return [] }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsReadOnlyKey], options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            guard (try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true,
                  (try? fm.destinationOfSymbolicLink(atPath: volume.appendingPathComponent("Applications").path)) == "/Applications" else { return nil }
            let candidate = volume.appendingPathComponent(app.lastPathComponent)
            return info(candidate)?.id == id ? candidate : nil
        }
    }

    /// here(지금 도는 앱)가 설치 디스크 안에서 돌고 있으면 그 디스크 안의 앱 위치.
    /// macOS 가 임시 위치로 옮겨 띄웠으면(App Translocation) 원래 위치로 보고, 원래 위치를 모르면 같은 빌드가 든 디스크로 본다
    nonisolated static func installer(running here: URL) -> URL? {
        let disks = installers(of: here)
        guard UpdateCenter.isTranslocated(here) else { return disks.first { $0.path == here.path } }
        guard let original = translocationOriginal(of: here) else { return disks.first { sameBuild($0, here) } }
        return disks.first { $0.path == original.path }
    }

    /// 번들 ID, 보이는 버전, 빌드(버전과 빌드 번호). Bundle(url:) 은 위치마다 값을 붙잡아 두므로 Info.plist 를 바로 읽는다
    nonisolated static func info(_ app: URL) -> (id: String?, version: String, build: String)? {
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        let version = plist["CFBundleShortVersionString"] as? String ?? "?"
        return (plist["CFBundleIdentifier"] as? String, version, "\(version) (\(plist["CFBundleVersion"] as? String ?? "?"))")
    }

    nonisolated static func sameBuild(_ a: URL, _ b: URL) -> Bool {
        guard let x = info(a), let y = info(b) else { return false }
        return x.id == y.id && x.build == y.build
    }

    /// 설치한 앱을 열었을 때: 같은 빌드가 든 설치 디스크는 할 일을 다 했으니 꺼낸다. 더 새 빌드가 든 디스크는 아직 설치 전일 수 있어 둔다
    nonisolated static func ejectInstalled(matching here: URL) {
        for app in installers(of: here) where sameBuild(app, here) {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: app.deletingLastPathComponent())
        }
    }

    /// App Translocation 으로 옮겨 띄운 앱의 원래 위치. Security 프레임워크에 있지만 공개 헤더가 없어 이름으로 찾는다
    nonisolated static func translocationOriginal(of url: URL) -> URL? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        return unsafeBitCast(symbol, to: Original.self)(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// 설치 디스크 안의 앱을 바로 열었을 때: 응용 프로그램 폴더로 옮길지 묻는다
    static func offerMove(from source: URL) {
        let dest = URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(source.lastPathComponent)
        let installed = info(dest)
        let same = sameBuild(dest, source)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let alert = NSAlert()
        if same {
            alert.messageText = String(localized: "Gitrochi is already in the Applications folder")
            alert.informativeText = String(localized: "Open that one instead? The disk image will be ejected.")
            alert.addButton(withTitle: String(localized: "Open"))
        } else {
            alert.messageText = String(localized: "Move Gitrochi to the Applications folder?")
            var lines = [String(localized: "Gitrochi is running from the disk image. In the Applications folder it can update itself, and the disk image will be ejected.")]
            if let installed { lines.append(String(localized: "Gitrochi \(installed.version) in the Applications folder will be replaced.")) }
            if !others.isEmpty { lines.append(String(localized: "The Gitrochi that's already open will quit.")) }
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.addButton(withTitle: String(localized: "Move to Applications"))
        }
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await move(source, to: dest, copying: !same, quitting: same ? [] : others)
                BackgroundMode.shared.quitToRestart()
            } catch is CancellationError {
            } catch {
                let failed = NSAlert()
                failed.alertStyle = .warning
                failed.messageText = String(localized: "Couldn't move Gitrochi to the Applications folder")
                failed.informativeText = error.localizedDescription
                failed.runModal()
            }
        }
    }

    /// 이 앱이 끝나면 dest 에 source 를 넣고(copying) dest 를 연다. 쓸 권한이 없는 폴더면 관리자 암호를 받아 지금 넣는다.
    /// 디스크는 새로 열린 앱이 꺼낸다(ejectInstalled)
    private static func move(_ source: URL, to dest: URL, copying: Bool, quitting others: [NSRunningApplication]) async throws {
        // 바꿔 넣을 앱이 열려 있으면 먼저 끝낸다. 열린 채로 두면 다시 열 때 새 앱 대신 그 창이 앞으로 온다
        others.forEach { $0.terminate() }
        var waited = 0
        while others.contains(where: { !$0.isTerminated }), waited < 50 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard others.allSatisfy(\.isTerminated) else {
            throw Failure(String(localized: "Quit the Gitrochi that's already open, then try again."))
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        if copying, !FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) {
            let prompt = String(localized: "Enter an administrator password to move Gitrochi to \(dest.deletingLastPathComponent().path).")
            guard try await UpdateCenter.replaceAsAdmin(with: source, at: dest, prompt: prompt) else { throw CancellationError() }
            try UpdateCenter.replace(with: nil, at: dest, afterPID: pid, relaunch: true)
        } else {
            try UpdateCenter.replace(with: copying ? source : nil, at: dest, afterPID: pid, relaunch: true)
        }
    }
}
