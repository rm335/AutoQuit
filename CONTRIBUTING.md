# Contributing to AutoQuit

Thanks for taking the time. AutoQuit is a small, single-purpose macOS menu bar
app, and the goal is to keep it that way — so the most useful contributions are
focused fixes, small improvements, and translations.

## Ways to help

- **Report a bug** — open an issue with your macOS version, what you did, what
  you expected, and what happened. If an app was quit (or *not* quit) when it
  shouldn't have been, name the app — the skip rules live in `isBlockedApp()`
  and that's usually where the fix goes.
- **Suggest a feature** — open an issue first so we can agree it fits before you
  write code. AutoQuit deliberately stays minimal; see *Scope* below.
- **Add a translation** — strings live in `AutoQuit/Localizable.xcstrings`
  (String Catalog). There's already a Dutch translation to mirror. Open the
  catalog in Xcode, add a language, fill in the values, and submit.
- **Fix code** — see below.

## Building and testing

Full setup is in the [README](README.md); the short version:

```bash
# Build (DEVELOPMENT_TEAM is blank, so a CLI build needs signing disabled)
xcodebuild -project AutoQuit.xcodeproj -scheme AutoQuit -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO

# Run the logic tests — please make sure these pass before opening a PR
xcodebuild test -project AutoQuit.xcodeproj -scheme AutoQuit \
  -destination 'platform=macOS' -only-testing:AutoQuitTests CODE_SIGNING_ALLOWED=NO
```

`AutoQuitTests` covers the pure logic (`QuitDecision.shouldQuit` and `IdleTime`
formatting). The UI-test targets are still Xcode-template stubs and their runner
can't launch unsigned — that's why the command scopes to `-only-testing:AutoQuitTests`.

If you change quit/idle/formatting logic, **add or update a test for it.** Tests
pin the locale to `en_US` so asserted strings don't depend on the host machine —
keep new tests doing the same.

## Code conventions

Read [`ARCHITECTURE.md`](ARCHITECTURE.md) before a non-trivial change — it
explains why things are where they are. In short:

- **Almost all code is in `ContentView.swift`**, driven by a single global
  `RunningAppsManager`. Match the existing structure rather than introducing new
  layers or files unless the change genuinely needs them.
- **Edit Info.plist keys in the target build settings**, not `Info.plist` — the
  plist is generated (`GENERATE_INFOPLIST_FILE = YES`) and empty on disk.
- **Keep the default for `hoursUntilClose` in `AppDefaults`** — every
  `@AppStorage("hoursUntilClose")` references it so the value can't drift.
- **Target is macOS 13.0+ / Swift 5.0.** Don't use newer-only APIs without an
  availability check.

## Scope — what tends to get declined

These keep AutoQuit small, private, and dependency-free, so PRs that break them
are unlikely to merge:

- **No third-party dependencies.** Launch-at-login was deliberately moved off an
  SPM package onto native `SMAppService`. Prefer a few lines of native code.
- **No network, accounts, sync, or telemetry.** "Nothing leaves your Mac" is a
  feature, not an oversight.
- **No scope creep** into a general app/process manager. AutoQuit quits *idle
  regular apps* and stays out of the way otherwise.

If you're unsure whether something fits, open an issue before building it.

## Submitting a pull request

1. Keep PRs small and focused — one logical change each.
2. Reference the issue it addresses.
3. Make sure `AutoQuitTests` passes and the app builds.
4. Describe what changed and why; note anything user-visible for the CHANGELOG.

## License

By contributing, you agree your contributions are licensed under the
[GNU General Public License v3.0](LICENSE), the same license as the project.
