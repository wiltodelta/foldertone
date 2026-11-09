import SwiftUI
import UniformTypeIdentifiers

enum Palette {
  static let accent = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.72, green: 0.64, blue: 1, alpha: 1)
        : UIColor(red: 0.39, green: 0.27, blue: 0.82, alpha: 1)
    })
  static let button = Color(red: 0.39, green: 0.27, blue: 0.82)
  static let background = Color(uiColor: .systemGroupedBackground)
  static let secondaryText = Color(uiColor: .label).opacity(0.72)
}

extension View {
  fileprivate func modeIndicator(_ active: Bool) -> some View {
    overlay(alignment: .bottom) {
      if active {
        Circle().fill(Color(uiColor: .label)).frame(width: 6, height: 6).offset(y: 8)
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder
  fileprivate func musicGlassButton(prominent: Bool = false) -> some View {
    if #available(iOS 26, *) {
      if prominent {
        buttonStyle(.glassProminent).tint(Palette.button)
      } else {
        buttonStyle(.glass)
      }
    } else if prominent {
      buttonStyle(.borderedProminent).tint(Palette.button)
    } else {
      buttonStyle(.bordered)
    }
  }

  @ViewBuilder
  fileprivate func musicGlassSurface(cornerRadius: CGFloat) -> some View {
    if #available(iOS 26, *) {
      glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    } else {
      background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(.primary.opacity(0.05)))
    }
  }

  @ViewBuilder
  fileprivate func musicGlassGroup(spacing: CGFloat) -> some View {
    if #available(iOS 26, *) {
      GlassEffectContainer(spacing: spacing) { self }
    } else {
      self
    }
  }
}

private enum AppLinks {
  static let privacy = URL(string: "https://wiltodelta.com/projects/foldertone/privacy/")!
  static let support = URL(string: "https://wiltodelta.com/projects/foldertone/support/")!
}

