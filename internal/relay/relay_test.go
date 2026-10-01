package relay

import (
	"context"
	"io"
	"net"
	"testing"
	"time"
)

const testID = "9f1c0e5b7a2d4c3e8b6a1f0d2c4e6a8b"

func TestNormalizeAddr(t *testing.T) {
	got, err := NormalizeAddr("relay.example:17777")
	if err != nil || got != "relay.example:17777" {
		t.Fatalf("got %q %v", got, err)
	}
	got, err = NormalizeAddr("tcp://127.0.0.1:19000")
	if err != nil || got != "127.0.0.1:19000" {
		t.Fatalf("tcp URL: %q %v", got, err)
	}
	got, err = NormalizeAddr("only-host")
	if err != nil || got != "only-host:17777" {
		t.Fatalf("default port: %q %v", got, err)
	}
	if _, err := NormalizeAddr(""); err == nil {
		t.Fatal("empty should fail")
	}
}

func TestSplicePair(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	srv := NewServer()
	go func() { _ = srv.Serve(ln) }()

	addr := ln.Addr().String()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	errc := make(chan error, 2)
	go func() {
		c, err := DialRegister(ctx, addr, testID)
		if err != nil {
			errc <- err
			return
		}
		defer c.Close()
		buf := make([]byte, 4)
		if _, err := io.ReadFull(c, buf); err != nil {
			errc <- err
			return
		}
		if string(buf) != "ping" {
			errc <- errString("got " + string(buf))
			return
		}
		_, err = c.Write([]byte("pong"))
		errc <- err
	}()
	time.Sleep(50 * time.Millisecond)
	go func() {
		c, err := DialJoin(ctx, addr, testID)
		if err != nil {
			errc <- err
			return
		}
		defer c.Close()
		if _, err := c.Write([]byte("ping")); err != nil {
			errc <- err
			return
		}
		buf := make([]byte, 4)
		if _, err := io.ReadFull(c, buf); err != nil {
			errc <- err
			return
		}
		if string(buf) != "pong" {
			errc <- errString("got " + string(buf))
			return
		}
		errc <- nil
	}()
	for i := 0; i < 2; i++ {
		if err := <-errc; err != nil {
			t.Fatal(err)
		}
	}
}

func TestJoinWithoutRegister(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	srv := NewServer()
	go func() { _ = srv.Serve(ln) }()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, err = DialJoin(ctx, ln.Addr().String(), testID)
	if err == nil {
		t.Fatal("join without register should fail")
	}
}

type errString string

func (e errString) Error() string { return string(e) }

func TestSameEndpoint(t *testing.T) {
	if !SameEndpoint("127.0.0.1", 9, "127.0.0.1", 9) {
		t.Fatal("equal")
	}
	if SameEndpoint("127.0.0.1", 9, "10.0.0.1", 9) {
		t.Fatal("different IP")
	}
	if !SameEndpoint("HOST", 1, "host", 1) {
		t.Fatal("case")
	}
}
