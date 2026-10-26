import CryptoKit
import Darwin
import Foundation

extension MCPHTTP {
    /// An .ipa sent with `PUT /upload`, for one install: its file goes once nothing holds it (an install takes it away first).
    final class Upload: @unchecked Sendable {
        let id: String
        /// The caller's lasting id on the tailnet: the only one that can install it.
        let owner: String
        let sha256: String
        let path: String

        init(id: String, owner: String, sha256: String, path: String) {
            self.id = id
            self.owner = owner
            self.sha256 = sha256
            self.path = path
        }

        deinit {
            unlink(path)
        }
    }

    /// The one upload kept (`--allow-install`), in RoamRun's own folder, where the app takes an app to install from.
    /// A new one replaces it.
    final class Uploads: @unchecked Sendable {
        /// An upload not used for this long is let go of.
        static let keptFor: TimeInterval = 30 * 60
        /// An upload file this old when a server starts was left by one that ended without Ctrl-C.
        static let leftFor: TimeInterval = 24 * 60 * 60
        /// Time for a body: `within`, and `perMiB` more for each MiB that came — by what comes, not what is said will:
        /// one that trickles doesn't hold the one slot for as long as its size would take at that pace.
        var within: TimeInterval = MCPHTTP.bodyWithin
        var perMiB: TimeInterval = 2

        let folder: URL
        /// The most taken, in bytes.
        let most: Int
        private let lock = NSLock()
        private var kept: (upload: Upload, used: Date)?
        /// The uploads installs were handed, until the app has taken each (or not): their files stay, so that an install
        /// the app didn't begin gives its own back — unless another upload came in since (`keepable` false then).
        private var lent: [(upload: Upload, keepable: Bool)] = []
        private var coming = false
        /// The file one coming in is written to.
        private var incoming: String?
        /// Stopping: no file is made any more (one made after `end` would be left).
        private var ended = false

        init(folder: URL, most: Int) {
            self.folder = folder
            self.most = most
            // What a server ended without Ctrl-C (killed, or the Mac gone down) left: none is kept that long.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                where name.hasPrefix("upload-") && name.hasSuffix(".ipa")
            {
                let file = folder.appendingPathComponent(name)
                let changed = try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
                if Date().timeIntervalSince(changed ?? .distantPast) > Self.leftFor {
                    unlink(file.path)
                }
            }
        }

        /// The slot for one coming in, the one kept let go of; false while another comes in. `done` frees it.
        func begin() -> Bool {
            lock.withLock {
                guard !coming else { return false }
                kept = nil
                coming = true
                return true
            }
        }

        func done() {
            lock.withLock {
                coming = false
            }
        }

        /// The body, into a file of the folder: what is kept and answered, or a status for a body that didn't all
        /// come (what was written of it is gone then).
        func receive(_ reader: Reader, _ request: Request, owner: String) -> Result<String, Refused> {
            var bytes = [UInt8](repeating: 0, count: 16)
            arc4random_buf(&bytes, bytes.count)
            let id = bytes.map {
                String(format: "%02x", $0)
            }
            .joined()
            let path = folder.appendingPathComponent("upload-\(id).ipa").path
            // Made, and said to be coming in, where stopping sees it: not after `end` has taken what is there.
            let fd = lock.withLock { () -> Int32? in
                guard !ended else { return nil }
                incoming = path
                var fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                if fd < 0, errno == ENOENT {
                    // The folder removed meanwhile: made again, once.
                    mkdir(folder.path, 0o700)
                    fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                }
                return fd
            }
            defer {
                lock.withLock {
                    incoming = nil
                }
            }
            guard let fd else { return .failure(503) }
            guard fd >= 0 else { return .failure(507) }
            var hash = SHA256()
            let began = MCPHTTP.now
            var received = 0
            reader.until = began + within + perMiB
            let size = MCPHTTP.framed(reader, request, most: most) { chunk in
                received += chunk.count
                reader.until = began + within + perMiB * Double((received >> 20) + 1)
                hash.update(data: Data(chunk))
                return chunk.withUnsafeBytes { raw in
                    var written = 0
                    while written < raw.count {
                        let n = write(fd, raw.baseAddress! + written, raw.count - written)
                        if n < 0, errno == EINTR {
                            continue
                        }
                        guard n > 0 else { return false }
                        written += n
                    }
                    return true
                }
            }
            close(fd)
            switch size {
            case let .failure(refused):
                unlink(path)
                return .failure(refused)
            case let .success(size):
                let sha256 = hash.finalize()
                    .map {
                        String(format: "%02x", $0)
                    }
                    .joined()
                lock.withLock {
                    kept = (Upload(id: id, owner: owner, sha256: sha256, path: path), Date())
                    // A newer one in: those lent before it aren't kept again (one that didn't all come replaced none).
                    for at in lent.indices {
                        lent[at].keepable = false
                    }
                }
                return .success(MCPHTTP.json(["upload": id, "size": size, "sha256": sha256]))
            }
        }

