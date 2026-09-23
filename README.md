# UpdateKit

**In-app updates for direct-download macOS apps, with no Sparkle and no XPC services.** The app reads a small JSON manifest, downloads a ZIP, checks it, and swaps itself in place. Where it can't update itself in place, it falls back to opening the DMG.

This is the updater from [Vaelora](https://vaelora.app), pulled out so other apps can use it.

## What it checks

Replacing your own bundle skips the Gatekeeper check that a downloaded app would normally get. So UpdateKit does that check itself. An archive is installed only if **all** of these hold:

- its SHA-256 matches the one in the manifest, which was fetched over HTTPS;
- the app inside is validly signed with a **Developer ID Application** certificate, from **your team**, for **your bundle identifier**;
- its version is **strictly newer** than the running copy, so a replayed or rolled-back manifest can't downgrade anyone.

Pinning your team matters. A check that accepts any valid Developer ID accepts every paid developer account. So does a team-only check: an Apple Development build signed with your own team would pass it. That is why the requirement also checks Apple's Developer ID certificate markers.

## Products

| Product | What it is |
|---|---|
| `UpdateKit` | The checker, the verified download and install, and the swap. Foundation, AppKit and Security only. |
| `UpdateKitUI` | SwiftUI pieces: a banner for document windows, the "update available" dialog, and a progress window. |

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

The preference and the last-check time are stored in `UserDefaults` under `UpdateKit.automaticChecks` and `UpdateKit.lastCheck`. Pass `defaults:`, `automaticChecksKey:` and `lastCheckKey:` to keep them somewhere else, for example keys your settings screen already uses.

### The swap

An app bundle can't replace itself while its own code is running. Something outside the bundle has to wait for the app to quit, then do the swap:

- **`.builtIn`** (default): a short `/bin/sh` script. It waits for the app to exit, moves the old bundle aside, moves the new one in (putting the old one back if that fails), and relaunches. There's nothing to bundle.
- **`.helper(relativePath:arguments:)`**: an executable you already ship, such as a CLI in `Contents/Helpers`. It is copied out of the bundle and run as `helper <arguments…> --pid P --staged S --installed I`. From its entry point, call `UpdateSwap.run(arguments:)`, which does the swap with one atomic `replaceItemAt`.

```swift
swap: .helper(relativePath: "Contents/Helpers/example", arguments: ["apply-update"])
```

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
