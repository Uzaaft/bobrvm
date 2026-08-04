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

enum MacOSVirtualMachineFactory {
  static func configuration(
    config: VMConfig,
    metadata: MacOSPlatformMetadata,
    retinaEnabled: Bool
  ) throws -> VZVirtualMachineConfiguration {
    #if !arch(arm64)
      throw MacVirtualMachineError.appleSiliconRequired
    #else
      guard let hardwareData = Data(base64Encoded: metadata.hardwareModel),
        let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData),
        hardwareModel.isSupported
      else {
        throw MacVirtualMachineError.invalidHardwareModel
      }
      guard let identifierData = Data(base64Encoded: metadata.machineIdentifier),
        let machineIdentifier = VZMacMachineIdentifier(
          dataRepresentation: identifierData
        )
      else {
        throw MacVirtualMachineError.invalidMachineIdentifier
      }
      guard let macAddress = VZMACAddress(string: metadata.macAddress) else {
        throw MacVirtualMachineError.invalidMACAddress
      }
      guard let diskPath = config.diskPath else {
        throw BobrvmError.invalidArgument
      }

      let platform = VZMacPlatformConfiguration()
      platform.hardwareModel = hardwareModel
      platform.machineIdentifier = machineIdentifier
      platform.auxiliaryStorage = VZMacAuxiliaryStorage(
        url: URL(fileURLWithPath: metadata.auxiliaryStoragePath)
      )

      let result = VZVirtualMachineConfiguration()
      result.bootLoader = VZMacOSBootLoader()
      result.platform = platform
      result.cpuCount = min(
        max(Int(config.vcpuCount), VZVirtualMachineConfiguration.minimumAllowedCPUCount),
        VZVirtualMachineConfiguration.maximumAllowedCPUCount
      )
      result.memorySize = min(
        max(config.memoryBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
        VZVirtualMachineConfiguration.maximumAllowedMemorySize
      )
      result.storageDevices = [
        try storageDevice(path: diskPath)
      ]
      result.graphicsDevices = [graphicsDevice(config: config, retinaEnabled: retinaEnabled)]
      result.keyboards = keyboardDevices()
      result.pointingDevices = pointingDevices()
      result.networkDevices = [networkDevice(macAddress: macAddress)]
      result.audioDevices = [audioDevice()]
      result.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

      try result.validate()
      return result
    #endif
  }

  #if arch(arm64)
    private static func storageDevice(path: String) throws -> VZStorageDeviceConfiguration {
      let attachment = try VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: path),
        readOnly: false,
        cachingMode: .automatic,
        synchronizationMode: .full
      )
      return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }

    private static func graphicsDevice(
      config: VMConfig,
      retinaEnabled: Bool
    ) -> VZGraphicsDeviceConfiguration {
      let graphics = VZMacGraphicsDeviceConfiguration()
      graphics.displays = [
        VZMacGraphicsDisplayConfiguration(
          widthInPixels: Int(config.displayWidth),
          heightInPixels: Int(config.displayHeight),
          pixelsPerInch: retinaEnabled ? 144 : 80
        )
      ]
      return graphics
    }

    private static func keyboardDevices() -> [VZKeyboardConfiguration] {
      if #available(macOS 14, *) {
        return [VZUSBKeyboardConfiguration(), VZMacKeyboardConfiguration()]
      }
      return [VZUSBKeyboardConfiguration()]
    }

    private static func pointingDevices() -> [VZPointingDeviceConfiguration] {
      [
        VZUSBScreenCoordinatePointingDeviceConfiguration(),
        VZMacTrackpadConfiguration(),
      ]
    }

    private static func networkDevice(macAddress: VZMACAddress) -> VZNetworkDeviceConfiguration {
      let network = VZVirtioNetworkDeviceConfiguration()
      network.attachment = VZNATNetworkDeviceAttachment()
      network.macAddress = macAddress
      return network
    }

    private static func audioDevice() -> VZAudioDeviceConfiguration {
      let sound = VZVirtioSoundDeviceConfiguration()
      let input = VZVirtioSoundDeviceInputStreamConfiguration()
      input.source = VZHostAudioInputStreamSource()
      let output = VZVirtioSoundDeviceOutputStreamConfiguration()
      output.sink = VZHostAudioOutputStreamSink()
      sound.streams = [input, output]
      return sound
    }
  #endif
}

