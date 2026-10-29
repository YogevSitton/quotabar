import Foundation
import Darwin

/// A bounded child session with no shell and no controlling terminal. Monitoring
/// stdin is an EOF pipe, not /dev/null: Antigravity classifies character devices
/// as interactive and would otherwise be allowed to start authentication.
enum AntigravityProcess {
    enum ProcessError: Error {
        case launchFailed
        case timedOut
        /// Cancelled after the child may have started; its phase is unknown.
        case cancelled
        /// Thrown only before posix_spawn: the child provably never ran.
        case cancelledBeforeLaunch
        case oversizedResponse
        case inputUnavailable
    }

    struct Result {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    /// Construct only for an explicit Connect action. This changes stdin's file
    /// type without granting a controlling terminal or using a shell/Terminal.
    final class LoginInput: @unchecked Sendable {
        private let lock = NSLock()
        private var master: Int32 = -1
        private var slave: Int32 = -1

        init() throws {
            guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw ProcessError.inputUnavailable }
            do {
                try setCloseOnExec(master)
                try setCloseOnExec(slave)
                var settings = termios()
                guard tcgetattr(slave, &settings) == 0 else { throw ProcessError.inputUnavailable }
                settings.c_lflag &= ~tcflag_t(ECHO | ECHONL)
                guard tcsetattr(slave, TCSANOW, &settings) == 0,
                      fcntl(master, F_SETFL, O_NONBLOCK) == 0 else { throw ProcessError.inputUnavailable }
            } catch {
                Darwin.close(master); Darwin.close(slave)
                master = -1; slave = -1
                throw error
            }
        }

        deinit { close() }

        fileprivate func duplicateSlave() throws -> Int32 {
            lock.lock(); defer { lock.unlock() }
            guard slave >= 0 else { throw ProcessError.inputUnavailable }
            let fd = fcntl(slave, F_DUPFD_CLOEXEC, 3)
            guard fd >= 0 else { throw ProcessError.inputUnavailable }
            return fd
        }

        func sendCode(_ code: String) throws {
            let bytes = Array(code.utf8)
            // Canonical mode keeps at most MAX_CANON bytes per line, newline
            // included; a longer code would be truncated without an error.
            guard !bytes.isEmpty, bytes.count < Int(MAX_CANON),
                  !bytes.contains(where: { $0 < 32 || $0 == 127 }) else { throw ProcessError.inputUnavailable }
            lock.lock(); defer { lock.unlock() }
            guard master >= 0 else { throw ProcessError.inputUnavailable }
            let line = bytes + [10]
            let count = line.withUnsafeBytes { Darwin.write(master, $0.baseAddress!, $0.count) }
            guard count == line.count else { throw ProcessError.inputUnavailable }
        }

        func close() {
            lock.lock(); defer { lock.unlock() }
            if master >= 0 { Darwin.close(master); master = -1 }
            if slave >= 0 { Darwin.close(slave); slave = -1 }
        }
    }

    static func run(binary: URL, arguments: [String], profile: AntigravityProfile.Lease,
                    timeout: TimeInterval = 45, loginInput: LoginInput? = nil,
                    cancel: Cancellation? = nil) throws -> Result {
        guard timeout.isFinite, timeout > 0, timeout <= 180,
              binary.isFileURL, binary.path.hasPrefix("/"),
              !([binary.path] + arguments).contains(where: { $0.utf8.contains(0) }) else {
            throw ProcessError.launchFailed
        }
        try profile.validateForLaunch()
        if cancel?.isCancelled == true { throw ProcessError.cancelledBeforeLaunch }
        // Cancel also closes the login input, so a failed duplicate after a
        // cancellation is that cancellation, still before any launch.
        let loginFD: Int32?
        do { loginFD = try loginInput?.duplicateSlave() }
        catch let failure { throw cancel?.isCancelled == true ? ProcessError.cancelledBeforeLaunch : failure }
        defer { if let loginFD { Darwin.close(loginFD) } }

        var input = try makePipe()
        defer { closePipe(&input) }
        var output = try makePipe()
        defer { closePipe(&output) }
        var error = try makePipe()
        defer { closePipe(&error) }
        // The monitor has no writer even during spawn, so it cannot accidentally
        // wait for input or take the CLI's interactive authentication branch.
        Darwin.close(input[1]); input[1] = -1
        try setNonblocking(output[0])
        try setNonblocking(error[0])

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProcessError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProcessError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }

