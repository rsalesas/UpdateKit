# UpdateKit

In-app updater for direct-download macOS apps. Extracted from Vaelora (`~/Git/Vaelora`), which is its first user. Keep the two in step: a fix here ships to Vaelora by bumping its `from:` version in `project.yml`.

## The security boundary

`AppUpdater.installUpdate` replaces the app's bundle itself, which skips Gatekeeper. The checks there are the only thing between "someone can serve bytes at the download URL" and "someone can run code as the user". Don't weaken any of them.

- **Checksum.** The SHA-256 comes from the manifest. `installableArchive` returns nil unless there is a well-formed 64-character hash. A missing checksum must never be read as a passed one.
- **Signature.** `requirementString` pins the bundle ID, the team, *and* both Developer ID OIDs (the CA intermediate and the Application leaf). Pinning only the team accepted an Apple Development build from the same team. A test in Vaelora caught that, and it's the test that proves it: `a development signed build of our own team is refused`. It needs a signed test host, so it lives in the app's tests, not here.
- **Newer only.** `checkNewer` compares with `AppVersion` (numerically, so 0.2.10 > 0.2.9) against the version inside the downloaded bundle.

Test every check against input that should fail, not only against the happy path.

## The swap

- `.helper` → `UpdateSwap.run`: one atomic `replaceItemAt`.
- `.builtIn` → `BuiltInSwap.script`: `mv` aside, `mv` in, with rollback. Paths are **positional parameters**, never spliced into the script text. `SwapTests` has a directory named with `$(…)` and quotes to hold that in place.
- The staged copy is always placed in the install directory, never `/tmp`, so the swap is a rename on the same volume.

## Conventions

- Swift Testing, `swift test`. `UpdateFetchLiveTests` skips itself unless `Tests/Fixtures` is served on :8766 (`python3 -m http.server 8766`).
- Comments explain *why*, and most record a bug that shipped once. Keep them when refactoring.
- UI text uses `configuration.appName`. Never hard-code an app name.