final class MacVirtualMachine: NSObject, ObservableObject, VZVirtualMachineDelegate {
  @Published private(set) var state: VMState = .stopped
  @Published private(set) var lastError: Error?

  private(set) var virtualMachine: VZVirtualMachine?
  private let config: VMConfig
  private let metadata: MacOSPlatformMetadata
  private let retinaEnabled: Bool

  init(config: VMConfig, metadata: MacOSPlatformMetadata, retinaEnabled: Bool) {
    self.config = config
    self.metadata = metadata
    self.retinaEnabled = retinaEnabled
  }

  @MainActor
  func start() throws {
    guard state == .stopped else { return }
    let configuration = try MacOSVirtualMachineFactory.configuration(
      config: config,
      metadata: metadata,
      retinaEnabled: retinaEnabled
    )
    let machine = VZVirtualMachine(configuration: configuration)
    machine.delegate = self
    virtualMachine = machine
    state = .running
    lastError = nil

    machine.start { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        if case .failure(let error) = result {
          self.lastError = error
          self.state = .stopped
          self.virtualMachine = nil
        }
      }
    }
  }

  @MainActor
  func stop() {
    guard let machine = virtualMachine else { return }
    Task { @MainActor [weak self] in
      do {
        try await machine.stop()
        self?.state = .stopped
        self?.virtualMachine = nil
      } catch {
        self?.lastError = error
      }
    }
  }

  @MainActor
  func pause() {
    guard let machine = virtualMachine, state == .running else { return }
    Task { @MainActor [weak self] in
      do {
        try await machine.pause()
        self?.state = .paused
      } catch {
        self?.lastError = error
      }
    }
  }

  @MainActor
  func resume() {
    guard let machine = virtualMachine, state == .paused else { return }
    Task { @MainActor [weak self] in
      do {
        try await machine.resume()
        self?.state = .running
      } catch {
        self?.lastError = error
      }
    }
  }

  @MainActor
  func destroy() {
    stop()
    virtualMachine = nil
  }

  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    DispatchQueue.main.async { [weak self] in
      self?.state = .stopped
      self?.virtualMachine = nil
    }
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    DispatchQueue.main.async { [weak self] in
      self?.lastError = error
      self?.state = .stopped
      self?.virtualMachine = nil
    }
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
      let configuration = try MacOSVirtualMachineFactory.configuration(
        config: config,
        metadata: metadata,
        retinaEnabled: retinaEnabled
      )
      let machine = VZVirtualMachine(configuration: configuration)
      let installer = VZMacOSInstaller(
        virtualMachine: machine,
        restoringFromImageAt: restoreURL
      )
      let observation = installer.progress.observe(\.fractionCompleted) { observed, _ in
        Task { @MainActor in
          progress(0.70 + observed.fractionCompleted * 0.30)
        }
      }
      defer { observation.invalidate() }

      try await withCheckedThrowingContinuation { continuation in
        installer.install { result in continuation.resume(with: result) }
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

  func makeNSView(context: Context) -> VZVirtualMachineView {
    let view = VZVirtualMachineView()
    view.capturesSystemKeys = true
    if #available(macOS 14, *) {
      view.automaticallyReconfiguresDisplay = true
    }
    view.virtualMachine = machine.virtualMachine
    return view
  }

  func updateNSView(_ view: VZVirtualMachineView, context: Context) {
    view.virtualMachine = machine.virtualMachine
  }
}
