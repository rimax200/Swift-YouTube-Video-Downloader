import Foundation
import Combine

enum UpdateStatus: Equatable {
    case idle
    case checking
    case downloading(Double)
    case success(String)
    case error(String)
}

// NSObject base class is required to conform to URLSessionDownloadDelegate
class EngineUpdater: NSObject, ObservableObject {
    @Published var status: UpdateStatus = .idle

    private var downloadSession: URLSession?

    // Mirrors BinaryManager's bin directory — must stay in sync with BinaryManager.appSupportBinPath
    private var ytDlpPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("RXDownloader/bin/yt-dlp").path
    }

    var activeBinaryPath: String {
        let path = ytDlpPath
        if FileManager.default.fileExists(atPath: path) { return path }
        return Bundle.main.path(forResource: "yt-dlp", ofType: nil) ?? ""
    }

    override init() {
        super.init()
        seedInitialBinary()
    }

    /// Copies the bundled binary on first launch if BinaryManager hasn't run yet.
    private func seedInitialBinary() {
        let path = ytDlpPath
        guard !FileManager.default.fileExists(atPath: path) else { return }
        guard let bundlePath = Bundle.main.path(forResource: "yt-dlp", ofType: nil) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: bundlePath, toPath: path)
        setExecutable(at: path)
    }

    // MARK: - Public API

    func checkForUpdates() {
        guard status == .idle else { return }
        status = .checking

        fetchLatestRelease { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let (githubVersion, downloadURL)):
                let localVersion = self.getLocalVersion()
                if githubVersion != localVersion {
                    self.performDownload(from: downloadURL)
                } else {
                    DispatchQueue.main.async {
                        self.status = .success("Already up to date (\(localVersion))")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.status = .idle }
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async { self.status = .error(error.localizedDescription) }
            }
        }
    }

    // MARK: - Private Helpers

    private func getLocalVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: activeBinaryPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch { return "" }
    }

    private func fetchLatestRelease(completion: @escaping (Result<(String, URL), Error>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else {
                completion(.failure(NSError(domain: "EngineUpdater", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "No data from GitHub"])))
                return
            }
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let assets = json["assets"] as? [[String: Any]],
                      let asset = assets.first(where: { ($0["name"] as? String) == "yt-dlp" }),
                      let urlString = asset["browser_download_url"] as? String,
                      let downloadURL = URL(string: urlString) else {
                    completion(.failure(NSError(domain: "EngineUpdater", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not parse release assets"])))
                    return
                }
                completion(.success((tagName, downloadURL)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func performDownload(from url: URL) {
        DispatchQueue.main.async { self.status = .downloading(0.0) }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: url).resume()
    }

    private func installBinary(from tempURL: URL) {
        let destinationURL = URL(fileURLWithPath: ytDlpPath)
        let fm = FileManager.default

        // Ensure the bin directory exists
        try? fm.createDirectory(at: destinationURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destinationURL)
            }
            setExecutable(at: destinationURL.path)
            removeQuarantine(at: destinationURL)
            DispatchQueue.main.async {
                self.status = .success("Updated successfully")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.status = .idle }
            }
        } catch {
            DispatchQueue.main.async {
                self.status = .error("Installation failed: \(error.localizedDescription)")
            }
        }
    }

    private func setExecutable(at path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func removeQuarantine(at url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.quarantineProperties = nil
        try? mutableURL.setResourceValues(values)
    }
}

// MARK: - URLSessionDownloadDelegate (progress tracking)

extension EngineUpdater: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.status = .downloading(progress) }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        installBinary(from: location)
        session.finishTasksAndInvalidate()
        downloadSession = nil
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error = error else { return }
        DispatchQueue.main.async { self.status = .error(error.localizedDescription) }
        session.finishTasksAndInvalidate()
        downloadSession = nil
    }
}
