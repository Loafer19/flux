package core

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

func TestFrameReaderAndCopyPeerDesktop(t *testing.T) {
	var src bytes.Buffer
	writeFrame := func(flags byte, data []byte) {
		_ = binary.Write(&src, binary.BigEndian, uint32(len(data)))
		src.WriteByte(flags)
		src.Write(data)
	}
	size := binary.BigEndian.AppendUint16(binary.BigEndian.AppendUint16(nil, 1280), 720)
	writeFrame(frameFormat, size)
	writeFrame(frameConfig, []byte{0, 0, 0, 1, 0x67, 0x42})
	writeFrame(frameKey, []byte{0, 0, 0, 1, 0x65, 0x88})

	var out bytes.Buffer
	var gotW, gotH int
	err := copyPeerDesktop(bytes.NewReader(src.Bytes()), &out, func(w, h int) {
		gotW, gotH = w, h
	})
	if err != io.EOF {
		t.Fatalf("err %v", err)
	}
	if gotW != 1280 || gotH != 720 {
		t.Fatalf("size %dx%d", gotW, gotH)
	}
	want := append([]byte{0, 0, 0, 1, 0x67, 0x42}, 0, 0, 0, 1, 0x65, 0x88)
	if !bytes.Equal(out.Bytes(), want) {
		t.Fatalf("h264 %x", out.Bytes())
	}
}

func TestPeerIgnoresAllowsDesktopAndMousepad(t *testing.T) {
	if peerIgnores(protoTypeFluxDesktop) || peerIgnores(protoTypeMousepad) {
		t.Fatal("desktop and mousepad must pass peer filter")
	}
	if !peerIgnores(protoTypeApprove) {
		t.Fatal("approve must stay ignored")
	}
}

// Local string aliases so this file does not need the proto import only for constants in one test.
const (
	protoTypeFluxDesktop = "flux.desktop"
	protoTypeMousepad    = "flux.mousepad.request"
	protoTypeApprove     = "flux.approve"
)
