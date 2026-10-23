import Foundation

/// Injectable boundary; all filesystem work runs on the service's private queue.
public protocol FilesFileSystem: Sendable {
  func coordinated<T>(_ roots: [URL], writing: Bool, metadataOnly: Bool, _ body: () throws -> T)
    throws -> T
  func cloudStatus(_ url: URL) throws -> FilesCloudStatus
  func requestDownload(_ url: URL) throws
  func trash(_ url: URL) throws
  func validateCloudRoot(_ url: URL) throws
}
public struct FoundationFilesFileSystem: FilesFileSystem {
  public init() {}
  public func validateCloudRoot(_ url: URL) throws {
    guard try url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true else {
      throw FilesError("root_not_available_in_icloud")
    }
  }
  public func requestDownload(_ url: URL) throws {
    try FileManager.default.startDownloadingUbiquitousItem(at: url)
  }
  public func trash(_ url: URL) throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  }
  public func coordinated<T>(
    _ roots: [URL], writing: Bool, metadataOnly: Bool, _ body: () throws -> T
  ) throws -> T {
    // The caller waits on its private utility queue. Clear the captured work before
    // signaling: NSFileCoordinator may retain its completion closure after returning.
    return try withoutActuallyEscaping(body) { body in
      let work = CoordinationWork(body)
      let coordinator = NSFileCoordinator()
      let readingOptions: NSFileCoordinator.ReadingOptions =
        metadataOnly
        ? [.withoutChanges, .immediatelyAvailableMetadataOnly] : [.withoutChanges]
      let intents = roots.map {
        writing
          ? NSFileAccessIntent.writingIntent(with: $0, options: .forMerging)
          : NSFileAccessIntent.readingIntent(with: $0, options: readingOptions)
      }
      let queue = OperationQueue()
      queue.maxConcurrentOperationCount = 1
      let box = CoordinationResult<T>()
      let done = DispatchSemaphore(value: 0)
      coordinator.coordinate(with: intents, queue: queue) { error in
        defer {
          work.body = nil
          done.signal()
        }
        if error != nil {
          box.result = .failure(FilesError("coordination_failed"))
          return
        }
        box.result = Result { try work.body!() }
      }
      done.wait()
      return try box.result!.get()
    }
  }
}
private final class CoordinationResult<T>: @unchecked Sendable { var result: Result<T, Error>? }

private final class CoordinationWork<T>: @unchecked Sendable {
  var body: (() throws -> T)?
  init(_ body: @escaping () throws -> T) { self.body = body }
}

public struct FilesCloudStatus: Sendable {
  public let ubiquitous: Bool?
  public let downloading: String?
  public let uploading: Bool?
  public let uploaded: Bool?
  public let conflicts: Bool?
  public init(
    ubiquitous: Bool? = nil, downloading: String? = nil,
    uploading: Bool? = nil, uploaded: Bool? = nil, conflicts: Bool? = nil
  ) {
    self.ubiquitous = ubiquitous
    self.downloading = downloading
    self.uploading = uploading
    self.uploaded = uploaded
    self.conflicts = conflicts
  }
  var locallyAvailable: Bool {
    ubiquitous != true || downloading == URLUbiquitousItemDownloadingStatus.current.rawValue
      || downloading == URLUbiquitousItemDownloadingStatus.downloaded.rawValue
  }
}
extension FilesFileSystem {
  public func coordinated<T>(_ roots: [URL], writing: Bool, _ body: () throws -> T) throws -> T {
    try coordinated(roots, writing: writing, metadataOnly: false, body)
  }

  public func cloudStatus(_ url: URL) throws -> FilesCloudStatus {
    let v = try url.resourceValues(forKeys: [
      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
      .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey,
      .ubiquitousItemHasUnresolvedConflictsKey,
    ])
    return .init(
      ubiquitous: v.isUbiquitousItem, downloading: v.ubiquitousItemDownloadingStatus?.rawValue,
      uploading: v.ubiquitousItemIsUploading, uploaded: v.ubiquitousItemIsUploaded,
      conflicts: v.ubiquitousItemHasUnresolvedConflicts)
  }
}
