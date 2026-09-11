# XcodeOffload

macOS utility for a small internal disk. It finds Xcode data that is safe to delete, and can move the rest to an external **APFS** drive while leaving a symlink at the original path so Xcode, Simulator, and `simctl` still find it.

## What it does

- Scans known Xcode caches (DerivedData, DeviceSupport, simulators, docs, SwiftPM, and similar)
- Skips `CoreDevice/DeviceFS` (that is a virtual mount of phones/simulators, not local disk)
- Deletes regenerable caches via Trash
- Copies keepers to an external APFS volume, then replaces the original folder with a symlink
- Remembers each move with a security-scoped bookmark so a remounted volume can be found again
- Refuses ExFAT/FAT, Time Machine, and case-sensitive APFS destinations

The 1TB flash drive formatted as ExFAT cannot host these folders. Use an APFS volume such as OnnSSD1Tb.

## Run without Xcode

The packaged app is already installed at:

**`~/Applications/XcodeOffload.app`**

Open it from Spotlight, Launchpad, or Finder. A zip copy is also in `dist/XcodeOffload.zip`.

The app is unsandboxed on purpose so it can write under `~/Library/Developer`. Quit Xcode and Simulator before deleting or moving.

If macOS blocks it the first time, right-click the app → **Open**.

