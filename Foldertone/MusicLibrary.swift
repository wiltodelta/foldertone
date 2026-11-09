import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import OSLog
import Observation
import UniformTypeIdentifiers

struct Track: Identifiable, Codable, Equatable, Sendable {
  let id: String
  let title: String
  let artist: String
  let filename: String
  let sourceSignature: String
  let duration: Double
  var sourcePath: String? = nil
  var contentHash: String? = nil
  var album: String? = nil
  var artworkFilename: String? = nil
  var metadataVersion: Int? = nil

  var url: URL { LibraryStorage.directory.appendingPathComponent(filename) }
}

struct LibraryIndex: Codable, Equatable, Sendable {
  var tracks: [Track] = []
  var memberships: [String: [String]] = [:]
  var unassigned: [String] = []

  static func load() throws -> LibraryIndex {
    guard FileManager.default.fileExists(atPath: LibraryStorage.index.path) else {
      return LibraryIndex()
    }
    let data = try Data(contentsOf: LibraryStorage.index)
    if let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) { return index }
    let tracks = try JSONDecoder().decode([Track].self, from: data)
    return LibraryIndex(tracks: tracks, unassigned: tracks.map(\.id))
  }
}

enum LibraryStorage {
  static let metadataVersion = 1
  static var directory: URL {
    URL.applicationSupportDirectory.appendingPathComponent("Music", isDirectory: true)
  }
  static var index: URL { directory.appendingPathComponent("library.json") }
  /// Everything here can be rebuilt from originals that stay in Files, so it skips iCloud Backup.
  static func prepareDirectory() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }
  static func path(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.absoluteString
  }
}

struct Playlist: Identifiable, Equatable {
  let id: String
  let name: String
  let trackIDs: Set<String>
}

struct MusicSource: Identifiable, Equatable {
  let id: String
  let name: String
  let isFolder: Bool
}

struct SyncSource: Sendable {
  let id: String
  let url: URL?
}

struct ImportResult: Sendable {
  var tracks: [Track]
  var pending: Int
  var failures: Int
  var pendingURLs: [URL] = []
}

struct SyncResult: Sendable {
  let index: LibraryIndex
  let pending: Int
  let failures: Int
  var pendingURLs: [URL] = []
}

