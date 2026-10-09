package snapshot

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/turinglambdaai/keepsake/internal/discover"
	"github.com/turinglambdaai/keepsake/internal/repo"
)

// fakeSQLite assembles a minimal file with a valid SQLite header so the
// chunker treats it as page-aligned.
func fakeSQLite(t *testing.T, path string, pages int) {
	t.Helper()
	const pageSize = 4096
	data := make([]byte, pages*pageSize)
	copy(data, "SQLite format 3\x00")
	data[16] = 0x10 // page size 4096, big-endian high byte
	data[17] = 0x00
	for i := range data[100:] {
		data[100+i] = byte(i % 251)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRunSnapshotsAndDedupes(t *testing.T) {
	root := t.TempDir()
	accDir := filepath.Join(root, "wxid_test", "db_storage", "message")
	if err := os.MkdirAll(accDir, 0o755); err != nil {
		t.Fatal(err)
	}
	fakeSQLite(t, filepath.Join(accDir, "0.db"), 4)
	if err := os.WriteFile(filepath.Join(root, "wxid_test", "db_storage", "note.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}

	r, err := repo.Init(filepath.Join(t.TempDir(), "repo"))
	if err != nil {
		t.Fatal(err)
	}
	account := discover.Account{ID: "wxid_test", Path: filepath.Join(root, "wxid_test")}

	// First run: everything is new.
	m1, res1, err := Run(r, account, "dev-a")
	if err != nil {
		t.Fatalf("Run 1: %v", err)
	}
	if res1.Files != 2 {
		t.Fatalf("files = %d, want 2", res1.Files)
	}
	if res1.DedupedBlobs != 0 || res1.UploadedBlobs == 0 {
		t.Fatalf("first run should upload all: %+v", res1)
	}
	if m1.DeviceID != "dev-a" || m1.Account != "wxid_test" {
		t.Fatalf("manifest identity wrong: %+v", m1)
	}

	// Second run, no changes: zero uploads, everything deduped.
	_, res2, err := Run(r, account, "dev-a")
	if err != nil {
		t.Fatalf("Run 2: %v", err)
	}
	if res2.UploadedBlobs != 0 {
		t.Fatalf("unchanged run uploaded %d blobs, want 0", res2.UploadedBlobs)
	}
	if res2.DedupedBlobs == 0 || res2.DedupedBytes != res2.TotalBytes {
		t.Fatalf("unchanged run should dedupe everything: %+v", res2)
	}

	// Touch one page of the database: only that page uploads.
	dbPath := filepath.Join(accDir, "0.db")
	data, err := os.ReadFile(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	data[100] ^= 0xFF // flip a byte inside the first page
	if err := os.WriteFile(dbPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	// Distinct mtime is not required for correctness (hashes drive dedupe),
	// but keep the write honest.
	_ = os.Chtimes(dbPath, time.Now(), time.Now())

	_, res3, err := Run(r, account, "dev-a")
	if err != nil {
		t.Fatalf("Run 3: %v", err)
	}
	if res3.UploadedBlobs != 1 {
		t.Fatalf("one-page edit uploaded %d blobs, want 1: %+v", res3.UploadedBlobs, res3)
	}
	if res3.UploadedBytes != 4096 {
		t.Fatalf("one-page edit uploaded %d bytes, want 4096", res3.UploadedBytes)
	}

	snaps, err := r.Snapshots("dev-a")
	if err != nil {
		t.Fatal(err)
	}
	if len(snaps) != 3 {
		t.Fatalf("repository holds %d manifests, want 3", len(snaps))
	}
}

func TestRunSkipsSymlinks(t *testing.T) {
	root := t.TempDir()
	accDir := filepath.Join(root, "wxid_test", "db_storage")
	if err := os.MkdirAll(accDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(accDir, "real.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "outside"), filepath.Join(accDir, "link")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	r, err := repo.Init(filepath.Join(t.TempDir(), "repo"))
	if err != nil {
		t.Fatal(err)
	}
	account := discover.Account{ID: "wxid_test", Path: filepath.Join(root, "wxid_test")}
	m, res, err := Run(r, account, "dev")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Files != 1 {
		t.Fatalf("files = %d, want 1 (symlink skipped)", res.Files)
	}
	if len(m.Files) != 1 {
		t.Fatalf("manifest entries = %d, want 1", len(m.Files))
	}
}
