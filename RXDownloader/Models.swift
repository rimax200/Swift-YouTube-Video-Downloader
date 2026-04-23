import Foundation

struct VideoFormat: Identifiable, Codable, Hashable {
    var id: String { formatId }
    let formatId: String
    let ext: String?
    let formatNote: String?
    let resolution: String?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let vcodec: String?
    let acodec: String?
    
    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case ext
        case formatNote = "format_note"
        case resolution
        case filesize
        case filesizeApprox = "filesize_approx"
        case vcodec
        case acodec
    }
    
    var sizeString: String {
        let size = filesize ?? filesizeApprox ?? 0
        if size == 0 { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    var displayName: String {
        let name = formatNote ?? resolution ?? "Unknown"
        let size = sizeString
        return size.isEmpty ? "\(name) (\(ext ?? ""))" : "\(name) (\(ext ?? "")) • \(size)"
    }
    
    var isAudioOnly: Bool {
        return vcodec == "none"
    }
    
    var isVideoOnly: Bool {
        return acodec == "none" && vcodec != "none"
    }
}

struct VideoMetadata: Identifiable, Codable {
    let id: String
    let title: String
    let thumbnail: String
    let duration: Double?
    var formats: [VideoFormat]
    let filesizeApprox: Int64?
    
    enum CodingKeys: String, CodingKey {
        case id, title, thumbnail, duration, formats
        case filesizeApprox = "filesize_approx"
    }
    
    /// Lightweight initializer used by the fast-path (no formats yet).
    init(id: String, title: String, thumbnail: String, duration: Double?, filesizeApprox: Int64? = nil, formats: [VideoFormat] = []) {
        self.id = id
        self.title = title
        self.thumbnail = thumbnail
        self.duration = duration
        self.filesizeApprox = filesizeApprox
        self.formats = formats
    }
    
    var videoFormats: [VideoFormat] {
        // Formats that are either combined or high-res video (yt-dlp will merge)
        formats.filter { $0.vcodec != "none" && $0.resolution != nil }
               .sorted(by: { ($0.filesize ?? 0) > ($1.filesize ?? 0) })
    }
    
    var audioFormats: [VideoFormat] {
        formats.filter { $0.vcodec == "none" && $0.acodec != "none" }
               .sorted(by: { ($0.filesize ?? 0) > ($1.filesize ?? 0) })
    }
}

enum DownloadType: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"
    case thumbnail = "Thumbnail"
    
    var id: String { self.rawValue }
    
    var icon: String {
        switch self {
        case .video: return "video.fill"
        case .audio: return "waveform"
        case .thumbnail: return "photo.fill"
        }
    }
}

enum DownloadStatus: Equatable {
    case idle
    case fetching
    case downloading(Double)
    case processing
    case completed
    case failed(String)
}
