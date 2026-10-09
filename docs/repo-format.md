# Keepsake Repository Format — v1

The repository is the core asset of Keepsake. Its defining property is
**escapability**: a repository is a plain, self-describing directory tree of
JSON and content-addressed blobs. If this project disappeared tomorrow, you
could reassemble every snapshot with `jq` and `cp`. No database, no vendor
lock, no proprietary packing.

## Design principles

1. **Content-addressed, append-only.** Blobs are written once under their
   sha256 and never modified. Writes go to a temp file and are renamed into
   place, so concurrent writers (multiple agents, a hub doing GC while an
   agent uploads) cannot corrupt anything without any locking protocol.
2. **File-level dedup for media, page-level dedup for databases.** WeChat
   stores media content-addressed and immutable — whole-file chunks are
   optimal. SQLite databases change a little every snapshot but only in a few
   pages, so they are split on their own page boundary and consecutive
   snapshots share all unchanged pages.
3. **Per-device namespaces.** Each device writes only under
   `devices/<device-id>/`, so agents never contend on shared files. The blob
   pool is the only shared area, and principle 1 makes that safe.
4. **The hub is never a single point of failure.** The format assumes the hub
   may be down: agents can write this exact layout directly to an SMB mount
   or local volume. The hub adds scheduling, GC, verification, and the UI —
   nothing in the format requires it.
5. **File-level only.** Keepsake never reads message content. It does not
   extract keys, decrypt databases, or attach to the WeChat process. The
   repository therefore contains only opaque files.

## Layout

```
<repo-root>/
├── repo.json                                 format marker
├── blobs/
│   └── sha256/
│       └── <hash[0:2]>/<hash>                content-addressed chunks
└── devices/
    └── <device-id>/
        └── snapshots/
            └── <YYYYMMDDThhmmss.mmmZ>.manifest.json
```

### repo.json

```json
{
  "format_version": 1,
  "created_at": "2026-10-09T00:00:00Z"
}
```

`format_version` is the layout version. Readers must refuse repositories with
a **higher** version; lower versions may be migrated forward.

### blobs

Each file `blobs/sha256/<xx>/<hash>` contains the raw bytes of one chunk,
where `<hash>` is the lowercase hex sha256 of those bytes. The two-character
fanout keeps directories small on filesystems that dislike huge listings.

Empty files are represented by **zero chunks** in the manifest; restore
creates an empty file. There is no empty blob.

### Manifests

One JSON document per snapshot, named by its UTC creation time at millisecond
precision so directory listings sort chronologically:

```json
{
  "format_version": 1,
  "device_id": "mac-mini",
  "account": "wxid_example123",
  "host_platform": "darwin",
  "created_at": "2026-10-09T12:00:00.000Z",
  "files": [
    {
      "path": "db_storage/message/0.db",
      "size": 8192,
      "mode": 420,
      "mod_time": "2026-10-09T11:59:59Z",
      "chunks": [
        { "hash": "9f86d081…", "offset": 0,    "size": 4096 },
        { "hash": "2c26b46b…", "offset": 4096, "size": 4096 }
      ]
    },
    {
      "path": "msg/attach/7f/abc123.jpg",
      "size": 29311,
      "mode": 420,
      "mod_time": "2026-10-01T08:00:00Z",
      "chunks": [
        { "hash": "e3b0c442…", "offset": 0, "size": 29311 }
      ]
    }
  ]
}
```

Field contracts:

- `path` is relative to the account directory and **always uses forward
  slashes**, so a manifest written on Windows restores on macOS.
- `chunks` cover the file completely, in order: `offset` is monotonically
  increasing starting at 0, and the sum of `size` equals `size`. Restoring is
  concatenating chunk contents at their offsets.
- `mode` holds permission bits only (`stat mode & 0777`). Ownership is not
  preserved; restores use the restoring user.
- A media file (any file that does not start with the SQLite 3 magic) is one
  whole-file chunk. A SQLite database is split on its own page size — read
  from the big-endian uint16 at header offset 16, value 1 meaning 65536.

### Device IDs

Stable per-installation identifiers (hostname today; a generated stable ID
later). They name a directory namespace only — the same WeChat account may
appear under several devices, and the union of their snapshots is the
most-complete backup of that account.

## Garbage collection (reserved, hub-side)

GC walks all manifests under `devices/`, marks every hash referenced by any
`chunks` entry, and deletes unreferenced blobs. Because blobs are immutable
and manifests are only added, GC is a background mark-sweep that can run
while agents upload: a blob uploaded but not yet referenced by any on-disk
manifest is indistinguishable from garbage only until its manifest lands, so
hub-side GC must exclude blobs younger than a grace window (default 24h).

## Encryption (reserved, optional layer)

Blobs may be stored encrypted (AES-GCM) with keys held by the agent, for
repositories on media the user does not control (a VPS, a cloud bucket).
Encrypted layouts will change the marker file to declare it; v1 repositories
are plaintext by definition.

## Compatibility rules

- Adding fields to manifests or the marker is **not** a version bump; readers
  ignore unknown fields.
- Removing or redefining fields, changing chunk semantics, or changing the
  layout **is** a version bump and requires a migration note in this file.
