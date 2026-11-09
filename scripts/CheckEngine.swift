import Darwin
import Foundation

@main struct RunScenarios {
  @MainActor static func main() async {
    do {
      guard CommandLine.arguments.count >= 2 else {
        throw SyncScenarios.Failure(description: "An isolated test directory is required")
      }
      let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path
      guard URL.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(root + "/")
      else {
        throw SyncScenarios.Failure(description: "Unsafe host test storage")
      }
      let cases: [(String, @MainActor () async throws -> Void)] = [
        ("events", { try await SyncScenarios.eventDrivenChanges() }),
        ("formats", { try await SyncScenarios.formatsAndMetadata() }),
        ("queue", { try SyncScenarios.playbackOrder() }),
        ("recursive", { try await SyncScenarios.recursiveChanges() }),
        ("unavailable", { try await SyncScenarios.unavailableSource() }),
        ("overlap", { try await SyncScenarios.overlappingSources() }),
        ("legacy", { try await SyncScenarios.legacyIndex() }),
        ("playlists", { try await SyncScenarios.playlistsAndFiles() }),
        ("source-management", { try await SyncScenarios.sourceManagement() }),
        ("cache", { try await SyncScenarios.cacheCleanup() }),
        ("incomplete", { try await SyncScenarios.incompleteEnumeration() }),
      ]
      let selected = CommandLine.arguments.dropFirst(2).first ?? "all"
      guard selected == "all" || cases.contains(where: { $0.0 == selected }) else {
        throw SyncScenarios.Failure(description: "Unknown scenario")
      }
      for (name, operation) in cases where selected == "all" || name == selected {
        try await operation()
        NSLog("PASS %@", name)
      }
    } catch {
      NSLog("FAIL %@", String(describing: error))
      exit(1)
    }
  }
}
