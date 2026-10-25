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
        /// Time for a body, beyond `bodyWithin`, by its size.
        static let perMiB: TimeInterval = 2

        let folder: URL
        /// The most taken, in bytes.
        let most: Int
        private let lock = NSLock()
        private var kept: (upload: Upload, used: Date)?
        private var coming = false
        /// The file one coming in is written to.
        private var incoming: String?

        init(folder: URL, most: Int) {
            self.folder = folder
            self.most = most
            // What a server ended without Ctrl-C (killed, or the Mac gone down) left: none is kept that long.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                where name.hasPrefix("upload-") && name.hasSuffix(".ipa")
            {
                let file = folder.appendingPathComponent(name)
                let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
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
            var fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd < 0, errno == ENOENT {
                // The folder removed meanwhile: made again, once.
                mkdir(folder.path, 0o700)
                fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            }
            guard fd >= 0 else { return .failure(507) }
            lock.withLock {
                incoming = path
            }
            defer {
                lock.withLock {
                    incoming = nil
                }
            }
            var hash = SHA256()
            let size = MCPHTTP.framed(reader, request, most: most) { chunk in
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

        /// The upload `id`, named by `sha256`, used up by an install in its turn: moved where the app takes it, in a
        /// folder install-… of its own in `folder` (as `roamrun mcp` leaves a path's copy); its path.
        func claim(id: String, sha256: String, into folder: URL) throws -> String {
            let upload = try lock.withLock { () -> Upload in
                guard let held = kept, held.upload.id == id,
                      held.upload.sha256.caseInsensitiveCompare(sha256) == .orderedSame
                else { throw Failure(description: Self.gone(id)) }
                kept = nil
                return held.upload
            }
            let own = folder.appendingPathComponent("install-\(UUID().uuidString)")
            let path = own.appendingPathComponent("app.ipa").path
            guard mkdir(own.path, 0o700) == 0, rename(upload.path, path) == 0 else {
                let why = String(cString: strerror(errno))
                rmdir(own.path)
                throw Failure(description: "the upload couldn't be made ready for the app: \(why)")
            }
            return path
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
            let left = lock.withLock { () -> String? in
                kept = nil
                return incoming
            }
            if let left {
                unlink(left)
            }
        }

        static func gone(_ id: String) -> String {
            "no upload \(id) is kept here for you (replaced by a later upload, used by an install, or dropped after \(Int(keptFor / 60)) minutes unused): send it again"
        }
    }
}
