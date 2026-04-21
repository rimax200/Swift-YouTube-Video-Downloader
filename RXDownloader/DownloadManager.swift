import Foundation
import Combine
import AppKit

class DownloadManager: ObservableObject {
    @Published var progress: Double = 0.0
    @Published var status: DownloadStatus = .idle
    @Published var isDownloading: Bool = false
    @Published var downloadedFilePath: String? = nil
    @Published var currentMetadata: VideoMetadata? = nil
    @Published var downloadLocation: URL
    
    private var logBuffer: [String] = []
    
    // Binary Environment and Updater
    @Published var updater = EngineUpdater()
    private let binaryManager = BinaryManager.shared
    
    // Explicit paths used by Process() calls
    private var ytDlpPath: String {
        return binaryManager.getBinaryPath(for: "yt-dlp")
    }
    
    private var ffmpegPath: String {
        return binaryManager.getBinaryPath(for: "ffmpeg")
    }
    
    private var ffprobePath: String {
        return binaryManager.getBinaryPath(for: "ffprobe")
    }
    
    private var binariesDirectory: String {
        return binaryManager.getBinaryPath(for: "")
    }
    
    private var process: Process?
    private var outputPipe: Pipe?
    
    init() {
        // Default to Downloads folder
        self.downloadLocation = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        ensureBinariesAreExecutable()
    }
    
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose download destination"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                DispatchQueue.main.async {
                    self.downloadLocation = url
                }
            }
        }
    }
    
    private func ensureBinariesAreExecutable() {
        let fileManager = FileManager.default
        let binaries = [ytDlpPath, ffmpegPath, ffprobePath].filter { !$0.isEmpty }
        
        for path in binaries {
            if fileManager.fileExists(atPath: path) {
                let attributes = [FileAttributeKey.posixPermissions: 0o755]
                try? fileManager.setAttributes(attributes, ofItemAtPath: path)
                
                var url = URL(fileURLWithPath: path)
                var values = URLResourceValues()
                values.quarantineProperties = nil
                try? url.setResourceValues(values)
            }
        }
    }
    
    private var formatFetchProcess: Process?
    
    /// Cancel any in-flight metadata or format-fetch processes.
    func cancelFetch() {
        formatFetchProcess?.terminate()
        formatFetchProcess = nil
    }
    
    // MARK: - Sandbox Optimization Helper
    
    /// Configures a Process with the necessary shims to bypass Sandbox search latencies.
    private func configureSandboxProcess(_ process: Process, withArguments specificArgs: [String], url videoURL: String) {
        // Use explicit binary names - exactly as in Bundle
        let binaryName = "yt-dlp"
        let ytPath = binaryManager.getBinaryPath(for: binaryName)
        let binPath = binaryManager.getBinaryPath(for: "")

        // 0. Verify using fileExists
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: ytPath)
        print("[DownloadManager] Checking yt-dlp at: \(ytPath) -> exists: \(exists)")

        // Try Bundle resources as fallback
        var finalPath = ytPath
        if !exists, let bundlePath = Bundle.main.path(forResource: binaryName, ofType: nil) {
            print("[DownloadManager] Using Bundle path fallback: \(bundlePath)")
            finalPath = bundlePath
        }

        // 1. Setup Process with proper URL - exact casing
        let execURL = URL(fileURLWithPath: finalPath)
        process.executableURL = execURL
        process.currentDirectoryURL = execURL.deletingLastPathComponent()
        process.qualityOfService = .userInitiated

        print("[DownloadManager] EXEC: executableURL = \(execURL.path)")
        print("[DownloadManager] EXEC: currentDirectory = \(execURL.deletingLastPathComponent().path)")

        // 2. Explicit Cache directory
        let cachesURL = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cachePath = cachesURL.appendingPathComponent("yt-dlp-cache").path
        try? fm.createDirectory(atPath: cachePath, withIntermediateDirectories: true)

        // 3. Build arguments
        var args = [
            "--no-warnings",
            "--no-check-certificate",
            "--no-playlist",
            "--flat-playlist",
            "--no-config",
            "--cache-dir", cachePath,
            "--ffmpeg-location", binPath
        ]
        args.append(contentsOf: specificArgs)
        args.append(videoURL)
        process.arguments = args

        // 4. Explicit Environment - full Sandbox bypass
        let env: [String: String] = [
            "HOME": fm.temporaryDirectory.path,
            "PATH": "\(binPath):/usr/bin:/bin:/usr/sbin:/sbin",
            "PYTHONDONTWRITEBYTECODE": "1",
            "LANG": "en_US.UTF-8"
        ]
        process.environment = env

        print("[DownloadManager] EXEC: PATH = \(binPath):/usr/bin:/bin:/usr/sbin:/sbin")
        print("[DownloadManager] EXEC: arguments = \(args)")
    }
    
    // MARK: - Public Entry Point
    
    func fetchVideoDetails(url: String) {
        guard !url.isEmpty else { return }
        cancelFetch()
        
        DispatchQueue.main.async {
            self.status = .fetching
            self.currentMetadata = nil
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.fastPathFetch(url: url)
        }
    }
    
    private func fastPathFetch(url: String) {
        let process = Process()
        let fetchArgs = ["--print", "%(title)s|%(thumbnail)s|%(duration)s|%(filesize_approx)s|%(id)s"]
        
        configureSandboxProcess(process, withArguments: fetchArgs, url: url)
        
        guard process.executableURL != nil else {
            print("[DownloadManager] ERROR: executableURL not set")
            DispatchQueue.main.async { self.status = .failed("Failed to configure process.") }
            return
        }
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        print("[DownloadManager] DEBUG: Launching \(process.executableURL!.path) with args: \(process.arguments ?? [])")
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                DispatchQueue.main.async { self.status = .failed("Preview fetch failed.") }
                return
            }
            
            let parts = output.components(separatedBy: "|")
            guard parts.count >= 5 else {
                DispatchQueue.main.async { self.status = .failed("Parsing error.") }
                return
            }
            
            let preview = VideoMetadata(
                id: parts[4],
                title: parts[0],
                thumbnail: parts[1] == "NA" ? "" : parts[1],
                duration: Double(parts[2]),
                filesizeApprox: Int64(parts[3]),
                formats: []
            )
            
            DispatchQueue.main.async {
                self.currentMetadata = preview
                self.status = .fetchingFormats
            }
            
            self.lazyFormatFetch(url: url)
        } catch {
            DispatchQueue.main.async { self.status = .failed(error.localizedDescription) }
        }
    }
    
    private func lazyFormatFetch(url: String) {
        let process = Process()
        self.formatFetchProcess = process
        configureSandboxProcess(process, withArguments: ["-j", "--skip-download"], url: url)
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                DispatchQueue.main.async { if self.status == .fetchingFormats { self.status = .idle } }
                return
            }
            
            if let fullMeta = try? JSONDecoder().decode(VideoMetadata.self, from: data) {
                DispatchQueue.main.async {
                    self.currentMetadata?.formats = fullMeta.formats
                    if self.status == .fetchingFormats { self.status = .idle }
                }
            }
        } catch {
            DispatchQueue.main.async { if self.status == .fetchingFormats { self.status = .idle } }
        }
    }
    
    func startDownload(url: String, type: DownloadType, formatID: String?) {
        guard validateEngine() else { return }
        
        self.progress = 0.0
        self.isDownloading = true
        self.status = .downloading(0.0)
        self.logBuffer = []
        
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            self.process = process
            
            var specificArgs: [String] = []
            
            switch type {
            case .video:
                let fid = formatID ?? "bestvideo+bestaudio/best"
                specificArgs.append(contentsOf: ["-f", fid])
            case .audio:
                let fid = formatID ?? "bestaudio/best"
                specificArgs.append(contentsOf: ["-f", fid, "-x", "--audio-format", "mp3"])
            case .thumbnail:
                specificArgs.append(contentsOf: ["--write-thumbnail", "--skip-download"])
            }
            
            let outputPath = self.downloadLocation.path
            specificArgs.append(contentsOf: ["-o", "\(outputPath)/%(title)s.%(ext)s", "--newline"])
            
            self.configureSandboxProcess(process, withArguments: specificArgs, url: url)
            
            let pipe = Pipe()
            self.outputPipe = pipe
            process.standardOutput = pipe
            process.standardError = pipe
            
            let fileHandle = pipe.fileHandleForReading
            fileHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let output = String(data: data, encoding: .utf8) {
                    output.components(separatedBy: .newlines).forEach { line in
                        if !line.isEmpty {
                            self?.parseOutput(line)
                            self?.logBuffer.append(line)
                        }
                    }
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
        process?.terminate()
        cleanup()
    }
    
    private func parseOutput(_ line: String) {
        let pattern = #"(?:\[download\]|\[ExtractAudio\])\s+([0-9.]+)%"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, options: [], range: range) {
                if let percentRange = Range(match.range(at: 1), in: line),
                   let percentValue = Double(line[percentRange]) {
                    DispatchQueue.main.async {
                        self.progress = percentValue / 100.0
                        self.status = .downloading(self.progress)
                    }
                }
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
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if let match = regex.firstMatch(in: line, options: [], range: range) {
                    if let pathRange = Range(match.range(at: 1), in: line) {
                        let path = String(line[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                                                          .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        DispatchQueue.main.async { self.downloadedFilePath = path }
                        break
                    }
                }
            }
        }
    }
    
    private func cleanup() {
        DispatchQueue.main.async {
            self.isDownloading = false
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.process = nil
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
