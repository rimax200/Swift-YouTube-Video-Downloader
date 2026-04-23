import Foundation

class BinaryManager {
    static let shared = BinaryManager()
    
    private let fileManager = FileManager.default
    private let binaries = ["yt-dlp", "ffmpeg", "ffprobe"]
    
    private var appSupportBinPath: String {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("RXDownloader")
        return appFolder.appendingPathComponent("bin").path
    }
    
    private init() {}
    
    func prepareBinaries() {
        print("=== BinaryManager: Starting Binary Setup ===")
        
        createAppSupportDirectory()
        syncBinaries()
        
        print("=== BinaryManager: Setup Complete ===\n")
    }
    
    private func createAppSupportDirectory() {
        print("[BinaryManager] Creating directory: \(appSupportBinPath)")
        
        do {
            try fileManager.createDirectory(atPath: appSupportBinPath, withIntermediateDirectories: true, attributes: nil)
            print("[BinaryManager] ✓ Directory created with intermediate parents")
        } catch {
            print("[BinaryManager] ✗ Failed to create directory: \(error.localizedDescription)")
        }
    }
    
    private func syncBinaries() {
        for binaryName in binaries {
            verifyAndSyncBinary(named: binaryName)
        }
    }
    
    private func verifyAndSyncBinary(named name: String) {
        print("\n[BinaryManager] === Processing: \(name) ===")
        
        guard let sourceURL = Bundle.main.url(forResource: name, withExtension: nil) else {
            let msg = "CRITICAL: \(name) missing from App Bundle. Check Target Membership in Xcode."
            print("[BinaryManager] ✗ \(msg)")
            fatalError(msg)
        }
        
        print("[BinaryManager] ✓ Source found in bundle: \(sourceURL.path)")
        
        let destinationPath = (appSupportBinPath as NSString).appendingPathComponent(name)
        
        copyBinaryIfNeeded(from: sourceURL.path, to: destinationPath, name: name)
    }
    
    private func copyBinaryIfNeeded(from sourcePath: String, to destinationPath: String, name: String) {
        let sourceExists = fileManager.fileExists(atPath: sourcePath)
        let destExists = fileManager.fileExists(atPath: destinationPath)
        
        var shouldCopy = false
        
        if !destExists {
            print("[BinaryManager]   - Destination missing, will copy")
            shouldCopy = true
        } else if let sourceMod = try? fileManager.attributesOfItem(atPath: sourcePath)[.modificationDate] as? Date,
                  let destMod = try? fileManager.attributesOfItem(atPath: destinationPath)[.modificationDate] as? Date {
            if sourceMod > destMod {
                print("[BinaryManager]   - Source newer (\(sourceMod)) > Dest (\(destMod)), will copy")
                shouldCopy = true
            } else {
                print("[BinaryManager]   - Destination up to date")
            }
        }
        
        if shouldCopy {
            do {
                if destExists {
                    try fileManager.removeItem(atPath: destinationPath)
                }
                try fileManager.copyItem(atPath: sourcePath, toPath: destinationPath)
                print("[BinaryManager]   ✓ Copied to Application Support")
                
                fixPermissions(for: destinationPath, name: name)
            } catch {
                print("[BinaryManager]   ✗ Copy failed: \(error.localizedDescription)")
            }
        } else {
            fixPermissions(for: destinationPath, name: name)
        }
    }
    
    private func fixPermissions(for path: String, name: String) {
        do {
            let attributes = [FileAttributeKey.posixPermissions: 0o755]
            try fileManager.setAttributes(attributes, ofItemAtPath: path)
            
            if let currentAttrs = try? fileManager.attributesOfItem(atPath: path),
               let perms = currentAttrs[.posixPermissions] as? Int {
                print("[BinaryManager]   ✓ Permissions set to 0o755 (current: \(String(format: "%o", perms)))")
            }
            
            removeQuarantineAttribute(for: path)
            validateBinary(at: path, name: name)
        } catch {
            print("[BinaryManager]   ✗ Failed to set permissions: \(error.localizedDescription)")
        }
    }
    
    private func validateBinary(at path: String, name: String) {
        let exists = fileManager.fileExists(atPath: path)
        
        if exists {
            print("[BinaryManager] ✓ SUCCESS: Binary is verified and executable at \(path)")
        } else {
            print("[BinaryManager] ✗ ERROR: Copy failed or Sandbox blocked the write.")
        }
    }
    
    private func removeQuarantineAttribute(for path: String) {
        var url = URL(fileURLWithPath: path)
        
        do {
            var values = URLResourceValues()
            values.quarantineProperties = nil
            try url.setResourceValues(values)
            print("[BinaryManager]   ✓ Quarantine removed (native Swift)")
        } catch {
            print("[BinaryManager]   ! Quarantine removal skipped: \(error.localizedDescription)")
        }
    }
    
    func getBinaryPath(for name: String) -> String {
        if name.isEmpty { return appSupportBinPath }
        return (appSupportBinPath as NSString).appendingPathComponent(name.lowercased())
    }
}