actor FolderImporter {
  private let log = Logger(subsystem: "app.foldertone", category: "Sync")
  private var isSynchronizing = false
  private var requestedDownloads: Set<String> = []
  func retryDownloads() { requestedDownloads.removeAll() }

  func synchronize(_ sources: [SyncSource], previous: LibraryIndex, forcePaths: Set<String> = [])
    async throws -> SyncResult
  {
    isSynchronizing = true
    defer { isSynchronizing = false }
    try LibraryStorage.prepareDirectory()
    var catalog = Dictionary(
      previous.tracks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    var memberships = previous.memberships
    var pending = 0
    var failures = 0
    var pendingURLs: [URL] = []
    for source in sources {
      try Task.checkCancellation()
      guard let url = source.url else {
        failures += 1
        continue
      }
      do {
        let result = try await scan(
          url, existing: Array(catalog.values),
          priorIDs: Set(previous.memberships[source.id] ?? []),
          forcePaths: forcePaths
        )
        memberships[source.id] = result.tracks.map(\.id)
        for track in result.tracks { catalog[track.id] = track }
        pending += result.pending
        pendingURLs += result.pendingURLs
        failures += result.failures
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // An unreadable root is not evidence that all its music was deleted.
        failures += 1
        log.error(
          "Source scan failed for \(url.path, privacy: .public): \(error, privacy: .public)")
      }
    }
    memberships = memberships.filter { entry in sources.contains { $0.id == entry.key } }
    let referenced = Set(memberships.values.flatMap { $0 })
    let unassigned = failures > 0 ? previous.unassigned.filter { !referenced.contains($0) } : []
    let retained = referenced.union(unassigned)
    let tracks = catalog.values.filter { retained.contains($0.id) }.sorted {
      let comparison = $0.title.localizedStandardCompare($1.title)
      return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
    }
    let index = LibraryIndex(tracks: tracks, memberships: memberships, unassigned: unassigned)
    try JSONEncoder().encode(index).write(to: LibraryStorage.index, options: .atomic)
    return SyncResult(index: index, pending: pending, failures: failures, pendingURLs: pendingURLs)
  }

  // A successful scan is an authoritative snapshot of this source, not an append-only import.
  func scan(
    _ folder: URL, existing: [Track], priorIDs: Set<String> = [], forcePaths: Set<String> = []
  ) async throws
    -> ImportResult
  {
    let scoped = folder.startAccessingSecurityScopedResource()
    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey,
    ]
    guard let isFolder = try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
      throw CocoaError(.fileReadUnknown)
    }
    var urls: [URL] = []
    if isFolder {
      var enumerationError: Error?
      guard
        let enumerator = manager.enumerator(
          at: folder, includingPropertiesForKeys: Array(keys), options: [],
          errorHandler: { _, error in
            enumerationError = error
            return false
          })
      else { throw CocoaError(.fileReadNoPermission) }
      while let url = enumerator.nextObject() as? URL { urls.append(url) }
      if let enumerationError { throw enumerationError }
    } else {
      urls = [folder]
    }
    urls = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
      .sorted { $0.path < $1.path }
    let currentPaths = Set(urls.map { LibraryStorage.path($0) })
    var result = ImportResult(tracks: [], pending: 0, failures: 0)
    for url in urls {
      try Task.checkCancellation()
      let path = LibraryStorage.path(url)
      let pathID = digest(Data(url.standardizedFileURL.absoluteString.utf8))
      let legacyID = digest(
        Data((folder.absoluteString + String(url.path.dropFirst(folder.path.count))).utf8))
      let old =
        existing.first { $0.sourcePath == path }
        ?? existing.first {
          $0.sourcePath == nil && ($0.id == pathID || (isFolder && $0.id == legacyID))
        }
      do {
        let values = try url.resourceValues(forKeys: keys)
        guard let isRegularFile = values.isRegularFile else { throw CocoaError(.fileReadUnknown) }
        guard isRegularFile else { continue }
        if values.isUbiquitousItem == true,
          values.ubiquitousItemDownloadingStatus != .current,
          values.ubiquitousItemDownloadingStatus != .downloaded
        {
          if let old { result.tracks.append(old) }
          result.pendingURLs.append(url)
          if requestedDownloads.contains(path), let error = values.ubiquitousItemDownloadingError {
            throw error
          }
          if requestedDownloads.insert(path).inserted {
            try manager.startDownloadingUbiquitousItem(at: url)
          }
          result.pending += 1
          continue
        }
        requestedDownloads.remove(path)
        let signature =
          "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let old, old.sourceSignature == signature, old.contentHash != nil,
          old.metadataVersion == LibraryStorage.metadataVersion, !forcePaths.contains(path),
          manager.fileExists(atPath: old.url.path)
        {
          result.tracks.append(old)
          continue
        }
        var data: Data?
        var coordinationError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
          source in
          do { data = try Data(contentsOf: source) } catch {
            readError = error
          }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let data else { throw CocoaError(.fileReadUnknown) }
        let hash = digest(data)
        // A move inside the same tree keeps the track identity and its offline audio.
        let moved =
          old == nil
          ? existing.first { candidate in
            guard let oldPath = candidate.sourcePath else { return false }
            return priorIDs.contains(candidate.id) && candidate.contentHash == hash
              && !currentPaths.contains(oldPath)
              && !result.tracks.contains(where: { $0.id == candidate.id })
          } : nil
        let matched = old ?? moved
        let filename: String
        if let matched, matched.contentHash == hash {
          filename = matched.filename
        } else {
          filename = "\(hash).\(url.pathExtension.lowercased())"
        }
        let destination = LibraryStorage.directory.appendingPathComponent(filename)
        if !manager.fileExists(atPath: destination.path) {
          try data.write(to: destination, options: .atomic)
        }
        let asset = AVURLAsset(url: destination)
        guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.metadata)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Unknown artist"
        var album: String?
        var artworkFilename: String?
        for item in metadata {
          if item.commonKey == .commonKeyTitle, let value = try? await item.load(.stringValue),
            !value.isEmpty
          {
            title = value
          }
          if item.commonKey == .commonKeyArtist, let value = try? await item.load(.stringValue),
            !value.isEmpty
          {
            artist = value
          }
          if item.commonKey == .commonKeyAlbumName { album = try? await item.load(.stringValue) }
          if item.commonKey == .commonKeyArtwork, let imageData = try? await item.load(.dataValue) {
            artworkFilename = saveArtwork(imageData, audioHash: hash)
          }
        }
        if artworkFilename == nil && url.pathExtension.lowercased() == "flac" {
          do {
            if let image = try FlacArtwork.embeddedImage(in: data) {
              artworkFilename = saveArtwork(image, audioHash: hash)
            }
          } catch {
            log.warning(
              "FLAC artwork could not be read for \(url.path, privacy: .public): \(error, privacy: .public)"
            )
          }
        }
        result.tracks.append(
          Track(
            id: matched?.id ?? UUID().uuidString, title: title, artist: artist,
            filename: filename, sourceSignature: signature,
            duration: duration.isFinite ? duration : 0, sourcePath: path,
            contentHash: hash, album: album, artworkFilename: artworkFilename,
            metadataVersion: LibraryStorage.metadataVersion))
      } catch {
        if let old, !result.tracks.contains(where: { $0.id == old.id }) {
          result.tracks.append(old)
        }
        result.failures += 1
        log.error("Sync failed for \(url.path, privacy: .public): \(error, privacy: .public)")
      }
    }
    result.tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    return result
  }

  func removeUnusedCopies(keeping filenames: Set<String>) {
    guard !isSynchronizing else { return }
    do {
      for url in try FileManager.default.contentsOfDirectory(
        at: LibraryStorage.directory, includingPropertiesForKeys: [.isRegularFileKey])
      {
        guard url.lastPathComponent != LibraryStorage.index.lastPathComponent,
          !filenames.contains(url.lastPathComponent),
          try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { continue }
        try FileManager.default.removeItem(at: url)
      }
    } catch { log.error("Cache cleanup failed: \(error, privacy: .public)") }
  }

  private func saveArtwork(_ data: Data, audioHash: String) -> String? {
    let name = audioHash + "-cover.jpg"
    let url = LibraryStorage.directory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: url.path) { return name }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 768,
        ] as CFDictionary),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      log.warning("Embedded artwork could not be decoded")
      return nil
    }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      log.warning("Embedded artwork could not be saved")
      return nil
    }
    return name
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

