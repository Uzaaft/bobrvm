import Combine
import Foundation
import SwiftUI
import Virtualization

public enum GuestSystem: String, Codable, CaseIterable {
  case linux
  case macOS

  public var displayName: String {
    switch self {
    case .linux: return "Linux"
    case .macOS: return "macOS"
    }
  }
}

public struct MacOSPlatformMetadata: Codable, Equatable {
  let hardwareModel: String
  let machineIdentifier: String
  let auxiliaryStoragePath: String
  let macAddress: String
}

enum MacVirtualMachineError: LocalizedError {
  case appleSiliconRequired
  case invalidRestoreImage
  case unsupportedRestoreImage
  case invalidHardwareModel
  case invalidMachineIdentifier
  case invalidMACAddress
  case missingPlatformMetadata

  var errorDescription: String? {
    switch self {
    case .appleSiliconRequired:
      return "macOS guests require an Apple silicon Mac."
    case .invalidRestoreImage:
      return "The selected file is not a valid macOS restore image."
    case .unsupportedRestoreImage:
      return "This Mac cannot install the selected macOS restore image."
    case .invalidHardwareModel:
      return "The saved virtual Mac hardware model is invalid or unsupported."
    case .invalidMachineIdentifier:
      return "The saved virtual Mac machine identifier is invalid."
    case .invalidMACAddress:
      return "The saved virtual Mac network address is invalid."
    case .missingPlatformMetadata:
      return "The virtual Mac is missing its platform identity."
    }
  }
}

@MainActor
final class MacVirtualMachine: ObservableObject {
  @Published private(set) var state: VMState = .stopped
  @Published private(set) var lastError: Error?

  private(set) var displayView: NSView?
  private let config: VMConfig
  private let metadata: MacOSPlatformMetadata
  private let retinaEnabled: Bool
  private var runtime: MacVM?
  private var stateCancellable: AnyCancellable?

  init(config: VMConfig, metadata: MacOSPlatformMetadata, retinaEnabled: Bool) {
    self.config = config
    self.metadata = metadata
    self.retinaEnabled = retinaEnabled
  }

  func start() throws {
    guard state == .stopped else { return }
    guard let diskPath = config.diskPath else { throw BobrvmError.invalidArgument }
    let runtime = try MacVM(
      config: MacVMConfig(
        memoryBytes: config.memoryBytes,
        vcpuCount: config.vcpuCount,
        displayWidth: config.displayWidth,
        displayHeight: config.displayHeight,
        retinaEnabled: retinaEnabled,
        diskPath: diskPath,
        auxiliaryStoragePath: metadata.auxiliaryStoragePath,
        hardwareModel: metadata.hardwareModel,
        machineIdentifier: metadata.machineIdentifier,
        macAddress: metadata.macAddress
      )
    )
    self.runtime = runtime
    displayView = runtime.displayView
    stateCancellable = runtime.$state.sink { [weak self] state in
      self?.state = state
    }
    lastError = nil
    try runtime.start()
  }

  func stop() {
    runtime?.stop()
  }

  func pause() {
    runtime?.pause()
  }

  func resume() {
    runtime?.resume()
  }

  func destroy() {
    runtime?.destroy()
    runtime = nil
    displayView = nil
    stateCancellable = nil
  }
}

@MainActor
enum MacOSRestoreService {
  struct Result {
    let config: VMConfig
    let metadata: MacOSPlatformMetadata
  }

