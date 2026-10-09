// Package manifest defines the snapshot manifest: the file-tree contract
// between a snapshot and the blobs stored in a keepsake repository.
package manifest

import (
	"time"
)

// FormatVersion is the version of the manifest schema written by this build.
// Bump on any breaking change; see docs/repo-format.md.
const FormatVersion = 1

// ChunkRef points at one content-addressed blob covering [Offset, Offset+Size)
// of a file. A media file maps to a single whole-file chunk; a SQLite database
// maps to page-aligned chunks so consecutive snapshots share unchanged pages.
type ChunkRef struct {
	Hash   string `json:"hash"` // sha256 hex of the chunk content
	Offset int64  `json:"offset"`
	Size   int64  `json:"size"`
}

// FileEntry describes one file inside the snapshot, relative to the account
// directory. Paths always use forward slashes so manifests stay portable
// across platforms.
type FileEntry struct {
	Path    string     `json:"path"`
	Size    int64      `json:"size"`
	Mode    uint32     `json:"mode"` // permission bits only
	ModTime time.Time  `json:"mod_time"`
	Chunks  []ChunkRef `json:"chunks"`
}

// Manifest is a point-in-time listing of one WeChat account directory.
type Manifest struct {
	FormatVersion int         `json:"format_version"`
	DeviceID      string      `json:"device_id"`
	Account       string      `json:"account"` // account directory name (e.g. wxid_...)
	HostPlatform  string      `json:"host_platform"`
	CreatedAt     time.Time   `json:"created_at"`
	Files         []FileEntry `json:"files"`
}

// TotalSize returns the sum of all file sizes in the manifest.
func (m *Manifest) TotalSize() int64 {
	var total int64
	for _, f := range m.Files {
		total += f.Size
	}
	return total
}
