import Foundation

/// Trwały zapis piosenek na dysku. Pierwsze odtworzenie leci ze strumienia, a w tle utwór jest pobierany
/// do końca i zostaje na stałe - każde kolejne odtworzenie startuje natychmiast i działa bez internetu.
actor AudioCache {
    static let shared = AudioCache()

    private let dir: URL
    private let session: URLSession
    private var inflight: [String: Task<URL?, Never>] = [:]
    private var slots = 0
    private let maxSlots = 4
    private var urgentWaiters: [CheckedContinuation<Void, Never>] = []
    private var normalWaiters: [CheckedContinuation<Void, Never>] = []

    /// yt-dlp pobiera w kawałkach ~10 MB, bo YouTube dławi długie, pojedyncze żądania.
    private static let chunk = 9_437_184

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var folder = base.appendingPathComponent("Lumen/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true      // duże pliki nie lecą do iCloud
        try? folder.setResourceValues(values)
        dir = folder
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg)
    }

    // MARK: Lookup

    /// Pobrany plik utworu (jeśli już jest na dysku).
    func localURL(for id: String) -> URL? {
        for ext in ["m4a", "mp4"] {
            let url = dir.appendingPathComponent("\(id).\(ext)")
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 50_000 {
                return url
            }
        }
        return nil
    }

    func remove(id: String) {
        for ext in ["m4a", "mp4"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).\(ext)"))
        }
    }

    /// Usuwa wszystkie pobrane piosenki. Zwraca liczbę usuniętych plików.
    @discardableResult
    func removeAll() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var n = 0
        for f in files {
            if (try? FileManager.default.removeItem(at: f)) != nil, f.pathExtension != "part" { n += 1 }
        }
        return n
    }

    func stats() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var count = 0
        var bytes: Int64 = 0
        for f in files where f.pathExtension == "m4a" || f.pathExtension == "mp4" {
            count += 1
            bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (count, bytes)
    }

    // MARK: Download

    /// Upewnia się, że utwór jest na dysku (pobiera go, jeśli trzeba). Zwraca adres pliku.
    /// `urgent` = bieżący / następny utwór (omija kolejkę masowego pobierania playlisty).
    @discardableResult
    func ensure(_ id: String, urgent: Bool = true) async -> URL? {
        if let local = localURL(for: id) { return local }
        if let running = inflight[id] { return await running.value }
        await DownloadProgress.shared.set(id, 0)
        let task = Task<URL?, Never> { await self.fetch(id, urgent: urgent) }
        inflight[id] = task
        let result = await task.value
        inflight[id] = nil
        await DownloadProgress.shared.clear(id)
        if result != nil {
            // Do pobranej piosenki zapisujemy też jej dużą okładkę (tło i ekran odtwarzacza bez internetu).
            Task.detached(priority: .utility) { _ = await ArtworkLoader.shared.artwork(for: id) }
        }
        return result
    }

    private func acquire(urgent: Bool) async {
        if slots < maxSlots { slots += 1; return }
        await withCheckedContinuation { cont in
            if urgent { urgentWaiters.append(cont) } else { normalWaiters.append(cont) }
        }
    }

    private func release() {
        if !urgentWaiters.isEmpty { urgentWaiters.removeFirst().resume() }
        else if !normalWaiters.isEmpty { normalWaiters.removeFirst().resume() }
        else { slots -= 1 }
    }

    private func fetch(_ id: String, urgent: Bool) async -> URL? {
        await acquire(urgent: urgent)
        defer { release() }
        if let local = localURL(for: id) { return local }
        for attempt in 0..<2 {
            guard let stream = try? await StreamResolver.shared.resolve(id, forceRefresh: attempt > 0) else { continue }
            let target = dir.appendingPathComponent("\(id).\(stream.ext)")
            if await download(stream.url, to: target, id: id) { return target }
        }
        return nil
    }

    private func download(_ remote: URL, to target: URL, id: String) async -> Bool {
        // Unikalny plik tymczasowy: dwa równoległe pobrania nigdy nie dopiszą do tego samego pliku.
        let part = target.appendingPathExtension("\(UUID().uuidString).part")
        let fm = FileManager.default
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part) else { return false }
        defer { try? handle.close() }

        var offset = 0
        var total = Int.max
        while offset < total {
            if Task.isCancelled { try? fm.removeItem(at: part); return false }
            var request = URLRequest(url: remote)
            request.setValue("bytes=\(offset)-\(offset + AudioCache.chunk - 1)", forHTTPHeaderField: "Range")
            guard let (bytes, response) = try? await session.bytes(for: request),
                  let http = response as? HTTPURLResponse else { try? fm.removeItem(at: part); return false }
            switch http.statusCode {
            case 206:
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let slash = range.lastIndex(of: "/"), let t = Int(range[range.index(after: slash)...]) {
                    total = t
                }
            case 200:
                // Serwer zignorował zakres i przysłał całość: zaczynamy plik od zera, żeby nie dokleić go drugi raz.
                do { try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0) } catch { try? fm.removeItem(at: part); return false }
                offset = 0
                total = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : Int.max
            default:
                try? fm.removeItem(at: part)
                return false
            }
            // Dane spływają na bieżąco, więc procent pobierania w odtwarzaczu stale się aktualizuje.
            var buffer = Data()
            var received = 0
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    received += 1
                    if buffer.count >= 65_536 {
                        try handle.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                        await DownloadProgress.shared.set(id, total == Int.max ? -1 : Double(offset + received) / Double(total))
                    }
                }
                if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            } catch { try? fm.removeItem(at: part); return false }
            if received == 0 { try? fm.removeItem(at: part); return false }
            offset += received
            if http.statusCode == 200 || (total == Int.max && received < AudioCache.chunk) { total = offset }
            await DownloadProgress.shared.set(id, total == Int.max ? -1 : Double(offset) / Double(total))
        }
        try? handle.close()
        guard offset > 50_000, offset == total else { try? fm.removeItem(at: part); return false }
        try? fm.removeItem(at: target)
        do { try fm.moveItem(at: part, to: target) } catch { try? fm.removeItem(at: part); return false }
        return true
    }
}
