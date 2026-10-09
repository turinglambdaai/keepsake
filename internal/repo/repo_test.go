package repo

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/turinglambdaai/keepsake/internal/manifest"
)

func TestInitIdempotent(t *testing.T) {
	root := filepath.Join(t.TempDir(), "repo")

	first, err := Init(root)
	if err != nil {
		t.Fatalf("Init: %v", err)
	}
	second, err := Init(root)
	if err != nil {
		t.Fatalf("re-Init: %v", err)
	}
	if first.Root() != second.Root() {
		t.Fatal("Init should return the same repository")
	}
	if _, err := os.Stat(filepath.Join(root, "repo.json")); err != nil {
		t.Fatalf("repo.json missing: %v", err)
	}
}

func TestOpenRejectsNonRepository(t *testing.T) {
	if _, err := Open(t.TempDir()); err == nil {
		t.Fatal("Open on a plain directory should fail")
	}
}

func TestPutBlobDedupes(t *testing.T) {
	r, err := Init(filepath.Join(t.TempDir(), "repo"))
	if err != nil {
		t.Fatal(err)
	}

	data := []byte("the same chunk, twice")
	h1, err := r.PutBlob(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("PutBlob: %v", err)
	}
	h2, err := r.PutBlob(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("PutBlob again: %v", err)
	}
	if h1 != h2 {
		t.Fatalf("same content produced hashes %s and %s", h1, h2)
	}

	// Walk the blob store: exactly one file must exist.
	var count int
	err = filepath.WalkDir(r.Root(), func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasPrefix(d.Name(), h1[:2]) {
			count++
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("blob store has %d files for identical content, want 1", count)
	}

	ok, err := r.HasBlob(h1)
	if err != nil || !ok {
		t.Fatalf("HasBlob = %v, %v; want true, nil", ok, err)
	}
}

func TestManifestRoundTripOrdered(t *testing.T) {
	r, err := Init(filepath.Join(t.TempDir(), "repo"))
	if err != nil {
		t.Fatal(err)
	}

	base := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	for i, minute := range []int{30, 10, 20} {
		if err := r.WriteManifest(manifest.Manifest{
			FormatVersion: manifest.FormatVersion,
			DeviceID:      "mac-mini",
			Account:       "wxid_test",
			CreatedAt:     base.Add(time.Duration(minute) * time.Minute),
			Files:         []manifest.FileEntry{{Path: "f", Size: int64(i)}},
		}); err != nil {
			t.Fatalf("WriteManifest %d: %v", i, err)
		}
	}

	snaps, err := r.Snapshots("mac-mini")
	if err != nil {
		t.Fatalf("Snapshots: %v", err)
	}
	if len(snaps) != 3 {
		t.Fatalf("got %d snapshots, want 3", len(snaps))
	}
	for i, want := range []int{10, 20, 30} {
		got := snaps[i].CreatedAt.Minute()
		if got != want {
			t.Fatalf("snapshot %d minute = %d, want %d (oldest first)", i, got, want)
		}
	}

	// Other devices see nothing.
	empty, err := r.Snapshots("other-box")
	if err != nil || len(empty) != 0 {
		t.Fatalf("other device snapshots = %v, %v; want empty", empty, err)
	}
}

func TestSanitizeBlocksTraversal(t *testing.T) {
	r, err := Init(filepath.Join(t.TempDir(), "repo"))
	if err != nil {
		t.Fatal(err)
	}
	if err := r.WriteManifest(manifest.Manifest{
		DeviceID:  "../../escape",
		Account:   "a",
		CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("WriteManifest with traversal id: %v", err)
	}
	escaped := filepath.Join(r.Root(), "escape")
	if _, err := os.Stat(escaped); err == nil {
		t.Fatal("manifest escaped the devices/ directory")
	}
}