struct LibraryView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var library: MusicLibrary
  let player: MusicPlayer
  @State private var choosingMusic = false
  @State private var showingPlayer = false
  @State private var query = ""
  @AppStorage("selectedPlaylistID") private var selectedPlaylistID = ""
  @State private var managingSources = false
  @State private var pendingPlaybackPath: String?

  private var selectedPlaylist: Playlist? {
    library.playlists.first { $0.id == selectedPlaylistID }
  }

  private var playbackContext: PlaybackContext {
    guard query.isEmpty else { return .selection }
    if let playlist = selectedPlaylist { return .playlist(playlist.id) }
    return .library
  }

  private var playlistTracks: [Track] {
    guard let playlist = selectedPlaylist else { return library.tracks }
    return library.tracks.filter { playlist.trackIDs.contains($0.id) }
  }

  private var filtered: [Track] {
    guard !query.isEmpty else { return playlistTracks }
    return playlistTracks.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.artist.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          if library.tracks.isEmpty && library.playlists.isEmpty { emptyLibrary } else { trackList }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 28)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
      }
      .background(Palette.background)
      .navigationTitle("Foldertone")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if !library.connections.isEmpty {
            Button("Sources", systemImage: "folder") { managingSources = true }
              .accessibilityIdentifier("sourceSettings")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Add from Files", systemImage: "plus") { choosingMusic = true }
            .accessibilityHint("Choose audio files or folders from Files")
            .accessibilityIdentifier("addMusic")
        }
      }
      .searchable(
        text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
        prompt: "Find a song or artist"
      )
      .scrollDismissesKeyboard(.interactively)
      .refreshable { await library.refresh() }
      .safeAreaInset(edge: .bottom) {
        if let track = player.current {
          MiniPlayer(player: player, track: track) { showingPlayer = true }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
      }
      .fileImporter(
        isPresented: $choosingMusic, allowedContentTypes: [.folder, .audio],
        allowsMultipleSelection: true
      ) { result in
        do { openSelection(try result.get()) } catch {
          library.errorMessage = error.localizedDescription
        }
      }
      .onOpenURL { url in
        if url.isFileURL { openSelection([url]) }
      }
      .task {
        #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--sample-file") {
            do {
              let folder = try SampleLibrary.create()
              openSelection([folder.appendingPathComponent("01 - Slow morning.wav")])
            } catch { library.errorMessage = error.localizedDescription }
          }
        #endif
      }
      .sheet(isPresented: $showingPlayer) { PlayerView(player: player) }
      .sheet(isPresented: $managingSources) { SourceManagerView(library: library) }
      .onChange(of: library.playlists.map(\.id), initial: true) {
        if !selectedPlaylistID.isEmpty && selectedPlaylist == nil { selectedPlaylistID = "" }
      }
      .onChange(of: library.tracks) { playPendingSelection() }
      .onChange(of: player.current?.id) {
        if player.current == nil { showingPlayer = false }
      }
      .alert(
        "Could not update library",
        isPresented: Binding(
          get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } }
        )
      ) {
        Button("OK") { library.errorMessage = nil }
      } message: {
        Text(library.errorMessage ?? "")
      }
      .alert(
        "Could not play track",
        isPresented: Binding(
          get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } }
        )
      ) {
        Button("OK") { player.errorMessage = nil }
      } message: {
        Text(player.errorMessage ?? "")
      }
    }
    .tint(Palette.accent)
  }

  private var emptyLibrary: some View {
    VStack(spacing: 22) {
      RecordArtwork().frame(width: 168, height: 168).padding(.top, 30)
      VStack(spacing: 10) {
        Text(library.sourceSummary ?? "A home for your music.")
          .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
        Text(
          library.sourceSummary == nil
            ? "Choose a folder to make a playlist,\nor open a song to start listening."
            : library.status
        )
        .font(.body).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)
      }
      Button(
        library.sourceSummary == nil ? "Choose files or folders" : "Retry",
        systemImage: library.sourceSummary == nil ? "folder" : "arrow.clockwise"
      ) {
        if library.sourceSummary == nil {
          choosingMusic = true
        } else {
          Task { await library.refresh() }
        }
      }
      .font(.headline).musicGlassButton(prominent: true).buttonBorderShape(.capsule)
      .controlSize(.large).disabled(library.isRefreshing)
      Link("Privacy Policy", destination: AppLinks.privacy)
        .font(.footnote).accessibilityIdentifier("privacyPolicy")
    }
    .frame(maxWidth: .infinity).padding(.bottom, 24)
  }

  private var trackList: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Menu {
          Picker("Playlist", selection: $selectedPlaylistID) {
            Text("All music").tag("")
            ForEach(library.playlists) { playlist in
              Text(playlist.name).tag(playlist.id)
            }
          }.pickerStyle(.inline)
          Divider()
          Button("Manage Sources", systemImage: "folder.badge.gearshape") {
            managingSources = true
          }
          .accessibilityIdentifier("manageSources")
        } label: {
          HStack(spacing: 6) {
            Text(selectedPlaylist?.name ?? "All music").font(.headline).lineLimit(
              dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
          }.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .buttonStyle(.plain).musicGlassSurface(cornerRadius: 24)
        .foregroundStyle(.primary)
        .accessibilityLabel("Playlist")
        .accessibilityValue(selectedPlaylist?.name ?? "All music")
        .accessibilityIdentifier("playlistPicker")
        Text("\(playlistTracks.count)").font(.subheadline.monospacedDigit()).foregroundStyle(
          Palette.secondaryText)
        Spacer()
      }
      HStack(spacing: 8) {
        if library.isRefreshing { ProgressView().controlSize(.mini) }
        Text(library.status).font(.caption).foregroundStyle(Palette.secondaryText)
      }
      let actionLayout =
        dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
      actionLayout {
        Button("Play all", systemImage: "play.fill") {
          if let first = filtered.first {
            player.play(first, in: filtered, context: playbackContext)
          }
        }
        .frame(maxWidth: .infinity).musicGlassButton(prominent: true)
        .accessibilityIdentifier("playAll")
        Button("Shuffle", systemImage: "shuffle") {
          player.shufflePlay(filtered, context: playbackContext)
        }
        .frame(maxWidth: .infinity).musicGlassButton()
        .accessibilityIdentifier("shuffleAll")
      }
      .font(.subheadline.weight(.semibold)).buttonBorderShape(.capsule).disabled(filtered.isEmpty)
      .musicGlassGroup(spacing: 12)
      LazyVStack(spacing: 0) {
        ForEach(filtered) { track in
          Button {
            player.play(track, in: filtered, context: playbackContext)
          } label: {
            TrackRow(
              track: track,
              currentSymbol: player.current?.id == track.id
                ? (player.isPlaying ? "waveform" : "pause.fill") : nil
            )
            .padding(.vertical, 11).contentShape(.rect)
          }
          .buttonStyle(.plain).accessibilityIdentifier("track-\(track.title)")
        }
      }
      if filtered.isEmpty {
        if query.isEmpty && selectedPlaylist != nil {
          ContentUnavailableView(
            "This playlist is empty", systemImage: "music.note.list",
            description: Text("Add audio files anywhere in its folder."))
        } else {
          ContentUnavailableView.search(text: query)
        }
      }
    }
  }
  private func openSelection(_ urls: [URL]) {
    do {
      let previous = Set(library.playlists.map(\.id))
      let singleFile = try library.addSources(urls)
      pendingPlaybackPath = singleFile.map { LibraryStorage.path($0) }
      selectedPlaylistID = library.playlists.last { !previous.contains($0.id) }?.id ?? ""
      Task {
        await library.refresh()
        playPendingSelection()
      }
    } catch { library.errorMessage = error.localizedDescription }
  }

  private func playPendingSelection() {
    guard let path = pendingPlaybackPath,
      let track = library.tracks.first(where: { $0.sourcePath == path })
    else { return }
    pendingPlaybackPath = nil
    player.play(track, in: [track])
  }
}