@MainActor @Observable
final class MusicLibrary {
  private struct SavedSource: Codable {
    let id: String
    var bookmark: Data
    var name: String? = nil
    var customName: String? = nil
    var isFolder: Bool? = nil
  }
  private struct Source {
    var saved: SavedSource
    var url: URL?
  }

  private(set) var tracks: [Track] = []
  private(set) var isRefreshing = false
  private(set) var status = "Your music, in one place."
  var errorMessage: String?
  private var sources: [Source] = []
  private var index = LibraryIndex()
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let importer = FolderImporter()
  @ObservationIgnored private let log = Logger(subsystem: "app.foldertone", category: "Library")
  @ObservationIgnored private var refreshRequested = false
  @ObservationIgnored private var observing = false
  @ObservationIgnored private var observers: [String: SourceObserver] = [:]
  @ObservationIgnored private var changeTask: Task<Void, Never>?
  @ObservationIgnored private var pendingFileURLs: [URL] = []
  @ObservationIgnored private var dirtyPaths: Set<String> = []

  var sourceSummary: String? {
    guard !sources.isEmpty else { return nil }
    return sources.count == 1
      ? displayName(sources[0].saved)
      : "\(sources.count) sources connected"
  }

  var playlists: [Playlist] {
    sources.filter { $0.saved.isFolder == true }.map { source in
      Playlist(
        id: source.saved.id, name: displayName(source.saved),
        trackIDs: Set(index.memberships[source.saved.id] ?? []))
    }
  }

  var connections: [MusicSource] {
    sources.map {
      MusicSource(id: $0.saved.id, name: displayName($0.saved), isFolder: $0.saved.isFolder == true)
    }
  }

  private func displayName(_ saved: SavedSource) -> String {
    saved.customName ?? Self.friendlyName(saved.name ?? "Music folder")
  }

  private static func friendlyName(_ name: String) -> String {
    name == "File Provider Storage" ? "Files" : name
  }

  private static func sourceName(_ url: URL) -> String {
    let name =
      (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
      ?? url.lastPathComponent
    return friendlyName(name)
  }

  enum SourceEditError: LocalizedError {
    case busy, wrongKind, duplicate, emptyName
    var errorDescription: String? {
      switch self {
      case .busy: "Wait for syncing to finish, then try again."
      case .wrongKind: "Choose a folder for a folder playlist, or an audio file for a file source."
      case .duplicate: "That source is already connected. Choose its existing playlist instead."
      case .emptyName: "Enter a name for this source."
      }
    }
  }

  func renameSource(id: String, name: String) throws {
    guard !isRefreshing else { throw SourceEditError.busy }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw SourceEditError.emptyName }
    var updated = sources
    guard let i = updated.firstIndex(where: { $0.saved.id == id }) else { return }
    updated[i].saved.customName = name
    try persistSources(updated)
    sources = updated
  }

