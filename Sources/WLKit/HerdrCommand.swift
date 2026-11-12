import Foundation
import Darwin

/// A private CLI process group. Payloads travel on stdin, never through a shell
/// or process-list-visible arguments. Cancellation also stops its SSH children.
final class HerdrCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var cancelled = false
    private var stopping = false
    private var continuation: CheckedContinuation<Data, Error>?
    private var process: Process?
    private var group: pid_t?

    /// `executable` must be an absolute path: a menu-bar app does not inherit
    /// the login shell's PATH, where `~/.local/bin` normally comes from.
    static func run(
        executable: String, arguments: [String],
        input: Data? = nil, timeout: TimeInterval = 20
    ) async throws -> Data {
        let command = HerdrCommand()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                command.start(executable: executable, arguments: arguments,
                              input: input, timeout: timeout, continuation: continuation)
            }
        }, onCancel: { command.cancel() })
    }

    private func start(
        executable: String, arguments: [String], input: Data?,
        timeout: TimeInterval, continuation: CheckedContinuation<Data, Error>
    ) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.launch(executable: executable, arguments: arguments, input: input, timeout: timeout)
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        if case .failure = result { stopping = true }
        let continuation = self.continuation
        self.continuation = nil
        let group = self.group
        let process = self.process
        lock.unlock()
        if case .failure = result {
            if let group { _ = Darwin.kill(-group, SIGTERM) }
            else if let process, process.isRunning { process.terminate() }
        }
        continuation?.resume(with: result)
    }

    private func launch(executable: String, arguments: [String], input: Data?, timeout: TimeInterval) {
        guard !isFinished else { return }
        guard executable.hasPrefix("/"), access(executable, X_OK) == 0 else {
            finish(.failure(HerdrError.api("Cannot execute \(executable). Is Herdr installed?")))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = input == nil ? nil : Pipe()
        var inputWriterStarted = false
        process.standardOutput = stdout
        process.standardError = stderr
        if let stdin { process.standardInput = stdin }
        else { process.standardInput = FileHandle.nullDevice }
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            if let stdin {
                try? stdin.fileHandleForReading.close()
                if !inputWriterStarted { try? stdin.fileHandleForWriting.close() }
            }
        }
        do {
            try process.run()
        } catch {
            finish(.failure(HerdrError.api("Cannot launch \(executable): \(error.localizedDescription)")))
            return
        }
        // Foundation creates a new process group on macOS. Verify ownership
        // before ever issuing a group signal; never signal the application's group.
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid
        guard ownsGroup || !process.isRunning else {
            _ = Darwin.kill(pid, SIGKILL)
            process.waitUntilExit()
            finish(.failure(HerdrError.api("Herdr command did not obtain an isolated process group.")))
            return
        }
        lock.lock()
        self.process = process
        self.group = ownsGroup ? pid : nil
        let alreadyFinished = finished
        lock.unlock()
        defer {
            if ownsGroup && (process.isRunning || shouldStop) {
                _ = Darwin.kill(-pid, SIGKILL)
            }
            process.waitUntilExit()
            lock.lock()
            self.process = nil
            self.group = nil
            lock.unlock()
        }
        if alreadyFinished { return }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        if let input, let stdin {
            try? stdin.fileHandleForReading.close()
            inputWriterStarted = true
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? stdin.fileHandleForWriting.close() }
                do { try stdin.fileHandleForWriting.write(contentsOf: input) }
                catch { self.finish(.failure(HerdrError.api("Cannot deliver the Herdr action payload."))) }
            }
        }
        let watchdog = DispatchWorkItem { self.finish(.failure(HerdrError.timeout("Herdr command"))) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        for fd in descriptors {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                finish(.failure(HerdrError.api("Cannot monitor the Herdr command output.")))
                return
            }
        }
        var polls = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP), revents: 0) }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var output = Data()
        var errors = Data()
        var open = 2
        while open > 0 && !isFinished {
            let ready = Darwin.poll(&polls, nfds_t(polls.count), 50)
            if ready < 0 {
                if errno == EINTR { continue }
                finish(.failure(HerdrError.api("Cannot read the Herdr command output.")))
                return
            }
            guard ready > 0 else { continue }
            for index in polls.indices where polls[index].fd >= 0 && polls[index].revents != 0 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(polls[index].fd, $0.baseAddress, $0.count) }
                if count == 0 {
                    polls[index].fd = -1
                    open -= 1
                } else if count > 0 {
                    if index == 0 {
                        guard output.count + count <= 8 * 1024 * 1024 else {
                            finish(.failure(HerdrError.badResponse("Herdr response exceeds 8 MiB.")))
                            return
                        }
                        output.append(contentsOf: buffer.prefix(count))
                    } else if errors.count < 16 * 1024 {
                        errors.append(contentsOf: buffer.prefix(min(count, 16 * 1024 - errors.count)))
                    }
                } else if errno != EAGAIN && errno != EINTR {
                    finish(.failure(HerdrError.api("Cannot read the Herdr command output.")))
                    return
                }
            }
        }
        guard !isFinished else { return }
        // Pipes can close before the child exits; keep cancellation/deadlines
        // effective rather than blocking indefinitely in waitUntilExit.
        while process.isRunning && !isFinished { usleep(10_000) }
        guard !isFinished else { return }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            finish(.success(output))
        } else {
            // herdr-app prints `{"error": "..."}` on stdout; other failures are
            // plain text on stderr.
            let response = output.isEmpty ? errors : output
            let error = (try? JSONSerialization.jsonObject(with: response) as? [String: Any])?["error"]
            let message = (error as? String) ?? ((error as? [String: Any])?["message"] as? String)
                ?? String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            finish(.failure(HerdrError.api(message.isEmpty ? "Herdr command failed (\(process.terminationStatus))." : message)))
        }
    }
}
