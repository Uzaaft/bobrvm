import Foundation
import SwiftUI
import WebKit

struct WindowsMediaDownloadView: View {
    @Environment(\.dismiss) private var dismiss

    let onDownloaded: (URL) -> Void

    @State private var downloadProgress: Double?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            WindowsMediaWebView(
                onDownloadStarted: {
                    errorMessage = nil
                    downloadProgress = 0
                },
                onDownloadProgress: { downloadProgress = $0 },
                onDownloaded: { url in
                    onDownloaded(url)
                    dismiss()
                },
                onFailed: { error in
                    downloadProgress = nil
                    errorMessage = error.localizedDescription
                }
            )
            Divider()
            HStack(spacing: 12) {
                if let downloadProgress {
                    ProgressView(value: downloadProgress)
                        .frame(width: 180)
                    Text("Downloading… \(Int(downloadProgress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select an edition and language, then choose the Arm64 download.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 900, minHeight: 680)
        .alert(
            "Couldn’t Download Windows",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }
}

private struct WindowsMediaWebView: NSViewRepresentable {
    let onDownloadStarted: () -> Void
    let onDownloadProgress: (Double) -> Void
    let onDownloaded: (URL) -> Void
    let onFailed: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onDownloadStarted: onDownloadStarted,
            onDownloadProgress: onDownloadProgress,
            onDownloaded: onDownloaded,
            onFailed: onFailed
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: Self.microsoftDownloadURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    private static let microsoftDownloadURL = URL(
        string: "https://www.microsoft.com/software-download/windows11arm64"
    )!

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private struct DownloadState {
            let destination: URL
            let observation: NSKeyValueObservation
        }

        private let onDownloadStarted: () -> Void
        private let onDownloadProgress: (Double) -> Void
        private let onDownloaded: (URL) -> Void
        private let onFailed: (Error) -> Void
        private var downloads: [ObjectIdentifier: DownloadState] = [:]

        init(
            onDownloadStarted: @escaping () -> Void,
            onDownloadProgress: @escaping (Double) -> Void,
            onDownloaded: @escaping (URL) -> Void,
            onFailed: @escaping (Error) -> Void
        ) {
            self.onDownloadStarted = onDownloadStarted
            self.onDownloadProgress = onDownloadProgress
            self.onDownloaded = onDownloaded
            self.onFailed = onFailed
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            let policy: WKNavigationActionPolicy = navigationAction.shouldPerformDownload
                ? .download
                : .allow
            decisionHandler(policy, preferences)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let filename = navigationResponse.response.suggestedFilename ?? ""
            decisionHandler(filename.lowercased().hasSuffix(".iso") ? .download : .allow)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let request = navigationAction.request.url {
                webView.load(URLRequest(url: request))
            }
            return nil
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            do {
                let destination = try Self.downloadDestination(
                    response: response,
                    suggestedFilename: suggestedFilename
                )
                let observation = download.progress.observe(
                    \.fractionCompleted,
                    options: [.initial, .new]
                ) { [weak self] progress, _ in
                    DispatchQueue.main.async {
                        self?.onDownloadProgress(progress.fractionCompleted)
                    }
                }
                downloads[ObjectIdentifier(download)] = DownloadState(
                    destination: destination,
                    observation: observation
                )
                onDownloadStarted()
                completionHandler(destination)
            } catch {
                onFailed(error)
                completionHandler(nil)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            let id = ObjectIdentifier(download)
            guard let state = downloads.removeValue(forKey: id) else { return }
            onDownloadProgress(1)
            onDownloaded(state.destination)
        }

        func download(
            _ download: WKDownload,
            didFailWithError error: Error,
            resumeData: Data?
        ) {
            downloads.removeValue(forKey: ObjectIdentifier(download))
            onFailed(error)
        }

        private static func downloadDestination(
            response: URLResponse,
            suggestedFilename: String
        ) throws -> URL {
            guard let host = response.url?.host?.lowercased(), isMicrosoftHost(host) else {
                throw WindowsMediaDownloadError.untrustedDownload
            }

            let filename = URL(fileURLWithPath: suggestedFilename).lastPathComponent
            guard URL(fileURLWithPath: filename).pathExtension.lowercased() == "iso" else {
                throw WindowsMediaDownloadError.unsupportedFile
            }

            let directory = DiskManager.appSupportDir
                .appendingPathComponent("InstallationMedia", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let preferred = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: preferred.path) else {
                return preferred
            }

            let base = preferred.deletingPathExtension().lastPathComponent
            let suffix = UUID().uuidString.prefix(8)
            return directory.appendingPathComponent("\(base)-\(suffix).iso")
        }

        private static func isMicrosoftHost(_ host: String) -> Bool {
            host == "microsoft.com" || host.hasSuffix(".microsoft.com")
        }
    }
}

private enum WindowsMediaDownloadError: LocalizedError {
    case untrustedDownload
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .untrustedDownload:
            return "The download did not come from an official Microsoft server."
        case .unsupportedFile:
            return "Microsoft did not provide a Windows ISO image."
        }
    }
}