  func reconnectSource(id: String, to url: URL) async throws {
    guard !isRefreshing else { throw SourceEditError.busy }
    guard let i = sources.firstIndex(where: { $0.saved.id == id }) else { return }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let isFolder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    guard isFolder == (sources[i].saved.isFolder == true) else { throw SourceEditError.wrongKind }
    guard
      !sources.contains(where: {
        $0.saved.id != id && $0.url.map(LibraryStorage.path) == LibraryStorage.path(url)
      })
    else { throw SourceEditError.duplicate }
    var updated = sources
    updated[i].saved.bookmark = try url.bookmarkData(
      options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    updated[i].saved.name = Self.sourceName(url)
    updated[i].url = url
    try persistSources(updated)
    sources = updated
    pendingFileURLs = []
    if observing { rebuildObservers() }
    await refresh()
  }

  func disconnectSource(id: String) async throws {
    guard !isRefreshing else { throw SourceEditError.busy }
    let updated = sources.filter { $0.saved.id != id }
    try persistSources(updated)
    sources = updated
    pendingFileURLs = []
    if observing { rebuildObservers() }
    await refresh()
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--empty-library") { return }
    #endif
    do {
      index = try LibraryIndex.load()
      tracks = index.tracks
    } catch {
      errorMessage = "The saved library could not be read. Add its sources again to resync it."
    }
    let saved: [SavedSource]
    if let data = defaults.data(forKey: "musicConnections") {
      do { saved = try JSONDecoder().decode([SavedSource].self, from: data) } catch {
        errorMessage = "Saved sources could not be read. Add your files or folders again."
        saved = []
      }
    } else {
      let bookmarks =
        defaults.array(forKey: "musicSources") as? [Data]
        ?? defaults.data(forKey: "musicFolder").map { [$0] } ?? []
      saved = bookmarks.map { SavedSource(id: UUID().uuidString, bookmark: $0) }
    }
    sources = saved.map { Source(saved: $0, url: nil) }
    resolveSources()
  }

  func connect(_ url: URL) throws { try addSources([url]) }

  @discardableResult
  func addSources(_ urls: [URL]) throws -> URL? {
    var singleFile: URL?
    var updated = sources
    for url in urls {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let bookmark = try url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      let existing = updated.first {
        $0.url.map { LibraryStorage.path($0) } == LibraryStorage.path(url)
      }
      guard let isFolder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
        throw CocoaError(.fileReadUnknown)
      }
      let saved = SavedSource(
        id: existing?.saved.id ?? UUID().uuidString, bookmark: bookmark,
        name: Self.sourceName(url), customName: existing?.saved.customName, isFolder: isFolder)
      updated.removeAll { $0.saved.id == saved.id }
      updated.append(Source(saved: saved, url: url))
      if urls.count == 1 && saved.isFolder == false { singleFile = url }
    }
    try persistSources(updated)
    sources = updated
    if observing { rebuildObservers() }
    errorMessage = nil
    return singleFile
  }

  func refresh(retryDownloads: Bool = true) async {
    guard !sources.isEmpty || !index.tracks.isEmpty else { return }
    if isRefreshing {
      refreshRequested = true
      return
    }
    isRefreshing = true
    defer { isRefreshing = false }
    if retryDownloads { await importer.retryDownloads() }
    repeat {
      refreshRequested = false
      resolveSources()
      status = "Syncing your music…"
      let forced = dirtyPaths
      dirtyPaths.removeAll()
      do {
        let result = try await importer.synchronize(
          sources.map { SyncSource(id: $0.saved.id, url: $0.url) }, previous: index,
          forcePaths: forced)
        index = result.index
        tracks = index.tracks
        pendingFileURLs = result.pendingURLs
        if observing { rebuildObservers() }
        if result.failures > 0 {
          status = "Some music is unavailable. Pull to retry."
        } else if result.pending > 0 {
          status = "Downloading \(result.pending) files…"
        } else {
          status = "Up to date"
        }
      } catch is CancellationError {
        dirtyPaths.formUnion(forced)
        return
      } catch {
        dirtyPaths.formUnion(forced)
        status = "Sync could not be saved. Pull to retry."
        log.error("Sync failed: \(error, privacy: .public)")
      }
    } while refreshRequested && !Task.isCancelled
  }

  func activate() async {
    observing = true
    resolveSources()
    rebuildObservers()
    await refresh()
  }

  func stopObserving() {
    observing = false
    refreshRequested = false
    changeTask?.cancel()
    changeTask = nil
    for observer in observers.values { observer.stop() }
    observers.removeAll()
  }

