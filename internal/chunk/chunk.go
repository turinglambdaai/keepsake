// Package chunk splits files into content-addressed chunks.
//
// Two policies exist because WeChat data has two very different shapes:
//
//   - Media files (images, videos, attachments) are content-addressed by
//     WeChat itself and immutable once written — one whole-file chunk is
//     optimal.
//   - SQLite databases change on every snapshot but only in a few pages.
//     Splitting them on their own page boundary makes consecutive snapshots
//     share all unchanged pages, so a multi-GB message store deltas down to
//     megabytes.
package chunk

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"os"

	"github.com/turinglambdaai/keepsake/internal/manifest"
)

// sqliteHeader is the magic every SQLite 3 database starts with.
var sqliteHeader = []byte("SQLite format 3\x00")

// sqliteHeaderLen is also how many bytes we must read before deciding policy.
const sqliteHeaderLen = 16

// minSQLitePage and maxSQLitePage bound the legal page sizes in the format
// spec (stored as a big-endian uint16 at offset 16; value 1 means 64KiB).
const (
	minSQLitePage = 512
	maxSQLitePage = 65536
)

// PlanFile chunks the file at path according to its detected type and returns
// the chunk references covering the whole file, in order.
func PlanFile(path string) ([]manifest.ChunkRef, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	pageSize, err := detectPageSize(f)
	if err != nil {
		return nil, err
	}
	if pageSize == 0 { // not a SQLite database: one whole-file chunk
		return planWholeFile(f)
	}
	return planPageAligned(f, pageSize)
}

// detectPageSize reads the file head and returns the SQLite page size, or 0
// when the file is not a SQLite database.
func detectPageSize(f *os.File) (int, error) {
	head := make([]byte, 100)
	if _, err := io.ReadFull(f, head); err != nil {
		if errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
			// Smaller than a SQLite header: rewind and treat as generic.
			if _, seekErr := f.Seek(0, io.SeekStart); seekErr != nil {
				return 0, seekErr
			}
			return 0, nil
		}
		return 0, err
	}
	for i := range sqliteHeader {
		if head[i] != sqliteHeader[i] {
			if _, seekErr := f.Seek(0, io.SeekStart); seekErr != nil {
				return 0, seekErr
			}
			return 0, nil
		}
	}
	page := int(binary.BigEndian.Uint16(head[16:18]))
	if page == 1 {
		page = maxSQLitePage
	}
	if page < minSQLitePage || page > maxSQLitePage {
		return 0, nil // malformed header: treat as generic file
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return 0, err
	}
	return page, nil
}

func planWholeFile(f *os.File) ([]manifest.ChunkRef, error) {
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() == 0 {
		return nil, nil // empty file: nothing to store, restore just creates it
	}
	hash, err := hashReader(f)
	if err != nil {
		return nil, err
	}
	return []manifest.ChunkRef{{Hash: hash, Offset: 0, Size: info.Size()}}, nil
}

func planPageAligned(f *os.File, pageSize int) ([]manifest.ChunkRef, error) {
	var refs []manifest.ChunkRef
	buf := make([]byte, pageSize)
	var offset int64
	for {
		n, err := io.ReadFull(f, buf)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) {
			return nil, err
		}
		sum := sha256.Sum256(buf[:n])
		refs = append(refs, manifest.ChunkRef{
			Hash:   hex.EncodeToString(sum[:]),
			Offset: offset,
			Size:   int64(n),
		})
		offset += int64(n)
		if errors.Is(err, io.ErrUnexpectedEOF) {
			break
		}
	}
	return refs, nil
}

func hashReader(r io.Reader) (string, error) {
	h := sha256.New()
	if _, err := io.Copy(h, r); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// HashBytes is a small helper for tests and tools.
func HashBytes(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