        /// Why `owner` may not install the upload `id` it names by `sha256`, if it may not: before the call waits its turn.
        func refusal(id: String, owner: String, sha256: String) -> String? {
            lock.withLock {
                guard let held = kept, held.upload.id == id, held.upload.owner == owner else { return Self.gone(id) }
                kept?.used = Date()
                utimes(held.upload.path, nil) // its file's time too: a server starting goes by that
                return held.upload.sha256.caseInsensitiveCompare(sha256) == .orderedSame ? nil :
                    "sha256 \(sha256) isn't upload \(id)'s: nothing was installed"
            }
        }

        /// The upload `id`, named by `sha256`, handed to an install in its turn: linked where the app takes it from, in a
        /// folder install-… of its own in `folder` (as `roamrun mcp` leaves a path's copy). Its path, and what to say once
        /// the app has answered: taken (the upload is used up), or not (it is kept again, unless another came meanwhile).
        func claim(id: String, sha256: String,
                   into folder: URL) throws -> (path: String, settle: (_ taken: Bool) -> Void)
        {
            let upload = try lock.withLock { () -> Upload in
                guard let held = kept, held.upload.id == id,
                      held.upload.sha256.caseInsensitiveCompare(sha256) == .orderedSame
                else { throw Failure(description: Self.gone(id)) }
                kept = nil
                lent.append((held.upload, true))
                return held.upload
            }
            let own = folder.appendingPathComponent("install-\(UUID().uuidString)")
            let path = own.appendingPathComponent("app.ipa").path
            if mkdir(own.path, 0o700) != 0, errno == ENOENT {
                // The folder removed meanwhile: made again, once.
                mkdir(folder.path, 0o700)
                mkdir(own.path, 0o700)
            }
            // A link, not a move: the app removes its folder whatever happens, and the upload's own file is kept.
            guard link(upload.path, path) == 0 else {
                let why = String(cString: strerror(errno))
                let gone = access(upload.path, F_OK) != 0
                rmdir(own.path)
                // Its own file gone (the folder removed meanwhile): nothing is kept.
                settle(upload, taken: gone)
                throw Failure(description: gone ? Self.gone(id) :
                    "the upload couldn't be made ready for the app: \(why). It is kept: try again")
            }
            return (path, { [weak self] taken in
                self?.settle(upload, taken: taken)
            })
        }

        /// The upload lent to an install, once the app has answered: used up, or kept again where nothing replaced it.
        private func settle(_ upload: Upload, taken: Bool) {
            lock.withLock {
                guard let at = lent.firstIndex(where: {
                    $0.upload === upload
                }) else { return }
                let keepable = lent.remove(at: at).keepable
                if !taken, keepable, kept == nil, !coming {
                    kept = (upload, Date())
                } else {
                    unlink(upload.path) // used up: the app has its own link
                }
            }
        }

        /// Lets go of the upload not used since `keptFor` before `now`.
        func sweep(now: Date = Date()) {
            lock.withLock {
                if let held = kept, now.timeIntervalSince(held.used) > Self.keptFor {
                    kept = nil
                }
            }
        }

        /// At stop: what is kept, and what was coming in.
        func end() {
            let left = lock.withLock { () -> [String] in
                // The process ends at once after this: no deinit runs. A lent one's install has its own link.
                let left = ([incoming, kept?.upload.path] + lent.map(\.upload.path)).compactMap {
                    $0
                }
                ended = true
                kept = nil
                lent = []
                return left
            }
            left.forEach {
                unlink($0)
            }
        }

        static func gone(_ id: String) -> String {
            "no upload \(id) is kept here for you (replaced by a later upload, used by an install, or dropped after \(Int(keptFor / 60)) minutes unused): send it again"
        }
    }
}
