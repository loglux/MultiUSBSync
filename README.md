# MultiUSBSync

A small WinForms GUI for pushing a folder's contents onto one or more
removable USB drives at once. Plain PowerShell + WinForms - no
external dependencies, no build step, no install.

- Pick a source folder once; it's remembered next time.
- Copies only what changed - hash comparison skips identical files.
- Chunked hashing/copying with byte-level progress, so a large file
  doesn't make the window look frozen.
- Drives are done one at a time, each showing its own `[copying]` /
  `[DONE]` status.
- Optional, off-by-default cleanup list for deleting specific
  known-stale files from already-populated drives - always confirmed
  by name before anything is deleted.

## Requirements

Windows only (WinForms). Works with the PowerShell that ships with
Windows 10/11 (Windows PowerShell 5.1) - no separate install needed.

## Running it

Keep `MultiUSBSync.ps1` and `RunMultiUSBSync.bat` in the same folder,
then double-click `RunMultiUSBSync.bat`. Plain double-clicking
`MultiUSBSync.ps1` itself usually opens it in a text editor instead of
running it, and PowerShell's default execution policy can block an
unsigned script either way. The `.bat` launcher runs it with
`-ExecutionPolicy Bypass` for this one script only, without changing
anything system-wide.

## One source folder, mirrored onto each drive's root

Pick any folder via **Browse...** in the tool itself - its entire
contents get copied to each selected drive's root as one path relative
to another: `<SourceRoot>\bin\launcher.exe` →
`<drive>:\bin\launcher.exe`, `<SourceRoot>\assets\logo.png` →
`<drive>:\assets\logo.png`, and so on for anything else under that
folder. Structure the source folder to already look like what a
drive's root should look like, and point the tool at it.

The picked folder is remembered between runs (saved to
`MultiUSBSync.settings.json`, next to the script - a local path
specific to this machine, gitignored).

## The window

- **Source folder / Browse...** - pick the folder to copy from; its
  path is shown read-only next to the button and remembered for next
  time.
- **Files to push** - every file under the source folder, as a tree
  (folders collapsed by default, expand to see and check individual
  files), each with a checkbox, checked by default. **Select
  All**/**Select None** toggle everything at once. Checking or
  unchecking a folder cascades to everything under it.
- **Drives found** - every currently-connected, ready removable drive,
  each with a checkbox, checked by default, with its own **Select
  All**/**Select None**. **Refresh drives** re-scans - use it after
  plugging in or swapping a drive without closing the window. There's
  no filtering on what already exists on a drive, so this covers both
  updating a drive that already has content and provisioning a
  completely blank one from scratch - but it also means there's no
  guardrail against picking an unrelated USB stick by mistake. Double
  check the drive path before copying, especially with **Confirm
  before copying** switched on.
- **Confirm before copying** - unchecked by default (Copy selected
  runs right away). Check it to get a Yes/No dialog listing exactly
  what's about to be copied and where, before anything happens.
- **Force overwrite even if identical** - unchecked by default
  (identical files are left alone). Check it to re-copy a file even
  when it's byte-for-byte the same as what's already on the drive.
- **Files to remove if present** - an explicit, hand-maintained list of
  relative paths (one per line, e.g. `old\stale-file.txt`), remembered
  between runs like the source folder. For cleaning up specific
  known-stale or renamed files left behind on drives that were already
  populated by an earlier run - deliberately **not** a computed
  "delete anything not in the source folder" mirror/diff, which would
  depend on exactly what happens to be checked in the tree this run
  and risks deleting something never meant to be touched. Only ever
  deletes files named here, and only where they're actually found.
  Leave it empty (the default) and nothing is ever deleted. Before any
  deletion, every checked drive is scanned and a single Yes/No dialog
  names exactly what will be deleted, grouped by drive - shown
  whenever there's anything to remove, independent of "Confirm before
  copying". Declining it only skips the removal step; the copy still
  proceeds.
- **Copy selected** - removes any **Files to remove** entries found on
  a checked drive, then copies the checked files to the checked
  drives. Top progress bar tracks overall copy progress (file N of M);
  the thinner bar underneath tracks the current file's own progress
  byte-by-byte, for both the hash comparison and the actual copy -
  hashing and copying are both hand-rolled in chunks rather than one
  blocking call, specifically so a large file (hundreds of MB,
  possibly on a slow USB drive) doesn't make the window look frozen
  partway through. Compares each file by hash first: identical files
  are skipped, not re-copied.
- **View report** - enabled only if something actually changed (new,
  replaced, or removed files); stays disabled if every file everywhere
  was already identical and nothing was removed, since there'd be
  nothing to say beyond what the status line already showed. Opens a
  non-modal window (doesn't block the main one) listing results one
  block per drive, naming only the files that actually changed and
  collapsing identical files to a count instead of listing each one -
  stays readable even at, say, 9 files across 10 drives, instead of 90
  near-identical lines to scroll through.

Uncheck what you don't want to touch this run.

Works either way you have drives connected: several at once (a hub) or
one at a time (a single USB port - swap the drive, click **Refresh
drives**, check it, click **Copy selected** again).

Drives are done strictly one at a time, in order - the drive list
itself shows which stage each one is at, appending `[copying]` or
`[DONE]` to a drive's own entry as it goes, since the overall progress
bar just counts file/drive pairs (9 files x 2 drives shows as "N of
18") and doesn't on its own make clear which drive that N belongs to.
`[DONE]` means every checked file for that drive has been written -
not a claim that it's safe to unplug right away, since that depends on
this machine's write-caching policy for removable media, which isn't
checked here. The status line says the same thing in words and holds
for a couple seconds before moving to the next drive. (Parallel
copying to multiple drives at once was considered and deliberately not
built - most setups have several drives sharing one USB hub's
bandwidth, so writing to them simultaneously wouldn't actually be
faster, just more complex.)

## Scope

Updating drives that already exist, or provisioning a blank one from
scratch - either way, this tool only copies (and, if configured,
removes) exactly what you tell it to. It has no idea what "complete"
means for your particular use case; that's on the source folder you
point it at.
