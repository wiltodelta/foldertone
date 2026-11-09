import Foundation

enum PlaybackContext {
  case selection
  case library
  case playlist(String)
}

enum RepeatMode: String, CaseIterable {
  case off, playlist, track

  var next: RepeatMode {
    switch self {
    case .off: .playlist
    case .playlist: .track
    case .track: .off
    }
  }
}

struct PlaybackQueue {
  private(set) var ordered: [Track] = []
  private(set) var tracks: [Track] = []
  private(set) var isShuffled = false

  mutating func begin(_ tracks: [Track], starting track: Track, shuffled: Bool) {
    ordered = tracks
    isShuffled = shuffled
    self.tracks = shuffled ? [track] + tracks.filter { $0.id != track.id }.shuffled() : tracks
  }

  mutating func toggleShuffle(keeping currentID: String) {
    isShuffled.toggle()
    guard isShuffled, let index = tracks.firstIndex(where: { $0.id == currentID }) else {
      tracks = ordered
      return
    }
    let history = Array(tracks.prefix(index + 1))
    let visited = Set(history.map(\.id))
    tracks = history + ordered.filter { !visited.contains($0.id) }.shuffled()
  }

  mutating func reconcile(with updated: [Track]) {
    ordered = updated
    if isShuffled {
      let catalog = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      tracks = tracks.compactMap { catalog[$0.id] }
      let known = Set(tracks.map(\.id))
      tracks += updated.filter { !known.contains($0.id) }.shuffled()
    } else {
      tracks = updated
    }
  }

  func next(after id: String, automatically: Bool, repeatMode: RepeatMode) -> Track? {
    guard let index = tracks.firstIndex(where: { $0.id == id }) else { return nil }
    if automatically && repeatMode == .track { return tracks[index] }
    if index + 1 < tracks.count { return tracks[index + 1] }
    return repeatMode == .playlist ? tracks.first : nil
  }

  func previous(before id: String) -> Track? {
    guard let index = tracks.firstIndex(where: { $0.id == id }) else { return nil }
    return tracks[max(0, index - 1)]
  }
}