struct RecordArtwork: View {
  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / 168
      ZStack {
        RoundedRectangle(cornerRadius: 36 * scale).fill(
          LinearGradient(
            colors: [
              Color(red: 0.79, green: 0.75, blue: 0.95), Color(red: 0.60, green: 0.55, blue: 0.82),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        Circle().fill(Color(white: 0.13)).padding(22 * scale)
        ForEach(0..<5) { index in
          Circle().stroke(.white.opacity(0.10), lineWidth: 1).padding(
            CGFloat(28 + index * 7) * scale)
        }
        Circle().fill(Color(red: 0.81, green: 0.91, blue: 0.63)).padding(62 * scale)
        Circle().fill(Color(white: 0.13)).padding(79 * scale)
      }
    }
    .accessibilityHidden(true)
  }
}

struct TrackArtwork: View {
  var track: Track?
  var large = false
  @State private var artwork: UIImage?

  var body: some View {
    ZStack {
      if let artwork {
        Image(uiImage: artwork).resizable().scaledToFill()
      } else if large {
        RecordArtwork()
      } else {
        RoundedRectangle(cornerRadius: 12).fill(Palette.accent.opacity(0.12))
        Image(systemName: "music.note").font(.title3).foregroundStyle(Palette.accent)
      }
    }
    .clipShape(.rect(cornerRadius: large ? 32 : 12)).accessibilityHidden(true)
    .task(id: track?.artworkFilename) {
      artwork = nil
      guard let filename = track?.artworkFilename else { return }
      let url = LibraryStorage.directory.appendingPathComponent(filename)
      let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
      guard !Task.isCancelled else { return }
      artwork = data.flatMap { UIImage(data: $0) }
    }
  }
}

struct TrackRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let track: Track
  var currentSymbol: String? = nil

