# UpdateKit

**In-app updates for direct-download macOS apps, with no Sparkle and no XPC services.** The app reads a small JSON manifest, downloads a ZIP, checks it, and swaps itself in place. Where it can't update itself in place, it falls back to opening the DMG.

This is the updater from [Vaelora](https://vaelora.app), pulled out so other apps can use it.

## What it checks

Replacing your own bundle skips the Gatekeeper check that a downloaded app would normally get. So UpdateKit does that check itself. An archive is installed only if **all** of these hold:

- its SHA-256 matches the one in the manifest, which was fetched over HTTPS;
- the app inside is validly signed with a **Developer ID Application** certificate, from **your team**, for **your bundle identifier**;
- its version is **strictly newer** than the running copy, so a replayed or rolled-back manifest can't downgrade anyone.
- its version is **the one the manifest announced**, so the user gets the release they agreed to;
- it contains every path in `requiredExecutables`, for helpers other programs launch by absolute path.

Pinning your team matters. A check that accepts any valid Developer ID accepts every paid developer account. So does a team-only check: an Apple Development build signed with your own team would pass it. That is why the requirement also checks Apple's Developer ID certificate markers.

## Products

| Product | What it is |
|---|---|
| `UpdateKit` | The checker, the verified download and install, and the swap. Foundation, AppKit and Security only. |
| `UpdateKitUI` | SwiftUI pieces: a banner for document windows, the "update available" dialog, and a progress window. |
| `UpdateKitHandOver` | For long-lived helpers such as MCP servers: become the updated build in place, keeping the process and its client's connection. Foundation and Security only. |

macOS 15+, Swift 6.

## Use

```swift
import UpdateKit
import UpdateKitUI

let updates = UpdateChecker(configuration: UpdaterConfiguration(
    appName: "Example",
    bundleIdentifier: "app.example",
    teamIdentifier: "ABCDE12345",
    manifestURL: URL(string: "https://dl.example.app/latest/appcast.json")!))

// At launch: at most once a day, and only if the user hasn't turned it off.
Task { await updates.checkIfDue() }

// The menu command. The user asked, so every outcome gets an answer.
Button("Check for Updates…") {
    Task {
        await updates.check()
        UpdateAlert.present(for: updates)
    }
}

// Across the top of a document window. It shows only when there's something to say.
VStack(spacing: 0) {
    UpdateBanner(checker: updates, accent: .blue)
    content
}

// Settings (with `@ObservedObject var updates`).
Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
```

At launch, `AppUpdater.sweepStaleStaging()` removes anything a force-quit mid-download left beside the bundle. Pass `prefixes:` to also sweep names an older, home-grown updater used.

The preference and the last-check time are stored in `UserDefaults` under `UpdateKit.automaticChecks` and `UpdateKit.lastCheck`. Pass `defaults:`, `automaticChecksKey:` and `lastCheckKey:` to keep them somewhere else, for example keys your settings screen already uses.

### The swap

An app bundle can't replace itself while its own code is running. Something outside the bundle has to wait for the app to quit, then do the swap:

- **`.builtIn`** (default): a short `/bin/sh` script. It waits for the app to exit, moves the old bundle aside, moves the new one in (putting the old one back if that fails), and relaunches. There's nothing to bundle.
- **`.helper(relativePath:arguments:)`**: an executable you already ship, such as a CLI in `Contents/Helpers`. It is copied out of the bundle and run as `helper <arguments…> --pid P --staged S --installed I`. From its entry point, call `UpdateSwap.run(arguments:)`, which does the swap with one atomic `replaceItemAt`.

```swift
swap: .helper(relativePath: "Contents/Helpers/example", arguments: ["apply-update"])
```

After the hand-off the app quits through `NSApp.terminate`, so `applicationShouldTerminate` runs as usual. It may return `.terminateLater` and reply from a Task when its own shutdown is done: the quit is asked for from a run-loop timer, not from inside a main-actor job, so that Task can run. If the app refuses the quit, `installUpdate` returns and the swap goes ahead on its own once its wait runs out.

A helper of your own doesn't have to call `UpdateSwap.run`. Anything that honours `--pid`, `--staged` and `--installed` will do, and `arguments` can carry more (Claunnector passes the socket its helper waits on).

If other programs launch something inside your bundle by absolute path, list it so a release that moved it is refused rather than installed:

```swift
requiredExecutables: ["Contents/Helpers/example"]
```

### Helpers that outlive the update

A helper another app launched, such as an MCP server an AI client started from `Contents/Helpers`, keeps running the old code after the bundle is replaced. Worse, macOS may withdraw its privacy access once that code is gone from disk. `UpdateKitHandOver` makes the helper `exec` the new build: the same process, parent, stdin and stdout, so the client never sees a disconnection.

In the helper, read requests through `StdioHandOver` and send every reply through it:

```swift
import UpdateKitHandOver

let handOver = StdioHandOver(watch: ExecutableWatch.forThisProcess())
if HandOver.resumed {
    // A client is connected and listed the old build's tools.
    try? handOver.send(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))
}
while let request = handOver.nextLine() {
    let reply = handle(request)
    try? handOver.send(reply)
}
```

A helper that serves requests concurrently reads with `nextRequest()` instead, and finishes each request once its reply is sent:

```swift
while let request = handOver.nextRequest() {
    Task {
        defer { request.finish() }
        try? handOver.send(await handle(request.line))
    }
}
```

An update then waits until no request is in flight. Meanwhile nothing more is read, so what the client sends stays in the pipe for the new build.

In the app, at launch:

```swift
HelperNudge.nudge(helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/example"))
```

When it switches:

- **Before reading each request.** It waits until input is readable, checks the launch path, and switches with the request still in the pipe, so the new code answers it.
- **When nudged** (`SIGUSR1`). An idle helper switches at once instead of at its next request. The app nudges at launch, which follows both an in-app update and an install from the disk image. A helper too old to handle the signal isn't sent it, since the default action would end it.
- **When the last request in flight finishes**, for a helper reading with `nextRequest()` whose update was ready while requests were running.
- **Never otherwise.** There is no timer; an idle helper sleeps until input or the nudge arrives.

What it switches to: the file at the helper's launch path, once that is a different file (by inode), has been in place for two seconds, and meets the running build's designated requirement. A Debug build signed to run locally has a requirement only an identical copy meets, so it never switches. A refused or failed switch leaves the old code serving.

It switches only with nothing in flight and nothing it has read left unanswered. A server that keeps state between requests (open files, sessions) must be able to rebuild it in the new image, or not use this.

## Publishing a release

Each release needs:

1. **The DMG**, for new users and as the fallback.
2. **A ZIP of the notarized, stapled app** for the updater. Make it with `ditto`, not `zip`, so the symlinks and extended attributes that the signature covers are preserved:
   ```bash
   ditto -c -k --keepParent "Example.app" "example-1.4.0.zip"
   ```
3. **`appcast.json`**, written by `scripts/publish-update.sh`:
   ```bash
   scripts/publish-update.sh --version 1.4.0 \
       --dmg-url https://dl.example.app/1.4.0/example-1.4.0.dmg \
       --zip build/example-1.4.0.zip --zip-url https://dl.example.app/1.4.0/example-1.4.0.zip \
       --min-macos 15.0 --notes "One line for the banner." --output build/appcast.json
   ```

Uploading is up to you. The order matters:

1. Upload the versioned files first. They are immutable: never overwrite a published version.
2. Then any mutable `latest` download link.
3. The manifest **last**, served `no-cache`.

An app must never see a manifest for a version whose files aren't there yet. The manifest must also point at the **versioned** URLs, never at `latest`. A client holding one release's checksum has to fetch that release's bytes.

```json
{
  "version": "1.4.0",
  "url": "https://dl.example.app/1.4.0/example-1.4.0.dmg",
  "minimumSystemVersion": "15.0",
  "notes": "One line for the banner.",
  "archive": "https://dl.example.app/1.4.0/example-1.4.0.zip",
  "sha256": "…64 hex characters…",
  "archiveSize": 5242880
}
```

A build that needs a newer macOS than `minimumSystemVersion` says isn't offered. A manifest without `archive` and `sha256` is offered as a download only.

## When it won't update in place

It offers the DMG instead when the app is:

- running from a disk image or a translocated path. `RunLocation.isUnsuitable(_:)` detects this, and you can use it at launch to ask the user to move the app to Applications;
- in a folder the user can't write to;
- sandboxed and installed outside its container.

## Licence

MIT.
