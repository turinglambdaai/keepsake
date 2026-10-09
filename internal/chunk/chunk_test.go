package chunk

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"

	"github.com/turinglambdaai/keepsake/internal/manifest"
)

func writeTemp(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return path
}

func sqliteBytes(t *testing.T, pages, pageSize int) []byte {
	t.Helper()
	if pageSize == maxSQLitePage {
		t.Fatal("64K page variant not needed in tests")
	}
	header := make([]byte, 100)
	copy(header, sqliteHeader)
	// The real format stores the page size in bytes (big-endian uint16);
	// 65536 is encoded as 1 and handled by the reader.
	binary.BigEndian.PutUint16(header[16:18], uint16(pageSize))
	data := append(header, make([]byte, pages*pageSize-100)...)
	for i := range data[100:] {
		data[100+i] = byte(i % 251)
	}
	return data
}

func checkCoverage(t *testing.T, refs []manifest.ChunkRef, size int64, expectChunks int) {
	t.Helper()
	if len(refs) != expectChunks {
		t.Fatalf("got %d chunks, want %d", len(refs), expectChunks)
	}
	var offset int64
	for i, ref := range refs {
		if ref.Offset != offset {
			t.Fatalf("chunk %d offset = %d, want %d", i, ref.Offset, offset)
		}
		offset += ref.Size
	}
	if offset != size {
		t.Fatalf("chunks cover %d bytes, file is %d", offset, size)
	}
}

func TestPlanFileGenericIsSingleChunk(t *testing.T) {
	dir := t.TempDir()
	path := writeTemp(t, dir, "photo.dat", []byte("not a database at all"))

	refs, err := PlanFile(path)
	if err != nil {
		t.Fatalf("PlanFile: %v", err)
	}
	checkCoverage(t, refs, int64(len("not a database at all")), 1)
}

func TestPlanFileSQLitePageAligned(t *testing.T) {
	dir := t.TempDir()
	const pageSize = 4096
	data := sqliteBytes(t, 5, pageSize) // 5 pages
	path := writeTemp(t, dir, "msg0.db", data)

	refs, err := PlanFile(path)
	if err != nil {
		t.Fatalf("PlanFile: %v", err)
	}
	checkCoverage(t, refs, int64(len(data)), 5)

	// Every hash must match its page content.
	for i, ref := range refs {
		want := HashBytes(data[i*pageSize : (i+1)*pageSize])
		if ref.Hash != want {
			t.Fatalf("chunk %d hash mismatch", i)
		}
	}
}

func TestPlanFileSharedPages(t *testing.T) {
	dir := t.TempDir()
	const pageSize = 4096

	v1 := sqliteBytes(t, 5, pageSize)
	v2 := append([]byte{}, v1...)
	copy(v2[100:], "\x01\x02\x03\x04") // mutate the first page only
	path := writeTemp(t, dir, "msg0.db", v1)

	first, err := PlanFile(path)
	if err != nil {
		t.Fatalf("PlanFile v1: %v", err)
	}
	if err := os.WriteFile(path, v2, 0o644); err != nil {
		t.Fatalf("rewrite: %v", err)
	}
	second, err := PlanFile(path)
	if err != nil {
		t.Fatalf("PlanFile v2: %v", err)
	}

	shared := 0
	for i := range first {
		if first[i].Hash == second[i].Hash {
			shared++
		}
	}
	if shared != 4 {
		t.Fatalf("expected 4 shared pages after one-page edit, got %d", shared)
	}
}

func TestPlanFileEmptyFile(t *testing.T) {
	dir := t.TempDir()
	path := writeTemp(t, dir, "empty.bin", nil)

	refs, err := PlanFile(path)
	if err != nil {
		t.Fatalf("PlanFile: %v", err)
	}
	if len(refs) != 0 {
		t.Fatalf("empty file should produce no chunks, got %d", len(refs))
	}
}
