// Package repo implements the keepsake repository: a self-describing,
// content-addressed directory tree that can live on an APFS volume, an SMB
// mount, or inside a hub container volume.
//
// Layout (see docs/repo-format.md):
//
//	repo.json                              format marker
//	blobs/sha256/<xx>/<hash>               content-addressed chunk store
//	devices/<device>/snapshots/*.manifest.json
package repo

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/turinglambdaai/keepsake/internal/manifest"
)

// FormatVersion of the on-disk repository layout.
const FormatVersion = 1

// markerName is the file that marks a directory as a keepsake repository.
const markerName = "repo.json"

type marker struct {
	FormatVersion int       `json:"format_version"`
	CreatedAt     time.Time `json:"created_at"`
}

// Repo is a handle on an initialized repository directory.
type Repo struct {
	root string
}

// Init creates a new repository at root. It is idempotent: an existing,
// valid repository is returned unchanged (format version permitting).
func Init(root string) (*Repo, error) {
	if err := os.MkdirAll(filepath.Join(root, "blobs", "sha256"), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(root, "devices"), 0o755); err != nil {
		return nil, err
	}
	markerPath := filepath.Join(root, markerName)
	if _, err := os.Stat(markerPath); errors.Is(err, os.ErrNotExist) {
		m := marker{FormatVersion: FormatVersion, CreatedAt: time.Now().UTC()}
		if err := writeJSONAtomic(markerPath, &m); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	return Open(root)
}

// Open opens an existing repository.
func Open(root string) (*Repo, error) {
	b, err := os.ReadFile(filepath.Join(root, markerName))
	if err != nil {
		return nil, fmt.Errorf("keepsake: %s is not a keepsake repository (no %s): %w", root, markerName, err)
	}
	var m marker
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("keepsake: corrupt %s in %s: %w", markerName, root, err)
	}
	if m.FormatVersion > FormatVersion {
		return nil, fmt.Errorf("keepsake: repository at %s uses format v%d, this build supports v%d", root, m.FormatVersion, FormatVersion)
	}
	return &Repo{root: root}, nil
}

// Root returns the repository's filesystem root.
func (r *Repo) Root() string { return r.root }

// HasBlob reports whether a chunk with the given sha256 hex hash is present.
func (r *Repo) HasBlob(hash string) (bool, error) {
	_, err := os.Stat(r.blobPath(hash))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

// PutBlob streams data into the blob store and returns its sha256 hex hash.
// Writing is content-addressed and idempotent: chunks already present are
// left untouched.
func (r *Repo) PutBlob(data io.Reader) (string, error) {
	tmp, err := os.CreateTemp(filepath.Join(r.root, "blobs", "sha256"), ".incoming-*")
	if err != nil {
		return "", err
	}
	tmpName := tmp.Name()
	defer func() {
		// No-op once renamed; cleans up on every early return.
		_ = os.Remove(tmpName)
	}()

	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, h), data); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	hash := hex.EncodeToString(h.Sum(nil))

	dst := r.blobPath(hash)
	if _, err := os.Stat(dst); err == nil {
		return hash, nil // already stored: dedupe
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", err
	}
	if err := os.Rename(tmpName, dst); err != nil {
		return "", err
	}
	return hash, nil
}

// ReadBlob opens a stored chunk for reading (used by restore).
func (r *Repo) ReadBlob(hash string) (io.ReadCloser, error) {
	return os.Open(r.blobPath(hash))
}

func (r *Repo) blobPath(hash string) string {
	return filepath.Join(r.root, "blobs", "sha256", hash[:2], hash)
}

// WriteManifest stores a snapshot manifest under the device's namespace.
// The filename carries millisecond-precision UTC time so listings sort
// chronologically by name alone.
func (r *Repo) WriteManifest(m manifest.Manifest) error {
	if m.DeviceID == "" {
		return errors.New("keepsake: manifest without device id")
	}
	dir := filepath.Join(r.root, "devices", sanitize(m.DeviceID), "snapshots")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	name := m.CreatedAt.UTC().Format("20060102T150405.000Z") + ".manifest.json"
	return writeJSONAtomic(filepath.Join(dir, name), &m)
}

// Snapshots lists all manifests for a device, oldest first.
func (r *Repo) Snapshots(deviceID string) ([]manifest.Manifest, error) {
	dir := filepath.Join(r.root, "devices", sanitize(deviceID), "snapshots")
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })

	var out []manifest.Manifest
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".manifest.json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			return nil, err
		}
		var m manifest.Manifest
		if err := json.Unmarshal(b, &m); err != nil {
			return nil, fmt.Errorf("keepsake: corrupt manifest %s: %w", e.Name(), err)
		}
		out = append(out, m)
	}
	return out, nil
}

// sanitize keeps device IDs from escaping the devices/ directory.
func sanitize(deviceID string) string {
	clean := filepath.Clean(deviceID)
	clean = strings.ReplaceAll(clean, "..", "__")
	clean = strings.ReplaceAll(clean, string(filepath.Separator), "-")
	clean = strings.ReplaceAll(clean, "/", "-")
	if clean == "" || clean == "." || clean == string(filepath.Separator) {
		clean = "unknown"
	}
	return clean
}

// writeJSONAtomic writes v as JSON via a temp file + rename so readers never
// observe a half-written file.
func writeJSONAtomic(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}
