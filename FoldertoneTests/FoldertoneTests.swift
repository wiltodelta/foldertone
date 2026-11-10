import CryptoKit
import Foundation
import ImageIO

#if !SYNC_STANDALONE
  import XCTest
  @testable import Foldertone

  final class FoldertoneTests: XCTestCase {
    @MainActor func testCoordinatedChangesRefreshWithoutPolling() async throws {
      try await SyncScenarios.eventDrivenChanges()
    }
    func testFormatsAndEmbeddedMetadata() async throws {
      try await SyncScenarios.formatsAndMetadata()
    }
    func testShuffleRepeatAndQueueReconciliation() throws { try SyncScenarios.playbackOrder() }

    func testRecursiveSyncHandlesAddDeleteRenameMoveAndReplace() async throws {
      try await SyncScenarios.recursiveChanges()
    }
    func testUnavailableSourceDoesNotEraseItsPlaylist() async throws {
      try await SyncScenarios.unavailableSource()
    }
    func testOverlappingSourcesDoNotDuplicateTracks() async throws {
      try await SyncScenarios.overlappingSources()
    }
    func testOriginalIndexMigratesAndIsSavedAtomically() async throws {
      try await SyncScenarios.legacyIndex()
    }
    @MainActor func testFoldersBecomePlaylistsAndSingleFileRequestsPlayback() async throws {
      try await SyncScenarios.playlistsAndFiles()
    }
    @MainActor func testSourceManagementPreservesOriginalsAndSharedTracks() async throws {
      try await SyncScenarios.sourceManagement()
    }
    func testOnlyUnusedOfflineCopiesAreRemoved() async throws {
      try await SyncScenarios.cacheCleanup()
    }
    func testUnreadableSubfolderDoesNotLookLikeDeletion() async throws {
      try await SyncScenarios.incompleteEnumeration()
    }
    @MainActor func testPlayerReconcilesRenamesAndRemovals() async throws {
      let sample = try SampleLibrary.create()
      let result = try await FolderImporter().synchronize(
        [SyncSource(id: "player", url: sample)], previous: LibraryIndex())
      let track = try XCTUnwrap(result.index.tracks.first)
      let player = MusicPlayer()
      player.play(track, in: [track])
      let renamed = Track(
        id: track.id, title: "After", artist: track.artist, filename: track.filename,
        sourceSignature: track.sourceSignature, duration: track.duration)
      player.reconcile(with: [renamed])
      XCTAssertEqual(player.current?.title, "After")
      player.reconcile(with: [])
      XCTAssertNil(player.current)
      XCTAssertFalse(player.isPlaying)
    }

    @MainActor func testPlayAllKeepsTheChosenShuffleMode() async throws {
      let sample = try SampleLibrary.create()
      let tracks = try await FolderImporter().synchronize(
        [SyncSource(id: "play-all", url: sample)], previous: LibraryIndex()
      ).index.tracks
      XCTAssertGreaterThan(tracks.count, 1)
      let player = MusicPlayer()
      player.playAll(tracks)
      XCTAssertFalse(player.isShuffled)
      XCTAssertEqual(player.current?.id, tracks.first?.id)
      XCTAssertEqual(player.upNext.map(\.id), tracks.dropFirst().map(\.id))
      player.toggleShuffle()
      player.playAll(tracks)
      XCTAssertTrue(player.isShuffled, "Play all must keep shuffle chosen in the player")
      let played = [player.current?.id].compactMap { $0 } + player.upNext.map(\.id)
      XCTAssertEqual(played.sorted(), tracks.map(\.id).sorted())
    }
  }
#endif

