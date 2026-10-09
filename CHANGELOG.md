# Changelog

All notable changes to this project will be documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/); versioning
starts at 1.0.0 for the first release.

## [Unreleased]

### Changed

- Rewrote the engine from Go to Racket (same repository format, same
  behavior): the product's soul is its UI, and Apple-grade native hosts are
  the Rivet line's whole point — a Go engine would have forced a second
  stack and a never-tested Go↔Swift bridge. The Go implementation survives
  in git history as a format reference.

### Added

- Native macOS shell (SwiftUI over the embedded Racket engine): account
  sidebar with real sizes, snapshot timeline, snapshot/restore actions with
  a destructive-action confirmation that explains the pre-restore safety
  snapshot, and an auto-snapshot interval picker.
- Auto-snapshot scheduling: the embedded backend snapshots every account on
  a user-set interval (off / 15m / 1h / 6h / 1d) and pushes a
  snapshots-changed event so open hosts refresh; the scheduling decision is
  pure and unit-tested.
- Restore by snapshot index (`restore-snapshot` replaces the provisional
  restore-latest RPC).
- macOS TCC denials surface as an actionable Full Disk Access hint instead
  of a bare "Operation not permitted".
- Restore flow: two-phase materialization (pre-flight blob verification
  before the target is touched, written-size checks after), path-safety
  rejection, best-effort mode/mtime restore, and a CLI that always takes an
  automatic pre-restore safety snapshot of the target directory first.
- Agent CLI (`racket app/cli.rkt`): `discover`, `snapshot`, `status` —
  locates WeChat account directories on macOS / Windows / Linux, chunks
  files content-addressed (whole-file for media, page-aligned for SQLite
  databases), uploads only missing blobs, and writes JSON snapshot manifests.
- Keepsake repository format v1: content-addressed blob store, per-device
  manifest namespaces, atomic writes, no locking required — specified in
  `docs/repo-format.md`.
- Cross-platform CI (ubuntu / macOS / Windows) and bilingual README.