  var body: some View {
    HStack(spacing: 14) {
      if !dynamicTypeSize.isAccessibilitySize {
        TrackArtwork(track: track).frame(width: 52, height: 52).accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(track.title).font(.body.weight(.medium)).foregroundStyle(.primary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        Text(track.artist).font(.subheadline).foregroundStyle(Palette.secondaryText)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        if dynamicTypeSize.isAccessibilitySize {
          Text(track.duration.clockText).font(.caption.monospacedDigit()).foregroundStyle(
            Palette.secondaryText)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let currentSymbol {
        Image(systemName: currentSymbol).foregroundStyle(Palette.accent)
          .accessibilityLabel("Current track")
      } else if !dynamicTypeSize.isAccessibilitySize {
        Text(track.duration.clockText).font(.caption.monospacedDigit()).foregroundStyle(
          Palette.secondaryText)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct MiniPlayer: View {
  let player: MusicPlayer
  let track: Track
  let open: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: open) {
        HStack(spacing: 12) {
          TrackArtwork(track: track).frame(width: 44, height: 44)
          VStack(alignment: .leading, spacing: 3) {
            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(player.isLoading ? "Loading…" : track.artist).font(.caption).foregroundStyle(
              Palette.secondaryText
            ).lineLimit(1)
          }
          Spacer(minLength: 0)
        }.contentShape(.rect)
      }
      .buttonStyle(.plain).accessibilityIdentifier("openPlayer")
      Button(
        player.isPlaying ? "Pause" : "Play",
        systemImage: player.isPlaying ? "pause.fill" : "play.fill"
      ) { player.toggle() }
      .labelStyle(.iconOnly).font(.title3).frame(width: 44, height: 44)
      .accessibilityIdentifier("miniPlayPause")
      Button("Next track", systemImage: "forward.end.fill") { player.next() }
        .labelStyle(.iconOnly).frame(width: 44, height: 44)
    }
    .padding(12).musicGlassSurface(cornerRadius: 28)
  }
}

struct PlayerView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let player: MusicPlayer
  @Environment(\.dismiss) private var dismiss
  @State private var scrubPosition = 0.0
  @State private var isScrubbing = false
  @State private var showingQueue = false

  private func transportControls(compact: Bool = false) -> some View {
    let layout =
      compact ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 16))
    return layout {
      HStack(spacing: compact ? 16 : 36) {
        Button {
          player.previous()
        } label: {
          Label("Previous track", systemImage: "backward.end.fill")
            .font(.title2).frame(width: 32, height: 32)
        }
        .musicGlassButton().buttonBorderShape(.circle)
        Button {
          player.toggle()
        } label: {
          Label(
            player.isPlaying ? "Pause" : "Play",
            systemImage: player.isPlaying ? "pause.fill" : "play.fill"
          ).font(.title).frame(width: compact ? 40 : 64, height: compact ? 40 : 64)
        }
        .musicGlassButton(prominent: true).buttonBorderShape(.circle)
        .accessibilityIdentifier("playerPlayPause")
        Button {
          player.next()
        } label: {
          Label("Next track", systemImage: "forward.end.fill")
            .font(.title2).frame(width: 32, height: 32)
        }
        .musicGlassButton().buttonBorderShape(.circle)
        .accessibilityIdentifier("playerNext")
      }.labelStyle(.iconOnly)
      HStack {
        Button {
          player.toggleShuffle()
        } label: {
          Label("Shuffle", systemImage: "shuffle").modeIndicator(player.isShuffled)
        }
        .frame(width: 44, height: 44)
        .foregroundStyle(player.isShuffled ? Palette.accent : Palette.secondaryText)
        .accessibilityValue(player.isShuffled ? "On" : "Off")
        .accessibilityIdentifier("toggleShuffle")
        Spacer()
        Button("Up next", systemImage: "list.bullet") { showingQueue = true }.frame(
          width: 44, height: 44)
        Spacer()
        Button {
          player.cycleRepeat()
        } label: {
          Label("Repeat", systemImage: player.repeatMode == .track ? "repeat.1" : "repeat")
            .modeIndicator(player.repeatMode != .off)
        }
        .foregroundStyle(player.repeatMode == .off ? Palette.secondaryText : Palette.accent)
        .accessibilityValue(player.repeatMode.rawValue)
        .accessibilityIdentifier("cycleRepeat")
        .frame(width: 44, height: 44)
      }
      .labelStyle(.iconOnly).font(.title3)
      .musicGlassButton().buttonBorderShape(.circle).controlSize(.large)
      .frame(maxWidth: compact ? 180 : .infinity)
    }
    .musicGlassGroup(spacing: 16)
    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    .frame(maxWidth: 520).frame(maxWidth: .infinity)
    .padding(.horizontal, compact ? 0 : 32).padding(.top, 12).padding(.bottom, 16)
    .background(Palette.background)
  }

  private var trackMetadata: some View {
    VStack(spacing: 8) {
      Text(player.current?.title ?? "").font(.title.weight(.bold)).multilineTextAlignment(
        .center)
      Text(player.current?.artist ?? "").font(.body).foregroundStyle(Palette.secondaryText)
      if let album = player.current?.album, !album.isEmpty {
        Text(album).font(.subheadline).foregroundStyle(Palette.secondaryText)
      }
    }
  }

  private var timeline: some View {
    VStack(spacing: 4) {
      Slider(
        value: Binding(
          get: { isScrubbing ? scrubPosition : player.elapsed }, set: { scrubPosition = $0 }
        ),
        in: 0...max(player.current?.duration ?? 0, 1),
        onEditingChanged: { editing in
          if editing {
            scrubPosition = player.elapsed
          } else {
            player.seek(to: scrubPosition)
          }
          isScrubbing = editing
        }
      ).accessibilityLabel("Playback position")
      HStack {
        Text((isScrubbing ? scrubPosition : player.elapsed).clockText)
        Spacer()
        Text((player.current?.duration ?? 0).clockText)
      }.font(.caption.monospacedDigit()).foregroundStyle(Palette.secondaryText)
    }
  }

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let coverSize =
          dynamicTypeSize.isAccessibilitySize
          ? 120
          : min(
            320, max(120, min(geometry.size.width - 64, geometry.size.height * 0.34)))
        if geometry.size.width > geometry.size.height {
          HStack(spacing: 24) {
            if !dynamicTypeSize.isAccessibilitySize && geometry.size.width >= 700 {
              TrackArtwork(track: player.current, large: true)
                .frame(
                  width: min(180, geometry.size.height * 0.65),
                  height: min(180, geometry.size.height * 0.65)
                )
                .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
              ScrollView {
                VStack(spacing: 16) {
                  trackMetadata
                  timeline
                }
                .frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 16)
              }
              transportControls(compact: true)
            }
          }.padding(.horizontal, 24)
        } else {
          ScrollView {
            VStack(spacing: 24) {
              TrackArtwork(track: player.current, large: true)
                .frame(width: coverSize, height: coverSize).padding(.top, 16)
                .accessibilityHidden(true)
              trackMetadata
              timeline
            }
            .padding(.horizontal, 32).padding(.bottom, 24)
            .frame(maxWidth: 520).frame(maxWidth: .infinity)
          }
          .safeAreaInset(edge: .bottom, spacing: 0) { transportControls() }
        }
      }
      .background(Palette.background)
      .navigationTitle("Now playing").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
        }
      }
    }
    .sheet(isPresented: $showingQueue) {
      NavigationStack {
        List(player.upNext) { track in
          Button {
            player.playQueued(track)
            showingQueue = false
          } label: {
            TrackRow(track: track).padding(.vertical, 4)
          }
          .buttonStyle(.plain)
        }
        .overlay {
          if player.upNext.isEmpty {
            ContentUnavailableView("You’re all caught up", systemImage: "music.note.list")
          }
        }
        .navigationTitle("Up next")
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingQueue = false } }
        }
      }
    }
    .tint(Palette.accent)
  }
}