// The same scenarios run in XCTest and in the isolated host runner when CoreSimulator is unavailable.
enum SyncScenarios {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }
  private static func check(
    _ condition: @autoclosure () throws -> Bool, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let passed = try condition()
    if !passed { throw Failure(description: "\(file):\(line): \(message)") }
  }

  private struct Fixture {
    let root: URL
    let a: URL
    let b: URL
    let samples: [URL]
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "FoldertoneTests-\(UUID().uuidString)", isDirectory: true)
      a = root.appendingPathComponent("Music", isDirectory: true)
      b = root.appendingPathComponent("Other music", isDirectory: true)
      try FileManager.default.createDirectory(
        at: a.appendingPathComponent("Nested/Deep", isDirectory: true),
        withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
      samples = try FileManager.default.contentsOfDirectory(
        at: SampleLibrary.create(), includingPropertiesForKeys: nil
      )
      .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
      try FileManager.default.copyItem(at: samples[0], to: a.appendingPathComponent("One.wav"))
      try FileManager.default.copyItem(
        at: samples[1], to: a.appendingPathComponent("Nested/Deep/Two.wav"))
      try FileManager.default.copyItem(at: samples[2], to: b.appendingPathComponent("Three.wav"))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }

  static func recursiveChanges() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let importer = FolderImporter()
    let source = [SyncSource(id: "music", url: f.a)]
    var state = try await importer.synchronize(source, previous: LibraryIndex()).index
    try check(state.tracks.count == 2, "Initial recursive snapshot must include the deep track")
    try check(
      try LibraryStorage.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true,
      "Playback copies must stay out of iCloud Backup")
    let two = try track("Two", in: state)
    let renamed = f.a.appendingPathComponent("Nested/Deep/Renamed.wav")
    try FileManager.default.moveItem(
      at: f.a.appendingPathComponent("Nested/Deep/Two.wav"), to: renamed)
    state = try await importer.synchronize(source, previous: state).index
    let renamedTrack = try track("Renamed", in: state)
    try check(
      renamedTrack.id == two.id && renamedTrack.filename == two.filename,
      "Rename must update the title without duplicating or interrupting cached audio")
    let moved = f.a.appendingPathComponent("Moved/Even deeper/Tune.wav")
    try FileManager.default.createDirectory(
      at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: renamed, to: moved)
    state = try await importer.synchronize(source, previous: state).index
    try check(
      try track("Tune", in: state).id == two.id,
      "Move into a nested folder must retain track identity")
    try FileManager.default.removeItem(at: f.a.appendingPathComponent("One.wav"))
    state = try await importer.synchronize(source, previous: state).index
    try check(
      state.tracks.count == 1 && state.tracks[0].title == "Tune",
      "Confirmed file deletion must remove its track")
    let hidden = f.a.appendingPathComponent(".Hidden/Three.wav")
    try FileManager.default.createDirectory(
      at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: f.samples[2], to: hidden)
    state = try await importer.synchronize(source, previous: state).index
    try check(
      state.tracks.count == 2, "New files in nested hidden folders must appear in the flat playlist"
    )
    let previousHash = try track("Tune", in: state).contentHash
    try Data(contentsOf: f.samples[0]).write(to: moved, options: .atomic)
    state = try await importer.synchronize(source, previous: state).index
    let replaced = try track("Tune", in: state)
    try check(
      replaced.id == two.id && replaced.contentHash != previousHash,
      "Replacing audio must update the offline copy")
    try Data("not audio".utf8).write(to: moved, options: .atomic)
    let unreadable = try await importer.synchronize(source, previous: state)
    try check(
      unreadable.failures > 0 && unreadable.index.tracks.contains(replaced),
      "An unreadable existing file must retain its last good audio")
    try FileManager.default.removeItem(at: hidden.deletingLastPathComponent())
    state = try await importer.synchronize(source, previous: unreadable.index).index
    try check(state.tracks.count == 1, "Deleting a subfolder must remove all its tracks")
    let saved = try LibraryIndex.load()
    try check(saved == state, "Persisted snapshot must match the live catalog")
  }

  static func unavailableSource() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let importer = FolderImporter()
    let sources = [SyncSource(id: "a", url: f.a), SyncSource(id: "b", url: f.b)]
    let before = try await importer.synchronize(sources, previous: LibraryIndex()).index
    let disconnected = f.root.appendingPathComponent("Disconnected", isDirectory: true)
    try FileManager.default.moveItem(at: f.a, to: disconnected)
    try FileManager.default.removeItem(at: f.b.appendingPathComponent("Three.wav"))
    let unavailable = try await importer.synchronize(sources, previous: before)
    try check(
      unavailable.failures > 0 && unavailable.index.tracks.count == 2,
      "A failed root must keep its tracks while a readable root removes deleted tracks")
    try check(
      unavailable.index.memberships["a"] == before.memberships["a"]
        && unavailable.index.memberships["b"] == [], "Root snapshots must be independent")
    let restored = try LibraryIndex.load()
    try check(restored == unavailable.index, "Offline memberships must survive restart")
    try FileManager.default.moveItem(at: disconnected, to: f.a)
    try FileManager.default.removeItem(at: f.a.appendingPathComponent("One.wav"))
    let reconnected = try await importer.synchronize(sources, previous: restored)
    try check(
      reconnected.failures == 0 && reconnected.index.tracks.count == 1,
      "Reconnected root must reconcile deletions")
  }

  static func overlappingSources() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let importer = FolderImporter()
    let sources = [
      SyncSource(id: "a", url: f.a),
      SyncSource(id: "nested", url: f.a.appendingPathComponent("Nested", isDirectory: true)),
      SyncSource(id: "file", url: f.a.appendingPathComponent("One.wav")),
    ]
    let before = try await importer.synchronize(sources, previous: LibraryIndex()).index
    try check(
      before.tracks.count == 2 && before.memberships["a"]?.count == 2
        && before.memberships["nested"]?.count == 1 && before.memberships["file"]?.count == 1,
      "Overlapping sources must share tracks and retain separate flat memberships")
    let repeated = try await importer.synchronize(sources.reversed(), previous: before).index
    try check(repeated == before, "Source order and repeat scanning must not change the catalog")
    try FileManager.default.removeItem(at: f.a.appendingPathComponent("Nested/Deep/Two.wav"))
    let deleted = try await importer.synchronize(sources, previous: repeated).index
    try check(
      deleted.tracks.count == 1 && deleted.memberships["nested"] == [],
      "Deletion must reconcile every overlapping playlist")
  }

  static func legacyIndex() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let importer = FolderImporter()
    let source = [SyncSource(id: "a", url: f.a)]
    let current = try await importer.synchronize(source, previous: LibraryIndex()).index
    guard let enumerator = FileManager.default.enumerator(at: f.a, includingPropertiesForKeys: nil)
    else { throw Failure(description: "Missing fixture enumerator") }
    let urls = enumerator.allObjects.compactMap { $0 as? URL }
    let legacy = try current.tracks.map { track in
      guard
        let url = urls.first(where: { $0.deletingPathExtension().lastPathComponent == track.title })
      else { throw Failure(description: "Missing legacy source") }
      let identity = f.a.absoluteString + String(url.path.dropFirst(f.a.path.count))
      let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
      return Track(
        id: id, title: track.title, artist: track.artist, filename: track.filename,
        sourceSignature: track.sourceSignature, duration: track.duration)
    }
    try JSONEncoder().encode(legacy).write(to: LibraryStorage.index, options: .atomic)
    let old = try LibraryIndex.load()
    try check(old.unassigned.count == legacy.count, "Original array index must migrate")
    let inaccessible = try await importer.synchronize(
      [SyncSource(id: "a", url: nil)], previous: old
    ).index
    try check(
      inaccessible.tracks.count == legacy.count,
      "Unassigned legacy tracks must survive an unavailable first scan")
    let migrated = try await importer.synchronize(source, previous: inaccessible).index
    try check(
      Set(migrated.tracks.map(\.id)) == Set(legacy.map(\.id)) && migrated.unassigned.isEmpty,
      "Legacy identities must be adopted without duplicates")
    try FileManager.default.removeItem(at: f.a.appendingPathComponent("One.wav"))
    let deleted = try await importer.synchronize(source, previous: migrated).index
    try check(deleted.tracks.count == 1, "Migrated tracks must support deletion")
  }

  @MainActor static func playlistsAndFiles() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let name = "FoldertoneSyncTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
      throw Failure(description: "Missing test defaults")
    }
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(
      try f.a.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
      forKey: "musicFolder")
    let library = MusicLibrary(defaults: defaults)
    try check(library.playlists.count == 1, "An original folder bookmark must become a playlist")
    let folderPlayback = try library.addSources([f.b])
    try check(
      folderPlayback == nil && library.playlists.count == 2,
      "Each folder must create its own playlist, without single-file playback")
    let file = f.a.appendingPathComponent("One.wav")
    let playback = try library.addSources([file])
    try check(
      playback.map { LibraryStorage.path($0) } == LibraryStorage.path(file)
        && library.playlists.count == 2,
      "A single file must request playback without creating a playlist")
    try library.addSources([file])
    await library.refresh()
    try check(
      library.tracks.count == 3 && library.playlists.first?.trackIDs.count == 2,
      "Folder playlist must flatten its nested files without duplicates")
    let restored = MusicLibrary(defaults: defaults)
    await restored.refresh()
    try check(
      restored.playlists == library.playlists && restored.tracks == library.tracks,
      "Playlist IDs, memberships, and tracks must survive relaunch")
  }

  @MainActor static func sourceManagement() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let domain = "FoldertoneSourceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let library = MusicLibrary(defaults: defaults)
    let technical = f.root.appendingPathComponent("File Provider Storage", isDirectory: true)
    try FileManager.default.createDirectory(at: technical, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: f.samples[0], to: technical.appendingPathComponent("Standalone.wav"))
    try library.addSources([f.a, f.a.appendingPathComponent("Nested"), technical])
    await library.refresh()
    let rootID = library.playlists.first { $0.name == "Music" }!.id
    let nested = library.playlists.first { $0.name == "Nested" }!
    try check(
      library.connections.last?.name == "Files", "Provider implementation names must be hidden")
    try library.renameSource(id: rootID, name: "  Evening  ")
    try library.addSources([f.a])
    await library.refresh()
    let restored = MusicLibrary(defaults: defaults)
    try check(
      restored.playlists.first { $0.id == rootID }?.name == "Evening",
      "A trimmed custom name must survive re-adding, synchronization, and relaunch")
    do {
      try library.renameSource(id: rootID, name: "  ")
      throw Failure(description: "Blank source names must be rejected")
    } catch MusicLibrary.SourceEditError.emptyName {}
    do {
      try await library.reconnectSource(id: rootID, to: f.a.appendingPathComponent("One.wav"))
      throw Failure(description: "Reconnect must reject a different source kind")
    } catch MusicLibrary.SourceEditError.wrongKind {}
    do {
      try await library.reconnectSource(id: rootID, to: f.a.appendingPathComponent("Nested"))
      throw Failure(description: "Reconnect must reject an already connected source")
    } catch MusicLibrary.SourceEditError.duplicate {}
    try await library.reconnectSource(id: rootID, to: f.b)
    try check(
      library.playlists.first { $0.id == rootID }?.name == "Evening"
        && library.playlists.first { $0.id == rootID }?.trackIDs.count == 1,
      "Reconnect must retain playlist identity and custom name while adopting the selected folder")
    let rootTracks = library.playlists.first { $0.id == rootID }!.trackIDs
    try await library.disconnectSource(id: rootID)
    try check(
      library.playlists.allSatisfy { $0.id != rootID }
        && nested.trackIDs.isSubset(of: Set(library.tracks.map(\.id)))
        && rootTracks.isDisjoint(with: Set(library.tracks.map(\.id))),
      "Disconnect must remove only unshared membership and keep overlapping tracks")
    for source in library.connections { try await library.disconnectSource(id: source.id) }
    let reopened = MusicLibrary(defaults: defaults)
    try check(
      reopened.connections.isEmpty && reopened.tracks.isEmpty,
      "Disconnecting the last source must persist an empty library")
    try check(
      FileManager.default.fileExists(atPath: f.a.appendingPathComponent("One.wav").path)
        && FileManager.default.fileExists(
          atPath: f.a.appendingPathComponent("Nested/Deep/Two.wav").path)
        && FileManager.default.fileExists(atPath: f.b.appendingPathComponent("Three.wav").path),
      "Source management must never delete original files")
  }

  static func cacheCleanup() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let importer = FolderImporter()
    let source = [SyncSource(id: "a", url: f.a)]
    let before = try await importer.synchronize(source, previous: LibraryIndex()).index
    let one = try track("One", in: before)
    try FileManager.default.removeItem(at: f.a.appendingPathComponent("One.wav"))
    let after = try await importer.synchronize(source, previous: before).index
    let retained = Set(after.tracks.map(\.filename))
    await importer.removeUnusedCopies(keeping: retained.union([one.filename]))
    try check(
      FileManager.default.fileExists(atPath: one.url.path),
      "Protected playing audio must not be removed")
    await importer.removeUnusedCopies(keeping: retained)
    try check(
      !FileManager.default.fileExists(atPath: one.url.path),
      "Unreferenced audio must be removed from the offline cache")
    try check(
      after.tracks.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }
        && FileManager.default.fileExists(
          atPath: f.a.appendingPathComponent("Nested/Deep/Two.wav").path),
      "Cleanup must retain current tracks and never touch source files")
  }

  static func incompleteEnumeration() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let importer = FolderImporter()
    let sources = [SyncSource(id: "a", url: f.a)]
    let before = try await importer.synchronize(sources, previous: LibraryIndex()).index
    let locked = f.a.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
    }
    let result = try await importer.synchronize(sources, previous: before)
    try check(
      result.failures > 0 && result.index.tracks == before.tracks,
      "Incomplete traversal must preserve the previous complete snapshot")
  }

  @MainActor static func eventDrivenChanges() async throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let name = "FoldertoneEventTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
      throw Failure(description: "Missing defaults")
    }
    defer { defaults.removePersistentDomain(forName: name) }
    let library = MusicLibrary(defaults: defaults)
    let original = f.a.appendingPathComponent("One.wav")
    try FileManager.default.setAttributes(
      [
        .modificationDate: Date(
          timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
      ], ofItemAtPath: original.path)
    try library.addSources([f.a])
    await library.activate()
    defer { library.stopObserving() }
    let before = library.tracks.count
    let renamed = f.a.appendingPathComponent("Event renamed.wav")
    try coordinatedWrite(original, options: .forMoving) { url, coordinator in
      try FileManager.default.moveItem(at: url, to: renamed)
      coordinator.item(at: url, didMoveTo: renamed)
    }
    try await eventually { library.tracks.contains { $0.title == "Event renamed" } }
    try check(library.tracks.count == before, "A rename notification must not duplicate tracks")
    let previousHash = library.tracks.first { $0.title == "Event renamed" }?.contentHash
    let oldValues = try renamed.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    guard let originalDate = oldValues.contentModificationDate else {
      throw Failure(description: "Missing file date")
    }
    try coordinatedWrite(renamed) { url, _ in
      try Data(contentsOf: f.samples[2]).write(to: url, options: .atomic)
      try FileManager.default.setAttributes(
        [.modificationDate: originalDate], ofItemAtPath: url.path)
    }
    let currentValues = try URL(fileURLWithPath: renamed.path).resourceValues(forKeys: [
      .contentModificationDateKey, .fileSizeKey,
    ])
    try check(
      currentValues.contentModificationDate == originalDate
        && currentValues.fileSize == oldValues.fileSize,
      "The overwrite fixture must preserve file size and modification date")
    try await eventually {
      library.tracks.first { $0.title == "Event renamed" }?.contentHash != previousHash
    }
    let added = f.a.appendingPathComponent("Nested/Deep/Event added.wav")
    try coordinatedWrite(added) { url, _ in
      try FileManager.default.copyItem(at: f.samples[2], to: url)
    }
    try await eventually { library.tracks.count == before + 1 }
    try coordinatedWrite(added, options: .forDeleting) { url, _ in
      try FileManager.default.removeItem(at: url)
    }
    try await eventually { library.tracks.count == before }
    library.stopObserving()
    try check(
      !NSFileCoordinator.filePresenters.contains {
        $0.presentedItemURL.map { LibraryStorage.path($0) } == LibraryStorage.path(f.a)
      }, "Background transition must unregister presenters")
    try FileManager.default.copyItem(at: f.samples[2], to: added)
    await library.activate()
    try check(
      library.tracks.count == before + 1, "Foreground activation must reconcile missed changes")
  }

  private static func coordinatedWrite(
    _ url: URL, options: NSFileCoordinator.WritingOptions = [],
    body: (URL, NSFileCoordinator) throws -> Void
  ) throws {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var operationError: Error?
    coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) {
      coordinated in
      do { try body(coordinated, coordinator) } catch { operationError = error }
    }
    if let coordinationError { throw coordinationError }
    if let operationError { throw operationError }
  }

  @MainActor private static func eventually(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    while !condition() {
      if clock.now >= deadline {
        throw Failure(description: "A file change did not refresh the library")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  static func formatsAndMetadata() async throws {
    let fixtures: URL
    #if SYNC_STANDALONE
      fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
        "Fixtures", isDirectory: true)
    #else
      guard let resources = Bundle(for: FoldertoneTests.self).resourceURL else {
        throw Failure(description: "Missing test bundle")
      }
      fixtures = resources.appendingPathComponent("Fixtures", isDirectory: true)
    #endif
    let rawFlac = try Data(contentsOf: fixtures.appendingPathComponent("FLAC.flac"))
    let image = try FlacArtwork.embeddedImage(in: rawFlac)
    guard let image,
      let source = CGImageSourceCreateWithData(image as CFData, nil),
      let cover = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw Failure(description: "FLAC PICTURE parsing must return a decodable embedded cover")
    }
    try check(
      cover.width == 32 && cover.height == 32,
      "FLAC PICTURE parsing must retain the embedded cover dimensions")
    for count in [4, 7, 9, 30] {
      do {
        _ = try FlacArtwork.embeddedImage(in: Data(rawFlac.prefix(count)))
        throw Failure(description: "Truncated FLAC metadata must be rejected")
      } catch is FlacArtwork.ParseError {}
    }
    let importer = FolderImporter()
    let result = try await importer.synchronize(
      [SyncSource(id: "formats", url: fixtures)], previous: LibraryIndex())
    try check(
      result.failures == 0 && result.index.tracks.count == 6,
      "MP3, FLAC, AAC, ALAC, WAV, and AIFF must import")
    try check(
      result.index.tracks.allSatisfy {
        $0.duration > 0 && FileManager.default.fileExists(atPath: $0.url.path)
      }, "Every codec fixture must have playable cached audio")
    for format in ["MP3", "FLAC", "AAC", "ALAC"] {
      let item = try track("Tagged " + format, in: result.index)
      try check(
        item.artist == "Fixture artist" && item.album == "Fixture album",
        "Embedded artist and album must be read for " + format)
      try check(
        item.artworkFilename.map {
          FileManager.default.fileExists(
            atPath: LibraryStorage.directory.appendingPathComponent($0).path)
        } == true, "Embedded cover must be decoded for " + format)
    }
  }

  static func playbackOrder() throws {
    let tracks = (0..<8).map {
      Track(
        id: String($0), title: "Track \($0)", artist: "Artist", filename: "unused",
        sourceSignature: "1", duration: 20)
    }
    var queue = PlaybackQueue()
    queue.begin(tracks, starting: tracks[0], shuffled: true)
    try check(
      queue.tracks.first?.id == tracks[0].id
        && Set(queue.tracks.map(\.id)) == Set(tracks.map(\.id)),
      "Shuffle must retain every track exactly once")
    var played = [tracks[0].id]
    var id = tracks[0].id
    while let next = queue.next(after: id, automatically: true, repeatMode: .off) {
      id = next.id
      played.append(id)
      try check(played.count <= tracks.count, "Shuffle without repeat must terminate")
    }
    try check(
      played.count == tracks.count && Set(played).count == tracks.count,
      "A shuffle cycle must visit each track once")
    try check(
      queue.next(after: id, automatically: true, repeatMode: .playlist)?.id == tracks[0].id,
      "Playlist repeat must restart at the beginning")
    try check(
      queue.next(after: tracks[0].id, automatically: true, repeatMode: .track)?.id == tracks[0].id,
      "Track repeat must repeat the current track")
    try check(
      queue.next(after: tracks[0].id, automatically: false, repeatMode: .track)?.id != tracks[0].id,
      "Manual next must skip a repeated track")
    queue.toggleShuffle(keeping: tracks[2].id)
    try check(
      !queue.isShuffled && queue.tracks == tracks, "Disabling shuffle must restore normal order")
    let history = Array(queue.tracks.prefix(3))
    queue.toggleShuffle(keeping: tracks[2].id)
    try check(
      Array(queue.tracks.prefix(3)) == history,
      "Enabling shuffle must preserve the playing track and history")
    let replacement =
      Array(tracks.prefix(6)) + [
        Track(
          id: "new", title: "New", artist: "Artist", filename: "unused", sourceSignature: "1",
          duration: 20)
      ]
    queue.reconcile(with: replacement)
    try check(
      Set(queue.tracks.map(\.id)) == Set(replacement.map(\.id))
        && queue.tracks.count == replacement.count,
      "A synchronized queue must adopt additions and deletions without duplicates")
  }

  private static func track(_ title: String, in index: LibraryIndex) throws -> Track {
    guard let track = index.tracks.first(where: { $0.title == title }) else {
      throw Failure(description: "Missing track: \(title)")
    }
    return track
  }
}
