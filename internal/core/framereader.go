package core

import (
	"encoding/binary"
	"fmt"
	"io"
)

// frameReader reads the framed H.264 stream that pumpDesktop writes: a
// big-endian uint32 size, 1 byte of flags, and the data. The first frame
// is usually frameFormat (width and height). Later frames are Annex-B
// H.264 (config, key, or delta).
type frameReader struct {
	r   io.Reader
	buf []byte
}

const maxFrameBytes = 16 << 20

func newFrameReader(r io.Reader) *frameReader { return &frameReader{r: r} }

// next returns the next frame flags and a copy of its data, or io.EOF.
func (fr *frameReader) next() (flags byte, data []byte, err error) {
	var hdr [5]byte
	if _, err := io.ReadFull(fr.r, hdr[:]); err != nil {
		return 0, nil, eof(err)
	}
	size := binary.BigEndian.Uint32(hdr[:4])
	flags = hdr[4]
	if size > maxFrameBytes {
		return 0, nil, fmt.Errorf("a frame of %d bytes is too large", size)
	}
	if cap(fr.buf) < int(size) {
		fr.buf = make([]byte, size)
	}
	data = fr.buf[:size]
	if _, err := io.ReadFull(fr.r, data); err != nil {
		return 0, nil, eof(err)
	}
	out := make([]byte, len(data))
	copy(out, data)
	return flags, out, nil
}

// formatSize reads width and height from a frameFormat payload.
func formatSize(data []byte) (w, h int, ok bool) {
	if len(data) < 4 {
		return 0, 0, false
	}
	return int(binary.BigEndian.Uint16(data[:2])), int(binary.BigEndian.Uint16(data[2:4])), true
}
