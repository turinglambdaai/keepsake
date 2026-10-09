package manifest

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"
)

func TestManifestJSONRoundTrip(t *testing.T) {
	m := Manifest{
		FormatVersion: FormatVersion,
		DeviceID:      "mac-mini",
		Account:       "wxid_test123",
		HostPlatform:  "darwin",
		CreatedAt:     time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC),
		Files: []FileEntry{
			{
				Path: "db_storage/msg/0.db",
				Size: 4096,
				Mode: 0o644,
				Chunks: []ChunkRef{
					{Hash: "aa", Offset: 0, Size: 4096},
				},
			},
			{
				Path: "msg/attach/abc.jpg",
				Size: 1024,
				Mode: 0o644,
				Chunks: []ChunkRef{
					{Hash: "bb", Offset: 0, Size: 1024},
				},
			},
		},
	}

	b, err := json.Marshal(&m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got Manifest
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !reflect.DeepEqual(got, m) {
		t.Fatalf("round trip mismatch:\n got %+v\nwant %+v", got, m)
	}
}

func TestTotalSize(t *testing.T) {
	m := Manifest{Files: []FileEntry{
		{Path: "a", Size: 10},
		{Path: "b", Size: 32},
	}}
	if got := m.TotalSize(); got != 42 {
		t.Fatalf("TotalSize() = %d, want 42", got)
	}
}
