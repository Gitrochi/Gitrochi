import Foundation

struct GitResult {
    let status: Int32
    let data: Data
    let stderr: String
    var output: String { String(decoding: data, as: UTF8.self) }
}

struct GitError: LocalizedError {
    let command: String
    let message: String

    var errorDescription: String? {
        var text = message.isEmpty ? String(localized: "git \(command) failed") : message
        let lower = message.lowercased()
        if lower.contains("terminal prompts disabled") || lower.contains("authentication failed")
            || lower.contains("permission denied (publickey)") || lower.contains("could not read username") {
            text += String(localized: "\n\nAuthentication is required. Push/pull once in a terminal to save your credentials (Keychain or SSH key), then try again.")
        }
        return text
    }
}

/// 시스템 git 을 서브프로세스로 실행한다. 앱은 git 의 동작을 새로 구현하지 않고 그대로 위임한다.
enum Git {
    /// 설정 > 도구에서 고른 git(없으면 자동으로 찾은 것)
    static var executable: String { ToolPaths.shared.get(.git) ?? "/usr/bin/git" }

    /// 사용자 설정이 출력 형식을 바꿔 파싱이 깨지지 않도록 고정하는 옵션
    private static let baseArgs = [
        "-c", "core.quotepath=off",
        "-c", "color.ui=false",
        "-c", "diff.noprefix=false",
        "-c", "diff.mnemonicprefix=false",
        "-c", "log.showsignature=false",
        "-c", "core.pager=cat",
    ]

    private static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"   // 자격 증명 프롬프트에서 멈추지 않고 실패하게
        env["GIT_OPTIONAL_LOCKS"] = "0"    // status 가 index 를 다시 써서 파일 감시가 되먹임되지 않게
        env["GIT_LITERAL_PATHSPECS"] = "1" // 고른 파일의 [, *, : 등을 패턴으로 해석하지 않게
        env["GIT_EDITOR"] = "true"         // merge/revert 기본 메시지를 편집기 없이 수락
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "en_US.UTF-8"
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path   // 훅·git-lfs·자격 증명 도우미
        return env
    }()

    /// 종료 코드가 ok 에 없으면 GitError 를 던진다.
    @discardableResult
    static func run(_ args: [String], in dir: URL, input: String? = nil, timeout: TimeInterval = 120,
                    ok: Set<Int32> = [0], env: [String: String] = [:]) async throws -> GitResult {
        let r = try await raw(args, in: dir, input: input, timeout: timeout, env: env)
        guard ok.contains(r.status) else {
            let msg = r.stderr.trimmed.isEmpty ? r.output.trimmed : r.stderr.trimmed
            throw GitError(command: args.first ?? "", message: msg)
        }
        return r
    }

    /// 종료 코드와 상관없이 결과를 돌려준다(프로세스를 띄우지 못했을 때만 던짐).
    static func raw(_ args: [String], in dir: URL, input: String? = nil, timeout: TimeInterval = 120,
                    env: [String: String] = [:]) async throws -> GitResult {
        try await Shell.run(executable, baseArgs + args, cwd: dir,
                            env: environment.merging(env) { _, new in new }, input: input, timeout: timeout)
    }
}

/// 외부 프로그램(git, gh, claude) 실행기.
/// 스레드를 붙잡고 기다리지 않는다: 출력은 readabilityHandler 로, 끝은 terminationHandler 로 받는다.
/// (예전엔 실행마다 GCD 스레드 두 개가 기다려서, 탭이 많을 때 64개 한도가 차 서로 기다리다 앱이 멈췄다)
enum Shell {
    /// 한 번의 실행 상태(출력 모으기 · 끝났는지)
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var outDone = false, errDone = false, exited = false, resumed = false
        private let finish: (Data, Data) -> Void

        init(finish: @escaping (Data, Data) -> Void) { self.finish = finish }

        func append(_ d: Data, err isErr: Bool) {
            lock.lock(); if isErr { err.append(d) } else { out.append(d) }; lock.unlock()
        }

        func close(err isErr: Bool) { mark { if isErr { errDone = true } else { outDone = true } } }
        func exit() { mark { exited = true } }

        private func mark(_ change: () -> Void) {
            lock.lock()
            change()
            let ready = outDone && errDone && exited && !resumed
            if ready { resumed = true }
            let (o, e) = (out, err)
            lock.unlock()
            if ready { finish(o, e) }
        }
    }

    /// 동시에 띄우는 프로세스 수 제한(파일 감시·여러 탭·아바타가 겹쳐도 git 이 수십 개씩 뜨지 않게)
    private actor Limiter {
        private var running = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        let limit = 16

        func acquire() async {
            if running < limit { running += 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
    }

    private static let limiter = Limiter()

    static func run(_ executable: String, _ args: [String], cwd: URL, env: [String: String]? = nil,
                    input: String? = nil, timeout: TimeInterval = 120) async throws -> GitResult {
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            p.currentDirectoryURL = cwd
            if let env { p.environment = env }
            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let inPipe = input == nil ? nil : Pipe()
            p.standardInput = inPipe ?? FileHandle.nullDevice

            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            let run = Run { o, e in
                killer.cancel()
                cont.resume(returning: GitResult(status: p.terminationStatus, data: o, stderr: String(decoding: e, as: UTF8.self)))
            }
            // stdout·stderr 는 둘 다 계속 비워야 한쪽 파이프가 가득 차 멈추지 않는다
            for (pipe, isErr) in [(out, false), (err, true)] {
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty {
                        h.readabilityHandler = nil
                        run.close(err: isErr)
                    } else {
                        run.append(d, err: isErr)
                    }
                }
            }
            p.terminationHandler = { _ in run.exit() }

            do {
                try p.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let name = (executable as NSString).lastPathComponent
                cont.resume(throwing: GitError(command: name, message: String(localized: "Couldn't run \(name): \(error.localizedDescription)")))
                return
            }
            if let inPipe, let input {
                // 입력이 파이프 버퍼보다 크면 쓰기가 막힐 수 있어 따로 쓴다(GCD 스레드를 붙잡지 않게 Thread)
                let data = Data(input.utf8)
                Thread.detachNewThread {
                    inPipe.fileHandleForWriting.write(data)
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        }
    }
}