extension Double {
  var clockText: String {
    let seconds = isFinite ? max(0, Int(self)) : 0
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

struct SourceManagerView: View {
  let library: MusicLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var editing: MusicSource?
  @State private var reconnecting: MusicSource?
  @State private var choosingReplacement = false
  @State private var disconnecting: MusicSource?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(library.connections) { source in
            VStack(alignment: .leading, spacing: 12) {
              Label(source.name, systemImage: source.isFolder ? "folder" : "music.note")
                .font(.headline).foregroundStyle(.primary)
              ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { sourceActions(source) }
                VStack(alignment: .leading, spacing: 12) { sourceActions(source) }
              }
              .font(.subheadline)
              .buttonStyle(.borderless)
            }.padding(.vertical, 8)
          }
        } footer: {
          Text(
            "Folders become playlists. Disconnecting a source leaves its original files in Files.")
        }
        .disabled(library.isRefreshing)
        Section {
          Link("Privacy Policy", destination: AppLinks.privacy)
          Link("Support", destination: AppLinks.support)
        }
      }
      .navigationTitle("Sources")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .sheet(item: $editing) { source in RenameSourceView(library: library, source: source) }
    .fileImporter(
      isPresented: $choosingReplacement,
      allowedContentTypes: reconnecting?.isFolder == true ? [.folder] : [.audio]
    ) { result in
      guard let source = reconnecting else { return }
      reconnecting = nil
      switch result {
      case .success(let url):
        Task {
          do { try await library.reconnectSource(id: source.id, to: url) } catch {
            errorMessage = error.localizedDescription
          }
        }
      case .failure(let error):
        if (error as NSError).code != NSUserCancelledError {
          errorMessage = error.localizedDescription
        }
      }
    }
    .confirmationDialog(
      "Disconnect source?",
      isPresented: Binding(
        get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
      titleVisibility: .visible
    ) {
      if let source = disconnecting {
        Button("Disconnect \(source.name)", role: .destructive) {
          disconnecting = nil
          Task {
            do { try await library.disconnectSource(id: source.id) } catch {
              errorMessage = error.localizedDescription
            }
          }
        }
      }
      Button("Cancel", role: .cancel) { disconnecting = nil }
    } message: {
      Text(
        "This removes the source and its unshared tracks from Foldertone. Original files stay in Files."
      )
    }
    .alert(
      "Could not update source",
      isPresented: Binding(
        get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .tint(Palette.accent)
  }

  @ViewBuilder private func sourceActions(_ source: MusicSource) -> some View {
    Button("Rename") { editing = source }.frame(minHeight: 44)
    Button("Reconnect in Files") {
      reconnecting = source
      choosingReplacement = true
    }.frame(minHeight: 44)
    Button("Disconnect", role: .destructive) { disconnecting = source }.frame(minHeight: 44)
  }
}

struct RenameSourceView: View {
  let library: MusicLibrary
  let source: MusicSource
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var errorMessage: String?

  init(library: MusicLibrary, source: MusicSource) {
    self.library = library
    self.source = source
    _name = State(initialValue: source.name)
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $name)
        Text("Only the name in Foldertone changes. The folder or file keeps its name in Files.")
          .foregroundStyle(Palette.secondaryText)
      }
      .navigationTitle("Rename Source")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try library.renameSource(id: source.id, name: name)
              dismiss()
            } catch { errorMessage = error.localizedDescription }
          }
          .disabled(
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isRefreshing)
        }
      }
      .alert(
        "Could not rename source",
        isPresented: Binding(
          get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
    }.tint(Palette.accent)
  }
}
