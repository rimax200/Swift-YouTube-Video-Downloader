import Foundation
import Combine
import AppKit
import UserNotifications

class DownloadManager: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var status: DownloadStatus = .idle
    @Published var isDownloading: Bool = false
    @Published var downloadedFilePath: String? = nil
    @Published var currentMetadata: VideoMetadata? = nil
    @Published var downloadLocation: URL

    @Published var updater = EngineUpdater()

    private let binaryManager = BinaryManager.shared
    private var logBuffer: [String] = []
    private var fetchProcess: Process?
    private var downloadProcess: Process?
    private var outputPipe: Pipe?
    private var cancellables = Set<AnyCancellable>()

    // Incremented on every new fetch; lets background closures detect they are stale.
    private var currentFetchID: UUID = UUID()
    private var notificationPermissionRequested = false

    private var ytDlpPath: String { binaryManager.getBinaryPath(for: "yt-dlp") }
    private var ffmpegPath: String { binaryManager.getBinaryPath(for: "ffmpeg") }
    private var ffprobePath: String { binaryManager.getBinaryPath(for: "ffprobe") }
    private var binariesDirectory: String { binaryManager.getBinaryPath(for: "") }

    init() {
        self.downloadLocation = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        ensureBinariesAreExecutable()

        updater.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose download destination"
        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.main.async { self.downloadLocation = url }
        }
    }

    private func ensureBinariesAreExecutable() {
        let fileManager = FileManager.default
        for path in [ytDlpPath, ffmpegPath, ffprobePath].filter({ !$0.isEmpty }) {
            guard fileManager.fileExists(atPath: path) else { continue }
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            var url = URL(fileURLWithPath: path)
            var values = URLResourceValues()
            values.quarantineProperties = nil
            try? url.setResourceValues(values)
        }
    }

    // MARK: - Fetch Cancellation

    func cancelFetch() {
        fetchProcess?.terminate()
        fetchProcess = nil
        currentFetchID = UUID() // invalidate all in-flight preview/oEmbed callbacks
    }

    // MARK: - Process Configuration

    private func configureSandboxProcess(_ process: Process, withArguments args: [String], url videoURL: String) {
        let fm = FileManager.default
        var finalPath = ytDlpPath
        if !fm.fileExists(atPath: finalPath),
           let bundlePath = Bundle.main.path(forResource: "yt-dlp", ofType: nil) {
            finalPath = bundlePath
        }

        let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cachePath = cachesURL.appendingPathComponent("yt-dlp-cache").path
        try? fm.createDirectory(atPath: cachePath, withIntermediateDirectories: true)

        let binPath = binariesDirectory
        let execURL = URL(fileURLWithPath: finalPath)
        process.executableURL = execURL
        process.currentDirectoryURL = execURL.deletingLastPathComponent()
        process.qualityOfService = .userInitiated

        var fullArgs: [String] = [
            "--no-warnings",
            "--no-check-certificate",
            "--no-playlist",
            "--no-config",
            "--socket-timeout", "15",
            "--extractor-retries", "1",
            "--cache-dir", cachePath,
            "--ffmpeg-location", binPath
        ]
        fullArgs.append(contentsOf: args)
        fullArgs.append(videoURL)
        process.arguments = fullArgs

        process.environment = [
            "HOME": fm.temporaryDirectory.path,
            "PATH": "\(binPath):/usr/bin:/bin:/usr/sbin:/sbin",
            "PYTHONDONTWRITEBYTECODE": "1",
            "LANG": "en_US.UTF-8"
        ]
    }

    // MARK: - YouTube Quick Preview

    /// Extracts the 11-character YouTube video ID from common URL formats.
    private func extractYouTubeID(from url: String) -> String? {
        let pattern = #"(?:youtu\.be/|youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/|v/))([A-Za-z0-9_-]{11})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let range = Range(match.range(at: 1), in: url) else { return nil }
        return String(url[range])
    }

    /// Hits YouTube's public oEmbed endpoint for the video title and thumbnail.
    /// Fast (~1s), requires no authentication, works for all public videos.
    private func fetchOEmbedTitle(for url: String, fetchID: UUID) {
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        guard let endpoint = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json") else { return }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String else { return }

            let thumbnail = json["thumbnail_url"] as? String

            DispatchQueue.main.async {
                // Bail if a newer fetch has started or yt-dlp already finished
                guard self.currentFetchID == fetchID,
                      self.status == .fetching,
                      let current = self.currentMetadata else { return }

                self.currentMetadata = VideoMetadata(
                    id: current.id,
                    title: title,
                    thumbnail: thumbnail ?? current.thumbnail,
                    duration: current.duration,
                    filesizeApprox: current.filesizeApprox,
                    formats: current.formats
                )
            }
        }.resume()
    }

    // MARK: - Public Fetch Entry Point

    func fetchVideoDetails(url: String) {
        guard !url.isEmpty else { return }
        cancelFetch() // cancels old process AND rotates currentFetchID

        let fetchID = currentFetchID

        if let videoId = extractYouTubeID(from: url) {
            // Instant preview: thumbnail from YouTube CDN (no network wait)
            let quickMeta = VideoMetadata(
                id: videoId,
                title: "",
                thumbnail: "https://img.youtube.com/vi/\(videoId)/hqdefault.jpg",
                duration: nil,
                formats: []
            )
            DispatchQueue.main.async {
                self.currentMetadata = quickMeta
                self.status = .fetching
            }
            // Fetch title via oEmbed in parallel (~1s, much faster than yt-dlp)
            fetchOEmbedTitle(for: url, fetchID: fetchID)
        } else {
            DispatchQueue.main.async {
                self.status = .fetching
                self.currentMetadata = nil
            }
        }

        // Full metadata + formats via yt-dlp in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runMetadataFetch(url: url, fetchID: fetchID)
        }
    }

    // MARK: - yt-dlp Metadata Fetch (single pass)

    private func runMetadataFetch(url: String, fetchID: UUID) {
        let process = Process()
        fetchProcess = process
        configureSandboxProcess(process, withArguments: ["-j", "--skip-download"], url: url)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        var accumulated = Data()
        let fileHandle = pipe.fileHandleForReading
        let sem = DispatchSemaphore(value: 0)

        fileHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil
                sem.signal()
            } else {
                accumulated.append(chunk)
            }
        }

        do {
            try process.run()
            _ = sem.wait(timeout: .now() + 60)
            process.waitUntilExit()
            fileHandle.readabilityHandler = nil

            // Discard result if this fetch was cancelled or superseded
            guard currentFetchID == fetchID else { return }

            guard process.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    guard self.currentFetchID == fetchID else { return }
                    self.status = .failed("Could not fetch video info.")
                    self.currentMetadata = nil
                }
                return
            }

            guard let metadata = try? JSONDecoder().decode(VideoMetadata.self, from: accumulated) else {
                DispatchQueue.main.async {
                    guard self.currentFetchID == fetchID else { return }
                    self.status = .failed("Failed to parse video metadata.")
                    self.currentMetadata = nil
                }
                return
            }

            DispatchQueue.main.async {
                guard self.currentFetchID == fetchID else { return }
                self.currentMetadata = metadata
                self.status = .idle
            }
        } catch {
            DispatchQueue.main.async {
                guard self.currentFetchID == fetchID else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Download

    func startDownload(url: String, type: DownloadType, formatID: String?) {
        guard validateEngine() else { return }

        requestNotificationPermissionIfNeeded()

        self.progress = 0.0
        self.isDownloading = true
        self.status = .downloading(0.0)
        self.logBuffer = []

        let videoTitle = currentMetadata?.title ?? ""

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            self.downloadProcess = process

            var specificArgs: [String] = []
            switch type {
            case .video:
                specificArgs += ["-f", formatID ?? "bestvideo+bestaudio/best"]
            case .audio:
                specificArgs += ["-f", formatID ?? "bestaudio/best", "-x", "--audio-format", "mp3"]
            case .thumbnail:
                specificArgs += ["--write-thumbnail", "--skip-download"]
            }

            let outputPath = self.downloadLocation.path
            specificArgs += ["-o", "\(outputPath)/%(title)s.%(ext)s", "--newline"]

            self.configureSandboxProcess(process, withArguments: specificArgs, url: url)

            let pipe = Pipe()
            self.outputPipe = pipe
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
                output.components(separatedBy: .newlines).forEach { line in
                    guard !line.isEmpty else { return }
                    self?.parseOutput(line)
                    self?.logBuffer.append(line)
                }
            }

            do {
                try process.run()
                process.waitUntilExit()

                let exitCode = process.terminationStatus
                DispatchQueue.main.async {
                    if exitCode == 0 {
                        self.status = .completed
                        self.progress = 1.0
                        self.playCompletionFeedback(videoTitle: videoTitle)
                    } else {
                        let lastLogs = self.logBuffer.suffix(2).joined(separator: "\n")
                        self.status = .failed(lastLogs.isEmpty ? "Error code \(exitCode)" : lastLogs)
                    }
                    self.cleanup()
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = .failed(error.localizedDescription)
                    self.cleanup()
                }
            }
        }
    }

    func stopDownload() {
        downloadProcess?.terminate()
        cleanup()
    }

    // MARK: - Completion Feedback

    private func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func playCompletionFeedback(videoTitle: String) {
        NSSound(named: NSSound.Name("Glass"))?.play()

        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = videoTitle.isEmpty
            ? "Your download is ready."
            : "\"\(videoTitle)\" has been downloaded."

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Output Parsing

    private func parseOutput(_ line: String) {
        let progressPattern = #"(?:\[download\]|\[ExtractAudio\])\s+([0-9.]+)%"#
        if let regex = try? NSRegularExpression(pattern: progressPattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let range = Range(match.range(at: 1), in: line),
           let value = Double(line[range]) {
            DispatchQueue.main.async {
                self.progress = value / 100.0
                self.status = .downloading(self.progress)
            }
        }

        if line.contains("[ExtractAudio]") && !line.contains("%") {
            DispatchQueue.main.async { self.status = .processing }
        }

        let pathPatterns = [
            #"\[(?:download|ExtractAudio|ffmpeg)\]\s+Destination:\s+(.*)"#,
            #"\[download\]\s+(.*)\s+has already been downloaded"#,
            #"\[ffmpeg\]\s+Merging formats into\s+"?([^"]*)"?"#,
            #"\[info\]\s+Writing thumbnail to:\s+(.*)"#
        ]
        for pattern in pathPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                let path = String(line[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                DispatchQueue.main.async { self.downloadedFilePath = path }
                break
            }
        }
    }

    private func cleanup() {
        DispatchQueue.main.async {
            self.isDownloading = false
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.downloadProcess = nil
        }
    }

    @discardableResult
    func validateEngine() -> Bool {
        ensureBinariesAreExecutable()
        return FileManager.default.fileExists(atPath: ytDlpPath) &&
               FileManager.default.fileExists(atPath: ffmpegPath) &&
               FileManager.default.fileExists(atPath: ffprobePath)
    }
}
