# AutoQuit architecture

## What this is

AutoQuit is a **macOS menu bar app** (not iOS) that automatically quits apps which have been idle longer than a configurable threshold (default 8h). It lives in the menu bar only (`LSUIElement = YES`, no Dock icon) via SwiftUI's `MenuBarExtra`. Each running app shows a countdown and a per-app opt-out checkbox.

## Build & run

Open `AutoQuit.xcodeproj` in Xcode (scheme `AutoQuit`), or from CLI:

```bash
# Build (DEVELOPMENT_TEAM is blank, so a CLI build needs signing disabled)
xcodebuild -project AutoQuit.xcodeproj -scheme AutoQuit -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO

# Test the logic suite (single test: append /AutoQuitTests/testName)
xcodebuild test -project AutoQuit.xcodeproj -scheme AutoQuit \
  -destination 'platform=macOS' -only-testing:AutoQuitTests CODE_SIGNING_ALLOWED=NO
```

- Target: macOS 13.0+, Swift 5.0, bundle id `com.AutoQuit`.
- `Info.plist` is empty on disk — keys are generated from build settings (`GENERATE_INFOPLIST_FILE = YES`). Edit Info keys in the target build settings, not the plist.
- `AutoQuitTests` covers the pure logic — `QuitDecision.shouldQuit` (idle/opt-out/launch boundaries) and `IdleTime` formatting (locale pinned to `en_US` so the asserted strings don't depend on the host locale). The UI-test targets are still Xcode-template stubs, and their runner can't launch unsigned — that's why the test command scopes to `-only-testing:AutoQuitTests`.

## Architecture

Almost everything lives in **`ContentView.swift`**; `AutoQuitApp.swift` is just the `@main` shell.

- **Single global manager.** `AutoQuitApp.swift` creates one file-scope `let runningAppsManager = RunningAppsManager()` and injects it into every view. There is no DI — this global is the source of truth.

- **`RunningAppsManager` (`ObservableObject`) is the whole engine** (`ContentView.swift:31`):
  - `runningApps: [NSRunningApplication: Date]` maps each app to its **last-active timestamp**. An app is quit when `now - timestamp > hoursUntilClose`.
  - A 1-second `Timer` calls `checkOpenApps()` (`ContentView.swift:172`) — but only when one of the app's windows is key/main, or at least once every 60s otherwise (tracked via `lastChecked`). This keeps the countdown UI live while the menu is open without polling constantly in the background. **This is the core loop; the terminate decision is here.**
  - Subscribes to `NSWorkspace.didDeactivateApplicationNotification` to stamp the moment an app loses focus.
  - `isBlockedApp()` excludes background/menu-bar-only apps (`activationPolicy != .regular`), AutoQuit itself, and a hardcoded list of Apple system bundle ids (Finder, Dock, Spotlight, Siri, etc.). This is what the CHANGELOG fixes refer to — apps like Bartender/CleanShot were wrongly terminated before this filter.

- **Opt-out is keyed by `bundleIdentifier`** (falling back to `localizedName`, then `""`) via `NSRunningApplication.toggleKey`. Reads (`willAutoQuit`) also check a legacy `localizedName` key so opt-outs saved before this change still apply. `toggleStatus: [String: Bool]` is JSON-encoded into an `@AppStorage` `Data` blob (`com.AutoQuit.toggleStatus`). Mutating `toggleStatus` **auto-persists** via its `didSet` (which calls `saveToggleStatus()`) — callers no longer invoke `saveToggleStatus()` by hand.

- **Settings** open in a separate `NSWindow` managed by `SettingsWindowController`, a singleton tracked via its static `.current` so a second click re-focuses the existing window instead of opening another.

- **Popover footer bulk actions.** *Close all selected* / *Force close all selected* (above *Settings* in the footer) terminate every app whose toggle is on — `runningApps.keys` filtered by `willAutoQuit` — via `terminate()` / `forceTerminate()`, the same calls the per-row buttons use. No manual cleanup: the 1s timer prunes apps once they've quit. Both disable when nothing is selected.

## Persistence

All state is `@AppStorage` (UserDefaults): `hoursUntilClose: Int`, `showCloseButton: Bool`, and the encoded `toggleStatus` blob.

The default for `hoursUntilClose` lives in one place — `AppDefaults.hoursUntilClose` (8) — and every `@AppStorage("hoursUntilClose")` declaration (manager, `AppRow`, `SettingsView`) references it, so the defaults can't drift apart.

## Dependencies

None. Launch-at-login is handled by `LaunchAtLoginToggle` (`ContentView.swift`), a small native wrapper around `SMAppService.mainApp` (ServiceManagement, macOS 13+). This replaced the former `LaunchAtLogin-Modern` SPM package.