  private func rebuildObservers() {
    var expected = Dictionary(
      sources.compactMap { source in
        source.url.map { (source.saved.id, $0) }
      }, uniquingKeysWith: { _, last in last })
    for url in pendingFileURLs { expected["pending:" + LibraryStorage.path(url)] = url }
    for (id, observer) in observers {
      if expected[id].map({ LibraryStorage.path($0) })
        != observer.presentedItemURL.map({ LibraryStorage.path($0) })
      {
        observer.stop()
        observers.removeValue(forKey: id)
      }
    }
    for (id, url) in expected where observers[id] == nil {
      let observer = SourceObserver(url: url) { [weak self] change in
        Task { @MainActor in
          guard let self, self.observing else { return }
          switch change {
          case .moved(let url): self.sourceMoved(id: id, to: url)
          case .content(let url): self.dirtyPaths.insert(LibraryStorage.path(url))
          }
          self.scheduleRefresh()
        }
      }
      observers[id] = observer
      observer.start()
    }
  }

  private func sourceMoved(id: String, to url: URL) {
    guard let i = sources.firstIndex(where: { $0.saved.id == id }) else { return }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      sources[i].saved.bookmark = try url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      sources[i].saved.name = Self.sourceName(url)
      sources[i].url = url
      try persistSources(sources)
    } catch { log.error("Updating a moved source failed: \(error, privacy: .public)") }
  }

  private func scheduleRefresh() {
    changeTask?.cancel()
    changeTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard let self, self.observing else { return }
      self.changeTask = nil
      await self.refresh(retryDownloads: false)
    }
  }

  func cleanupCache(keeping filenames: Set<String>) async {
    guard !isRefreshing else { return }
    await importer.removeUnusedCopies(
      keeping: Set(tracks.map(\.filename) + tracks.compactMap(\.artworkFilename)).union(filenames))
  }

  private func resolveSources() {
    for i in sources.indices {
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: sources[i].saved.bookmark, options: [], bookmarkDataIsStale: &stale
        )
        sources[i].url = url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        sources[i].saved.name = Self.sourceName(url)
        if let isFolder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
          sources[i].saved.isFolder = isFolder
        }
        if stale {
          sources[i].saved.bookmark = try url.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
      } catch {
        log.error("Restoring a source failed: \(error, privacy: .public)")
      }
    }
    do { try persistSources(sources) } catch {
      log.error("Saving source bookmarks failed: \(error, privacy: .public)")
    }
  }

  deinit {
    changeTask?.cancel()
    for observer in observers.values { observer.stop() }
  }

  private func persistSources(_ sources: [Source]) throws {
    defaults.set(try JSONEncoder().encode(sources.map(\.saved)), forKey: "musicConnections")
  }
}

// AVFoundation exposes Vorbis text tags but may omit the FLAC PICTURE block.
// RFC 9639, sections 8.1 and 8.8. All offsets are bounded before reading.
enum FlacArtwork {
  enum ParseError: Error { case malformed }

  static func embeddedImage(in data: Data) throws -> Data? {
    guard data.starts(with: Data("fLaC".utf8)) else { return nil }
    var offset = 4
    var fallback: Data?
    while offset < data.count {
      guard data.count - offset >= 4 else { throw ParseError.malformed }
      let last = data[offset] & 0x80 != 0
      let type = data[offset] & 0x7f
      let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
      offset += 4
      guard length <= data.count - offset else { throw ParseError.malformed }
      if type == 6 {
        var reader = Reader(data: data, offset: offset, end: offset + length)
        let pictureType = try reader.integer()
        let mimeLength = try reader.integer()
        let mime = try reader.bytes(mimeLength)
        let descriptionLength = try reader.integer()
        try reader.skip(descriptionLength)
        try reader.skip(16)  // Width, height, depth, and palette size.
        let imageLength = try reader.integer()
        let image = try reader.bytes(imageLength)
        if String(data: mime, encoding: .utf8) != "-->" && !image.isEmpty {
          if pictureType == 3 { return image }
          if fallback == nil { fallback = image }
        }
      }
      if last { return fallback }
      offset += length
    }
    throw ParseError.malformed
  }

  private struct Reader {
    let data: Data
    var offset: Int
    let end: Int
    mutating func integer() throws -> Int {
      guard end - offset >= 4 else { throw ParseError.malformed }
      let result =
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
        | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
      offset += 4
      return result
    }
    mutating func skip(_ count: Int) throws {
      guard count >= 0 && count <= end - offset else { throw ParseError.malformed }
      offset += count
    }
    mutating func bytes(_ count: Int) throws -> Data {
      let start = offset
      try skip(count)
      return data.subdata(in: start..<offset)
    }
  }
}
