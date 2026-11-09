Act as a principal iOS engineer building Foldertone, a music player for files and folders selected through iOS Files.

## Project scope

- Read `README.md` for the product goal and initial scope.
- Open `Foldertone.xcodeproj`, scheme `Foldertone`. The deployment target is iOS 17.0; there are no external dependencies.
- `FolderImporter` persists per-source synchronization snapshots and coordinates read-only access. `MusicLibrary` owns observable library state; `MusicPlayer` owns AVPlayer and remote commands.
- Follow `docs/product.md` for folder playlists, single-file playback, metadata, and queue behavior.
- Follow `~/Documents/GitHub/claude-config/docs/ios-apps.md` for the shared native iOS appearance and accessibility conventions.
- Follow `docs/release.md` for App Store releases; keep `Foldertone/PrivacyInfo.xcprivacy` and `docs/privacy.md` true to the code.
- Use the checks in `README.md`; `scripts/check-engine.sh` runs shared scenarios in an isolated temporary home. Sample playback hooks are Debug-only; codec fixtures are synthetic.
- Preserve the one-screen library and native multi-selection file and folder picker. Keep file presenters active only in the foreground; background audio is separate. Use events and foreground reconciliation rather than periodic polling.
- Validate file and folder permissions across Files providers, cloud downloads, and physical playback controls on an iPhone; simulator success does not prove these behaviors.
- `scripts/draw-icon.py` generates `Foldertone/AppIcon.icon`; change its geometry and appearance in the generator, never in the generated layers.