        // POSIX_SPAWN_SETSID is 0x0400 in the macOS SDK's sys/spawn.h. A new
        // session prevents /dev/tty from reattaching to a launcher's terminal.
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGPIPE, SIGHUP] { sigaddset(&defaults, signal) }
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawn_file_actions_adddup2(&actions, loginFD ?? input[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, error[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, profile.workingDirectory.path) == 0 else {
            throw ProcessError.launchFailed
        }

        let argv = ([binary.path] + profile.arguments + arguments).map { strdup($0) }
        let env = profile.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { for pointer in argv + env { free(pointer) } }
        guard argv.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else { throw ProcessError.launchFailed }
        var argvPointers = argv + [nil], envPointers = env + [nil]
        if cancel?.isCancelled == true { throw ProcessError.cancelledBeforeLaunch }
        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, binary.path, &actions, &attributes, &argvPointers, &envPointers)
        guard spawnResult == 0, pid > 0 else { throw ProcessError.launchFailed }
        Darwin.close(output[1]); output[1] = -1
        Darwin.close(error[1]); error[1] = -1
        var reaped = false
        defer {
            // Also terminate inherited pipe holders in the child's group. Keep
            // the leader unreaped until this signal so its PID cannot be reused.
            if !reaped { terminateAndReap(pid) }
            withExtendedLifetime(profile) {}
            withExtendedLifetime(loginInput) {}
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var stdout = Data(), stderr = Data()
        while true {
            if cancel?.isCancelled == true { throw ProcessError.cancelled }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ProcessError.timedOut }
            try drain(&output[0], into: &stdout, limit: 2_000_000)
            try drain(&error[0], into: &stderr, limit: 128_000)

            var info = siginfo_t()
            let status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if status < 0, errno != EINTR { throw ProcessError.launchFailed }
            if status == 0, info.si_pid == pid {
                kill(-pid, SIGKILL)
                try drain(&output[0], into: &stdout, limit: 2_000_000)
                try drain(&error[0], into: &stderr, limit: 128_000)
                var childStatus: Int32 = 0
                var waited: pid_t
                repeat { waited = waitpid(pid, &childStatus, 0) } while waited < 0 && errno == EINTR
                guard waited == pid else { throw ProcessError.launchFailed }
                reaped = true
                let exitCode: Int32 = (childStatus & 0x7f) == 0 ? (childStatus >> 8) & 0xff : 128 + (childStatus & 0x7f)
                return Result(stdout: stdout, stderr: stderr, exitCode: exitCode)
            }
            var descriptors = [pollfd(fd: output[0], events: Int16(POLLIN), revents: 0),
                               pollfd(fd: error[0], events: Int16(POLLIN), revents: 0)]
            let result = poll(&descriptors, nfds_t(descriptors.count), 50)
            if result < 0, errno != EINTR { throw ProcessError.launchFailed }
        }
    }

    private static func makePipe() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw ProcessError.launchFailed }
        do {
            // Ensure no source descriptor is 0/1/2: dup2 actions must not
            // accidentally overwrite another source when the app lacks stdio.
            for index in descriptors.indices {
                let duplicate = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
                guard duplicate >= 0 else { throw ProcessError.launchFailed }
                Darwin.close(descriptors[index]); descriptors[index] = duplicate
            }
            return descriptors
        } catch { closePipe(&descriptors); throw error }
    }

    private static func setCloseOnExec(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ProcessError.launchFailed }
    }

    private static func setNonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ProcessError.launchFailed }
    }

    private static func closePipe(_ descriptors: inout [Int32]) {
        for index in descriptors.indices where descriptors[index] >= 0 {
            Darwin.close(descriptors[index]); descriptors[index] = -1
        }
    }

    private static func drain(_ fd: inout Int32, into output: inout Data, limit: Int) throws {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            guard count >= 0 else { throw ProcessError.launchFailed }
            if count == 0 { Darwin.close(fd); fd = -1; return }
            guard count <= limit - output.count else { throw ProcessError.oversizedResponse }
            output.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func terminateAndReap(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        // Polling the zombie without reaping reserves the leader PID until the
        // final group kill. This also covers a child that ignores SIGTERM.
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid { break }
            poll(nil, 0, 10)
        }
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return }
        // Reaping cannot delay the UI or extend the request deadline if the OS
        // has not yet scheduled the killed child. This closure sends no signal.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
    }
}
