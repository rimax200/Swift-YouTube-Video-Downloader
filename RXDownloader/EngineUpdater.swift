import Foundation
import Combine

enum UpdateStatus: Equatable {
    case idle
    case checking
    case downloading(Double)
    case success(String)
    case error(String)
}

class EngineUpdater: ObservableObject {
    @Published var status: UpdateStatus = .idle
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Paths
    
    private let binaryName = "yt-dlp"
    
    private var appSupportBinDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let binDir = appSupport.appendingPathComponent("Binaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        return binDir
    }
    
    var activeBinaryPath: String {
        let localURL = appSupportBinDir.appendingPathComponent(binaryName)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL.path
        }
        // Fallback to bundle version if we haven't seeded yet
        return Bundle.main.path(forResource: binaryName, ofType: nil) ?? ""
    }
    
    // MARK: - Lifecycle
    
    init() {
        seedInitialBinary()
    }
    
    /// Copies the bundled binary to Application Support on first launch
    private func seedInitialBinary() {
        let localURL = appSupportBinDir.appendingPathComponent(binaryName)
        if !FileManager.default.fileExists(atPath: localURL.path) {
            if let bundlePath = Bundle.main.path(forResource: binaryName, ofType: nil) {
                try? FileManager.default.copyItem(atPath: bundlePath, toPath: localURL.path)
                setExecutablePermissions(at: localURL.path)
            }
        }
    }
    
    // MARK: - Update Logic
    
    func checkForUpdates() {
        guard status == .idle else { return }
        status = .checking
        
        fetchLatestReleaseMetadata { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let githubVersion, let downloadURL):
                let localVersion = self.getLocalVersion()
                
                if githubVersion != localVersion {
                    print("Update available: \(localVersion) -> \(githubVersion)")
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
    
    private func getLocalVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: activeBinaryPath)
        process.arguments = ["--version"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
    
    private func fetchLatestReleaseMetadata(completion: @escaping (Result<(String, URL), Error>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(NSError(domain: "EngineUpdater", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data from GitHub"]))); return }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String,
                   let assets = json["assets"] as? [[String: Any]] {
                    
                    // Find the asset named "yt-dlp" (generic Unix/Mac binary)
                    if let asset = assets.first(where: { ($0["name"] as? String) == "yt-dlp" }),
                       let downloadURLString = asset["browser_download_url"] as? String,
                       let downloadURL = URL(string: downloadURLString) {
                        completion(.success((tagName, downloadURL)))
                        return
                    }
                }
                completion(.failure(NSError(domain: "EngineUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not parse release assets"])))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    private func performDownload(from url: URL) {
        DispatchQueue.main.async { self.status = .downloading(0.0) }
        
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async { self.status = .error(error.localizedDescription) }
                return
            }
            
            guard let tempURL = tempURL else {
                DispatchQueue.main.async { self.status = .error("Download failed") }
                return
            }
            
            self.replaceBinary(with: tempURL)
        }
        
        // Track progress if needed (simplified here)
        task.resume()
    }
    
    private func replaceBinary(with tempURL: URL) {
        let destinationURL = appSupportBinDir.appendingPathComponent(binaryName)
        let fileManager = FileManager.default
        
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }
            
            setExecutablePermissions(at: destinationURL.path)
            
            DispatchQueue.main.async {
                self.status = .success("Updated successfully")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.status = .idle }
            }
        } catch {
            DispatchQueue.main.async { self.status = .error("File replacement error: \(error.localizedDescription)") }
        }
    }
    
    private func setExecutablePermissions(at path: String) {
        let attributes = [FileAttributeKey.posixPermissions: 0o755]
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: path)
    }
}