  static func install(
    ipswURL: URL?,
    diskURL: URL,
    auxiliaryStorageURL: URL,
    memoryBytes: UInt64,
    vcpuCount: UInt8,
    displayWidth: UInt32,
    displayHeight: UInt32,
    retinaEnabled: Bool,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> Result {
    #if !arch(arm64)
      throw MacVirtualMachineError.appleSiliconRequired
    #else
      let restoreURL = try await resolveRestoreImage(
        selectedURL: ipswURL,
        progress: progress
      )
      let image = try await loadRestoreImage(from: restoreURL)
      guard let requirements = image.mostFeaturefulSupportedConfiguration else {
        throw MacVirtualMachineError.unsupportedRestoreImage
      }

      let machineIdentifier = VZMacMachineIdentifier()
      let macAddress = VZMACAddress.randomLocallyAdministered()
      _ = try VZMacAuxiliaryStorage(
        creatingStorageAt: auxiliaryStorageURL,
        hardwareModel: requirements.hardwareModel
      )

      let config = VMConfig(
        memoryBytes: max(memoryBytes, requirements.minimumSupportedMemorySize),
        vcpuCount: UInt8(
          min(
            255,
            max(Int(vcpuCount), requirements.minimumSupportedCPUCount)
          )
        ),
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        gpuMemoryBytes: 0,
        networkEnabled: true,
        diskPath: diskURL.path,
        diskReadOnly: false
      )
      let metadata = MacOSPlatformMetadata(
        hardwareModel: requirements.hardwareModel.dataRepresentation.base64EncodedString(),
        machineIdentifier: machineIdentifier.dataRepresentation.base64EncodedString(),
        auxiliaryStoragePath: auxiliaryStorageURL.path,
        macAddress: macAddress.string
      )
      let runtime = try MacVM(
        config: MacVMConfig(
          memoryBytes: config.memoryBytes,
          vcpuCount: config.vcpuCount,
          displayWidth: config.displayWidth,
          displayHeight: config.displayHeight,
          retinaEnabled: retinaEnabled,
          diskPath: diskURL.path,
          auxiliaryStoragePath: metadata.auxiliaryStoragePath,
          hardwareModel: metadata.hardwareModel,
          machineIdentifier: metadata.machineIdentifier,
          macAddress: metadata.macAddress
        )
      )
      try await runtime.install(restorePath: restoreURL.path) { fraction in
        progress(0.70 + fraction * 0.30)
      }
      progress(1)
      return Result(config: config, metadata: metadata)
    #endif
  }

  #if arch(arm64)
    private static func resolveRestoreImage(
      selectedURL: URL?,
      progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
      if let selectedURL {
        progress(0.70)
        return selectedURL.resolvingSymlinksInPath()
      }

      progress(0.01)
      let latest = try await withCheckedThrowingContinuation { continuation in
        VZMacOSRestoreImage.fetchLatestSupported { result in
          continuation.resume(with: result)
        }
      }
      progress(0.03)

      let cache = DiskManager.appSupportDir
        .appendingPathComponent("RestoreImages", isDirectory: true)
      try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
      let destination = cache.appendingPathComponent(latest.url.lastPathComponent)
      if FileManager.default.fileExists(atPath: destination.path) {
        progress(0.70)
        return destination
      }

      return try await RestoreImageDownloader.download(
        from: latest.url,
        to: destination,
        progress: progress
      )
    }

    private static func loadRestoreImage(from url: URL) async throws -> VZMacOSRestoreImage {
      try await withCheckedThrowingContinuation { continuation in
        VZMacOSRestoreImage.load(from: url) { result in
          continuation.resume(with: result)
        }
      }
    }
  #endif
}

private final class RestoreImageDownloader: NSObject, URLSessionDownloadDelegate {
  private let destination: URL
  private let progress: @MainActor (Double) -> Void
  private var continuation: CheckedContinuation<URL, Error>?
  private var session: URLSession?
  private var finished = false
  private var progressTimeNsLast: UInt64 = 0

  private static let progressIntervalNs: UInt64 = 100_000_000

  private init(destination: URL, progress: @escaping @MainActor (Double) -> Void) {
    self.destination = destination
    self.progress = progress
  }

  static func download(
    from source: URL,
    to destination: URL,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> URL {
    let downloader = RestoreImageDownloader(destination: destination, progress: progress)
    return try await downloader.start(source: source)
  }

  private func start(source: URL) async throws -> URL {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(
          configuration: configuration,
          delegate: self,
          delegateQueue: queue
        )
        self.session = session
        session.downloadTask(with: source).resume()
      }
    } onCancel: {
      self.session?.invalidateAndCancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    let timeNs = DispatchTime.now().uptimeNanoseconds
    let intervalElapsed = timeNs &- progressTimeNsLast >= Self.progressIntervalNs
    guard fraction >= 1 || intervalElapsed else { return }

    progressTimeNsLast = timeNs
    Task { @MainActor in
      progress(0.03 + fraction * 0.67)
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      try FileManager.default.moveItem(at: location, to: destination)
      finish(.success(destination))
    } catch {
      finish(.failure(error))
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      finish(.failure(error))
    }
  }

  private func finish(_ result: Result<URL, Error>) {
    guard !finished else { return }
    finished = true
    session?.finishTasksAndInvalidate()
    session = nil
    continuation?.resume(with: result)
    continuation = nil
  }
}

struct MacVirtualMachineView: NSViewRepresentable {
  @ObservedObject var machine: MacVirtualMachine

  func makeNSView(context: Context) -> NSView {
    machine.displayView ?? NSView()
  }

  func updateNSView(_ view: NSView, context: Context) {}
}
