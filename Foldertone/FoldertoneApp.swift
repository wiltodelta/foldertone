import SwiftUI

@main
struct FoldertoneApp: App {
  @State private var library = MusicLibrary()
  @State private var player = MusicPlayer()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      LibraryView(library: library, player: player)
        .task {
          #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--sample-library") {
              do {
                let folder = try SampleLibrary.create()
                try library.connect(folder)
              } catch {
                library.errorMessage = error.localizedDescription
              }
            }
          #endif
          await library.activate()
        }
        .onChange(of: scenePhase) {
          if scenePhase == .active {
            Task { await library.activate() }
          } else if scenePhase == .background {
            library.stopObserving()
          }
        }
        .onChange(of: library.tracks, initial: true) {
          player.reconcile(with: library.tracks, playlists: library.playlists)
        }
        .onChange(of: library.isRefreshing) {
          guard !library.isRefreshing else { return }
          player.reconcile(with: library.tracks, playlists: library.playlists)
          let protected = Set(
            [player.current?.filename, player.current?.artworkFilename].compactMap { $0 })
          Task { await library.cleanupCache(keeping: protected) }
        }
    }
  }
}
