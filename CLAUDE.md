# UpdateKit

In-app updater for direct-download macOS apps. Extracted from Vaelora (`~/Git/Vaelora`), which is its first user; Claunnector (`~/Git/Claunnector`) is the second, with its own swap helper. Keep the two in step: a fix here ships to Vaelora by bumping its `from:` version in `project.yml`.

## The security boundary

`AppUpdater.installUpdate` replaces the app's bundle itself, which skips Gatekeeper. The checks there are the only thing between "someone can serve bytes at the download URL" and "someone can run code as the user". Don't weaken any of them.

- **Checksum.** The SHA-256 comes from the manifest. `installableArchive` returns nil unless there is a well-formed 64-character hash. A missing checksum must never be read as a passed one.
- **Signature.** `requirementString` pins the bundle ID, the team, *and* both Developer ID OIDs (the CA intermediate and the Application leaf). Pinning only the team accepted an Apple Development build from the same team. A test in Vaelora caught that, and it's the test that proves it: `a development signed build of our own team is refused`. It needs a signed test host, so it lives in the app's tests, not here.
- **Announced version.** `checkAnnounced`: the bundle's version must equal the manifest's, so "newer" can't mean "anything newer".
- **Required executables.** `configuration.requiredExecutables` must all be executable in the staged bundle.
- **Newer only.** `checkNewer` compares with `AppVersion` (numerically, so 0.2.10 > 0.2.9) against the version inside the downloaded bundle.

Test every check against input that should fail, not only against the happy path.

## The swap

- `.helper` → `UpdateSwap.run`: one atomic `replaceItemAt`.
- `.builtIn` → `BuiltInSwap.script`: `mv` aside, `mv` in, with rollback. Paths are **positional parameters**, never spliced into the script text. `SwapTests` has a directory named with `$(…)` and quotes to hold that in place.
- Staging is removed in `handOff`, before the app quits. The `defer` in `installUpdate` covers failures only: on success the process is gone before it runs.
- The staged copy is always placed in the install directory, never `/tmp`, so the swap is a rename on the same volume.

## Conventions

- Swift Testing, `swift test`. `UpdateFetchLiveTests` skips itself unless `Tests/Fixtures` is served on :8766 (`python3 -m http.server 8766`).
- Comments explain *why*, and most record a bug that shipped once. Keep them when refactoring.
- UI text uses `configuration.appName`. Never hard-code an app name.

## Hand-over (`UpdateKitHandOver`)

For an app's long-lived helpers. Vaelora's `vaelora mcp` and Claunnector's daemon each had their own version first; this one takes Claunnector's exec and signature checks and replaces its once-a-second idle poll with a signal.

- **It switches at two moments only:** after input becomes readable but before reading it, and when nudged with SIGUSR1. No timer. The check at the top of `nextLine` runs before the wait, so it can't count as the check before reading; `firstRequestAfterUpdate` failed until the readable branch checked again.
- **Settle time is counted from the file's ctime,** not from when the helper first noticed it, so a request long after an install doesn't wait.
- **`HelperNudge` never signals a process that leaves SIGUSR1 at its default,** because the default ends it. It reads `p_sigignore | p_sigcatch` through `sysctl`.
- **Tests run `HandOverDemo` for real.** They copy it, rename a fresh copy over it, and talk to it over pipes. A copied Apple binary (`/bin/sleep`) is killed by macOS on launch, so the "old helper" case is the demo with `HANDOVER_DEMO_NO_SIGNAL`.

## Windows across the update (`WindowsAcrossUpdate`)

The update's `NSApp.terminate` is an ordinary quit, and with the default "Close windows when quitting" setting AppKit discards the saved windows. So `installUpdate` calls `keep()` just before the quit, and `UpdateChecker.init` calls `finishRelaunch()`.

- **Documents are reopened by UpdateKit, from bookmarks.** Setting `NSQuitAlwaysKeepsWindows` from inside Vaelora right before `terminate` still discarded its SwiftUI document windows. It did keep a plain AppKit window, so the setting stays too, for apps with ordinary windows.
- **Reopen after `didFinishLaunching`.** Before that, a SwiftUI document app is still deciding whether to show its Open panel.
- **Only the update's quit keeps anything.** The marker key means a user's own `NSQuitAlwaysKeepsWindows` is never removed. A refused quit calls `cancel()`.
- **To test against a real app without touching the user's Recents**, build it with `PRODUCT_BUNDLE_IDENTIFIER` overridden. A build signed differently under the same bundle id takes over the recent-documents list and empties it.
