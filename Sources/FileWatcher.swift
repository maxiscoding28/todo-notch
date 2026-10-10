import Foundation

/// Calls `onChange` when the file changes. Reopens the file after atomic replacement.
final class FileWatcher {
    private let path: String
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchWorkItem?
    private var generation = 0
    var onChange: (() -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleRestart(after: 2)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.scheduleRestart(after: 0.05)
            } else {
                self.onChange?()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        generation += 1
        retry?.cancel()
        retry = nil
        source?.cancel()
        source = nil
    }

    private func scheduleRestart(after delay: Double) {
        retry?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.start()
            self.onChange?()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    deinit { stop() }
}
