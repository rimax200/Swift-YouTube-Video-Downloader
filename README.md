# 🚀 RXDownloader

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg?style=flat-square)](https://developer.apple.com/swift/)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013.0+-blue.svg?style=flat-square)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=flat-square)](LICENSE)

**RXDownloader** is a high-performance, premium macOS utility designed for seamless media acquisition. Built with **SwiftUI** and powered by the industry-standard `yt-dlp` and `ffmpeg` engines, it bridges the gap between powerful CLI functionality and a refined, native user experience.

---

## ✨ Key Features

-   **High-Fidelity UI**: A modern, "Raycast-inspired" interface with deep dark mode support and vibrant aesthetics.
-   **Preview-First Workflow**: Instant metadata fetching provides titles, thumbnails, and durations before you commit to a download.
-   **Advanced Format Selection**: Granular control over video quality, audio-only extraction (MP3), and thumbnail acquisition.
-   **Real-time Progress**: Detailed tracking of download percentages and post-processing (merging/conversion) states.
-   **Custom Persistence**: User-definable download locations with full `NSOpenPanel` integration.

---

## 🛠 Engineering Excellence

Unlike simple wrappers, RXDownloader implements several sophisticated engineering patterns to ensure reliability and performance:

### 1. Two-Phase Metadata Fetching
To eliminate the latency inherent in parsing complex JSON formats, we use a custom parsing engine:
-   **Fast Path**: Extracts essential UI data (Title/Thumbnail) in `< 500ms`.
-   **Lazy Loading**: Fetches detailed format specifications in the background to keep the UI responsive.

### 2. Sandbox Optimized Binary Management
Running CLI binaries like `yt-dlp` within the macOS App Sandbox is notoriously difficult. RXDownloader solves this through:
-   **Binary Persistence**: Automatic deployment of bundled binaries to the `Application Support` container.
-   **POSIX Permission Management**: Programmatic verification and enforcement of `0o755` execution bits.
-   **Environment Shimming**: Custom `PATH` and `HOME` injection to bypass sandbox search latencies.

### 3. Asynchronous Process Pipeline
The app leverages a robust `Process` management system using `Pipe` for real-time output parsing, ensuring that terminal logs are translated into smooth SwiftUI animations without blocking the main thread.

---

## 🏗 Tech Stack

-   **Language**: Swift 5.9
-   **Framework**: SwiftUI + Combine
-   **Engines**: 
    -   [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) (Core downloader)
    -   [`ffmpeg`](https://ffmpeg.org/) (Media muxing & processing)
-   **Architecture**: MVVM (Model-View-ViewModel) with a centralized `BinaryManager` singleton.

---

## 🚀 Getting Started

### Prerequisites
-   macOS 13.0 or later
-   Xcode 15.0+ (for building from source)

### Build Instructions
1.  Clone the repository:
    ```bash
    git clone https://github.com/yourusername/RXDownloader.git
    ```
2.  Open `RXDownloader.xcodeproj` in Xcode.
3.  Ensure the binaries in the `Binaries/` folder have target membership checked for the main app.
4.  Build and Run (`⌘R`).

---

## 🤝 Contributing

Contributions are what make the open-source community an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

---

<p align="center">
  Developed with ❤️ for the macOS Community
</p>
