import SwiftUI

struct ContentView: View {
    @StateObject private var manager = DownloadManager()
    @State private var url: String = ""
    @State private var selectedType: DownloadType = .video
    @State private var selectedFormat: String = ""
    
    var body: some View {
        ZStack {
            // Background
            Color(hex: "07080a").ignoresSafeArea()
            
            VStack(spacing: 16) {
                // Search Bar
                HStack(spacing: 10) {
                    RaycastTextField(text: $url, placeholder: "Paste YouTube URL...")
                    
                    Button(action: { manager.fetchVideoDetails(url: url) }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.06))
                                .frame(width: 34, height: 34)
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(url.isEmpty || manager.status == .fetching || manager.status == .fetchingFormats)
                    .opacity(url.isEmpty || manager.status == .fetching || manager.status == .fetchingFormats ? 0.3 : 1.0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                
                if manager.status == .fetching {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .colorInvert()
                        Text("Fetching details...")
                            .raycastFont(size: 12, color: .white.opacity(0.3))
                    }
                    .frame(maxHeight: .infinity)
                } else if let metadata = manager.currentMetadata {
                    // PREVIEW CARD
                    VStack(spacing: 0) {
                        // 1. Header (Thumbnail + Title)
                        HStack(spacing: 12) {
                            CachedAsyncImage(url: URL(string: metadata.thumbnail)) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else if phase.error != nil {
                                    Color.white.opacity(0.05)
                                } else {
                                    ProgressView().scaleEffect(0.5).colorInvert()
                                }
                            }
                            .frame(width: 100, height: 60)
                            .cornerRadius(8)
                            .clipped()
                            
                            Text(metadata.title)
                                .raycastFont(size: 14, color: Color(hex: "f9f9f9"), weight: .semibold)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        
                        Divider().background(Color.white.opacity(0.05))
                        
                        // 2. Type Toggle
                        HStack(spacing: 12) {
                            ForEach(DownloadType.allCases) { type in
                                Button(action: { 
                                    selectedType = type 
                                    selectedFormat = "" // Reset
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: type.icon).font(.system(size: 10))
                                        Text(type.rawValue).raycastFont(size: 12)
                                    }
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(selectedType == type ? Color.white.opacity(0.1) : Color.clear)
                                    .cornerRadius(6)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .foregroundColor(selectedType == type ? .white : .white.opacity(0.4))
                            }
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.2))
                        
                        // 3. Format List / Picker (Custom ScrollView for Obsidian Aesthetic)
                        ScrollView {
                            VStack(spacing: 0) {
                                if selectedType == .thumbnail {
                                    FormatRow(
                                        title: "High Resolution Image",
                                        secondary: "Best Quality .jpg",
                                        isSelected: true,
                                        onTap: {}
                                    )
                                } else if manager.status == .fetchingFormats {
                                    // Lazy-path still running — show inline spinner
                                    VStack(spacing: 8) {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                            .colorInvert()
                                        Text("Loading qualities...")
                                            .raycastFont(size: 11, color: .white.opacity(0.3))
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .padding(.vertical, 20)
                                } else {
                                    let formats = selectedType == .video ? metadata.videoFormats : metadata.audioFormats
                                    
                                    if formats.isEmpty {
                                        VStack(spacing: 6) {
                                            Image(systemName: "tray")
                                                .font(.system(size: 16))
                                                .foregroundColor(.white.opacity(0.1))
                                            Text("No formats available")
                                                .raycastFont(size: 11, color: .white.opacity(0.2))
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .padding(.vertical, 20)
                                    } else {
                                        ForEach(formats) { format in
                                            FormatRow(
                                                title: format.formatNote ?? format.resolution ?? "Standard",
                                                secondary: format.sizeString,
                                                isSelected: selectedFormat == format.id,
                                                onTap: { selectedFormat = format.id }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .frame(height: 140)
                        .background(Color.black.opacity(0.1))
                        
                        Divider().background(Color.white.opacity(0.05))
                        
                        // 4. Footer (Location + Download)
                        HStack {
                            RaycastSecondaryButton(
                                title: manager.downloadLocation.lastPathComponent,
                                icon: "folder.fill",
                                action: { manager.selectFolder() }
                            )
                            
                            Spacer()
                            
                            Button(action: { manager.startDownload(url: url, type: selectedType, formatID: selectedFormat.isEmpty ? nil : selectedFormat) }) {
                                Text(manager.isDownloading ? "..." : "Download")
                                    .raycastFont(size: 12, color: Color(hex: "07080a"), weight: .bold)
                                    .frame(width: 90, height: 28)
                                    .background(Capsule().fill(Color.white))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(manager.isDownloading || manager.status == .fetchingFormats || (selectedFormat.isEmpty && selectedType != .thumbnail))
                            .opacity(manager.isDownloading ? 0.5 : 1.0)
                        }
                        .padding(12)
                    }
                    .background(Color(hex: "101111"))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                } else if case .failed(let error) = manager.status {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundColor(.red.opacity(0.6))
                        Text(error).raycastFont(size: 11, color: .red.opacity(0.6)).multilineTextAlignment(.center)
                    }
                    .padding(40)
                    .frame(maxHeight: .infinity)
                } else {
                    // Empty state
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.05))
                        Text("Ready for your next download")
                            .raycastFont(size: 12, color: .white.opacity(0.2))
                        
                        updaterView
                    }
                    .frame(maxHeight: .infinity)
                }
                
                // Progress
                if manager.isDownloading || manager.status == .completed {
                    VStack(spacing: 10) {
                        if manager.isDownloading {
                            RaycastProgressBar(progress: manager.progress)
                        }
                        HStack {
                            statusLabel
                            Spacer()
                            if manager.status == .completed {
                                RaycastSecondaryButton(title: "Open Folder") {
                                    NSWorkspace.shared.open(manager.downloadLocation)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                
                Spacer(minLength: 0)
            }
        }
        .frame(width: 480, height: 500)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: manager.status)
    }
    
    private var statusLabel: some View {
        Group {
            switch manager.status {
            case .downloading(let p):
                Text("Downloading... \(Int(p * 100))%")
            case .processing:
                Text("Processing media...")
            case .completed:
                Text("Success!").foregroundColor(Color(hex: "5fc992"))
            default:
                EmptyView()
            }
        }
        .raycastFont(size: 11, color: .white.opacity(0.5))
    }
    
    private var updaterView: some View {
        VStack(spacing: 8) {
            RaycastSecondaryButton(
                title: manager.updater.status == .idle ? "Update Engine" : "Working...",
                icon: "arrow.clockwise",
                action: { manager.updater.checkForUpdates() }
            )
            .disabled(manager.updater.status != .idle)
            .opacity(manager.updater.status == .idle ? 1.0 : 0.5)
            
            switch manager.updater.status {
            case .checking:
                Text("Checking GitHub...").raycastFont(size: 10, color: .white.opacity(0.4))
            case .downloading(let progress):
                Text("Downloading: \(Int(progress * 100))%").raycastFont(size: 10, color: .white.opacity(0.4))
            case .success(let msg):
                Text(msg).raycastFont(size: 10, color: Color(hex: "5fc992").opacity(0.8))
            case .error(let err):
                Text(err).raycastFont(size: 10, color: .red.opacity(0.6))
            default:
                EmptyView()
            }
        }
        .padding(.top, 10)
    }
}

struct FormatRow: View {
    let title: String
    let secondary: String
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            // Selection Indicator
            Rectangle()
                .fill(isSelected ? Color(hex: "5fc992") : Color.clear)
                .frame(width: 2)
                .padding(.vertical, 8)
            
            HStack {
                Text(title)
                    .raycastFont(size: 13, color: Color(hex: "f9f9f9").opacity(0.9), weight: isSelected ? .semibold : .regular)
                
                Spacer()
                
                Text(secondary)
                    .raycastFont(size: 11, color: Color(hex: "c0c0c0").opacity(0.5))
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 38)
        .background(isSelected ? Color.white.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Component Additions
struct RaycastSecondaryButton: View {
    var title: String
    var icon: String? = nil
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let ic = icon {
                    Image(systemName: ic).font(.system(size: 10))
                }
                Text(title)
                    .raycastFont(size: 11, color: .white.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Reusable Styles
struct RaycastTextField: View {
    @Binding var text: String
    var placeholder: String
    
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(PlainTextFieldStyle())
            .raycastFont(size: 13)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
            .overlay(
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .raycastFont(size: 13, color: .white.opacity(0.15))
                            .padding(.leading, 14)
                            .allowsHitTesting(false)
                    }
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                }
            )
    }
}

struct RaycastProgressBar: View {
    var progress: Double
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.04))
                Capsule()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: geo.size.width * CGFloat(progress))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Extensions
extension View {
    func raycastFont(size: CGFloat, color: Color = .white, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .rounded))
            .foregroundColor(color)
            .tracking(0.2)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

private let imageCache = NSCache<NSString, NSImage>()

// MARK: - CachedAsyncImage (prevents thumbnail flickering on redraw)
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let content: (AsyncImagePhase) -> Content
    
    @State private var phase: AsyncImagePhase = .empty
    
    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }
    
    var body: some View {
        content(phase)
            .onAppear { loadImage() }
            .onChange(of: url?.absoluteString) { _ in loadImage() }
    }
    
    private func loadImage() {
        guard let url = url else {
            phase = .empty
            return
        }
        
        let key = url.absoluteString as NSString
        
        // Check cache first
        if let cached = imageCache.object(forKey: key) {
            phase = .success(Image(nsImage: cached))
            return
        }
        
        // Fetch from network
        phase = .empty
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.phase = .failure(error)
                    return
                }
                guard let data = data, let nsImage = NSImage(data: data) else {
                    self.phase = .failure(URLError(.badServerResponse))
                    return
                }
                imageCache.setObject(nsImage, forKey: key)
                self.phase = .success(Image(nsImage: nsImage))
            }
        }.resume()
    }
}
