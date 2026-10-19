# Project context

## Confirmed decisions

- SimParcel delivers files and links to ordinary iOS simulators and to booted Xcode Canvas devices.
- Canvas uses CoreSimulator's separate `previews` device set. It is optional on installations that do not support it.
- Standard and Canvas broadcasts stay separate. Canvas selection IDs are namespaced; `simctl` receives the raw device UDID and the matching `--set` argument.
- Xcode manages Canvas lifecycle. SimParcel never boots a Canvas device or opens it in Device Hub. An unavailable Canvas selection stays selected and cannot receive files; refresh must not redirect it to another simulator.
- Contributor commits are preserved when integrating external pull requests.

## Implementation

- The selected Xcode determines whether SimParcel opens Simulator.app or DeviceHub.app. Device Hub uses its registered `devices://` URL scheme.
- Automatic device refresh preserves operation errors and successful Show retries clear the previous error. Refresh failures remain visible.
- Simulator services, command execution, and selection persistence have protocol boundaries for constructor injection in tests.
- New simulator and Canvas UI text lives in `SimParcel/Main/Localizable.xcstrings`. Existing unrelated UI still contains legacy English literals; migrating the rest of the app is separate work.

## Verification

- The macOS `SimParcel` scheme is the build and test entry point. Use native arm64 and an isolated derived-data directory for local verification.
- Canvas and standard JSON test fixtures were reduced from `simctl list devices available --json` snapshots on Xcode 27. Their UDIDs identify test fixtures only; tests do not connect to those devices.
- Unit tests cover device-set routing, Canvas shutdown checks, optional preview-set failure, broadcast isolation, selection persistence, Show retries, and operation-status preservation.
- On 2026-10-19, all 57 tests passed using Xcode 27.0 on arm64 macOS.
- Manual verification used a live iPhone Duo Canvas on iOS 27.1. Sending a text file and PNG through the built app succeeded; the file contents and Photos database record were independently checked.
- Closing the test Xcode shut down its Canvas device. Sending against the stale selection failed visibly without rebooting it. Refresh preserved the unavailable Canvas selection, retained the queue, and disabled sending.
- Show in Device Hub selected the existing iPhone 17 running iOS 27.0. The legacy Simulator launch path is covered by a command-runner test; a legacy Xcode GUI was not launched.
- The `previews` set was checked with Apple's installed `simctl`; the `devices` scheme was checked in DeviceHub.app's bundle metadata and exercised through the app.
- App installation, push delivery, and media variants use command-routing tests for Canvas. Real Canvas verification covered PNG and ordinary file delivery.
