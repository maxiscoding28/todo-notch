import Foundation

/// Calls `onChange` when the file changes. Reopens the file after atomic replacement.
final class FileWatcher {
    private let path: String
    private var source: DispatchSourceFileSystemObject?
    var onChange: (() -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.start()
                    self.onChange?()
                }
            } else {
                self.onChange?()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
