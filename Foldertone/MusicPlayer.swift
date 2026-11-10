import AVFoundation
import MediaPlayer
import OSLog
import Observation
import UIKit

@MainActor @Observable
final class MusicPlayer {
  private(set) var current: Track?
  private(set) var isPlaying = false
  private(set) var isLoading = false
  private(set) var elapsed: Double = 0
  var errorMessage: String?
  @ObservationIgnored private let player = AVPlayer()
  private(set) var queue = PlaybackQueue()
  private(set) var repeatMode = RepeatMode.off
  @ObservationIgnored private var context = PlaybackContext.selection
  @ObservationIgnored private var timer: Any?
  @ObservationIgnored private var observation: NSKeyValueObservation?
  @ObservationIgnored private var itemObservation: NSKeyValueObservation?
  @ObservationIgnored private var endObserver: NSObjectProtocol?
  @ObservationIgnored private let log = Logger(subsystem: "app.foldertone", category: "Playback")

  init() {
    observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      let status = player.timeControlStatus
      Task { @MainActor in
        self?.isPlaying = status == .playing
        self?.isLoading = status == .waitingToPlayAtSpecifiedRate
        self?.updateNowPlaying()
      }
    }
    timer = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      Task { @MainActor in
        self?.elapsed = time.seconds.isFinite ? time.seconds : 0
        self?.updateNowPlaying()
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] note in
      guard let item = note.object as? AVPlayerItem else { return }
      Task { @MainActor in
        guard let self, item === self.player.currentItem else { return }
        self.next(automatically: true)
      }
    }
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.resume() }
      return .success
    }
    commands.pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.pause() }
      return .success
    }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.toggle() }
      return .success
    }
    commands.nextTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.next() }
      return .success
    }
    commands.previousTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.previous() }
      return .success
    }
    commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      let position = event.positionTime
      Task { @MainActor in self?.seek(to: position) }
      return .success
    }
  }

  var isShuffled: Bool { queue.isShuffled }
  var upNext: [Track] {
    guard let current, let index = queue.tracks.firstIndex(where: { $0.id == current.id }) else {
      return []
    }
    return Array(queue.tracks.dropFirst(index + 1))
  }

  func play(_ track: Track, in tracks: [Track], context: PlaybackContext = .selection) {
    self.context = context
    queue.begin(tracks, starting: track, shuffled: false)
    start(track)
  }

  /// Plays every track in the order mode last chosen in the player.
  func playAll(_ tracks: [Track], context: PlaybackContext = .selection) {
    let shuffled = queue.isShuffled
    guard let first = shuffled ? tracks.randomElement() : tracks.first else { return }
    self.context = context
    queue.begin(tracks, starting: first, shuffled: shuffled)
    start(first)
  }

  func toggleShuffle() {
    guard let current else { return }
    queue.toggleShuffle(keeping: current.id)
  }

  func cycleRepeat() { repeatMode = repeatMode.next }
  func playQueued(_ track: Track) { start(track) }

  private func start(_ track: Track) {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
      try AVAudioSession.sharedInstance().setActive(true)
      current = track
      elapsed = 0
      errorMessage = nil
      let item = AVPlayerItem(url: track.url)
      itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        guard item.status == .failed else { return }
        let message = item.error?.localizedDescription ?? "This audio file could not be played."
        Task { @MainActor in
          self?.log.error("Audio item failed: \(message, privacy: .public)")
          self?.errorMessage = message
        }
      }
      player.replaceCurrentItem(with: item)
      player.play()
      updateNowPlaying()
    } catch {
      log.error("Playback failed: \(error, privacy: .public)")
      errorMessage = error.localizedDescription
    }
  }

  func toggle() { player.rate == 0 ? resume() : pause() }
  func reconcile(with tracks: [Track], playlists: [Playlist] = []) {
    let catalog = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    switch context {
    case .library:
      queue.reconcile(with: tracks)
    case .playlist(let id):
      let ids = playlists.first(where: { $0.id == id })?.trackIDs ?? []
      queue.reconcile(with: tracks.filter { ids.contains($0.id) })
    case .selection:
      queue.reconcile(with: queue.ordered.compactMap { catalog[$0.id] })
    }
    guard let current else { return }
    guard let updated = catalog[current.id], queue.tracks.contains(where: { $0.id == current.id })
    else {
      player.pause()
      player.replaceCurrentItem(with: nil)
      itemObservation = nil
      self.current = nil
      elapsed = 0
      isPlaying = false
      isLoading = false
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        log.warning(
          "Deactivating the removed track's audio session failed: \(error, privacy: .public)")
      }
      return
    }
    if updated.filename != current.filename {
      let wasPlaying = player.rate != 0 || isLoading
      let position = elapsed
      start(updated)
      seek(to: position)
      if !wasPlaying { pause() }
    } else {
      self.current = updated
      updateNowPlaying()
    }
  }
  func pause() { player.pause() }
  func resume() {
    guard let current else { return }
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      if elapsed >= current.duration - 0.5 { seek(to: 0) }
      player.play()
    } catch {
      log.error("Resuming playback failed: \(error, privacy: .public)")
      errorMessage = error.localizedDescription
    }
  }
  func seek(to seconds: Double) {
    player.seek(
      to: CMTime(seconds: max(0, min(seconds, current?.duration ?? 0)), preferredTimescale: 600))
  }
  func next(automatically: Bool = false) {
    guard let current else { return }
    if let next = queue.next(
      after: current.id, automatically: automatically, repeatMode: repeatMode)
    {
      start(next)
    } else {
      pause()
    }
  }
  func previous() {
    guard let current else { return }
    if elapsed > 3 {
      seek(to: 0)
    } else if let previous = queue.previous(before: current.id) {
      start(previous)
    }
  }
  @ObservationIgnored private var cachedArtworkFilename: String?
  @ObservationIgnored private var cachedArtwork: MPMediaItemArtwork?

  private func updateNowPlaying() {
    guard let current else { return }
    if current.artworkFilename != cachedArtworkFilename {
      cachedArtworkFilename = current.artworkFilename
      cachedArtwork = nil
      if let name = current.artworkFilename,
        let image = UIImage(
          contentsOfFile: LibraryStorage.directory.appendingPathComponent(name).path)
      {
        cachedArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
    }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: current.title,
      MPMediaItemPropertyArtist: current.artist,
      MPMediaItemPropertyPlaybackDuration: current.duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
      MPNowPlayingInfoPropertyPlaybackRate: player.rate,
    ]
    if let album = current.album { info[MPMediaItemPropertyAlbumTitle] = album }
    if let artwork = cachedArtwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }
}
