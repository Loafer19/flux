package main

import (
	"fmt"
	"net"
	"os"
	"strings"

	"flux/internal/relay"
)

// relayCmd shows or changes the optional TCP rendezvous used when there is
// no direct LAN or Tailscale path. Prefer a direct path; relay is off by
// default.
func relayCmd(args []string) error {
	switch first(args) {
	case "on":
		if _, err := setRelay(true); err != nil {
			return err
		}
		fmt.Println("Relay is on. Prefer LAN or Tailscale when either works.")
		fmt.Println("Both computers need the same URL. Run a helper with: flux-cli relay serve")
		return nil
	case "off":
		if _, err := setRelay(false); err != nil {
			return err
		}
		fmt.Println("Relay is off. Pairing uses the LAN, Tailscale, or an invite host.")
		return nil
	case "url":
		if len(args) < 2 {
			return fmt.Errorf("Usage: flux-cli relay url HOST:PORT")
		}
		raw := strings.TrimSpace(args[1])
		addr := ""
		if raw != "" {
			var err error
			addr, err = relay.NormalizeAddr(raw)
			if err != nil {
				return err
			}
		}
		if err := call("settings.set", map[string]any{"key": "relayURL", "value": addr}); err != nil {
			return err
		}
		if addr == "" {
			fmt.Println("Relay URL cleared")
		} else {
			fmt.Printf("Relay URL is %s\n", addr)
		}
		return nil
	case "serve":
		return relayServe(args[1:])
	case "":
	default:
		return fmt.Errorf("unknown argument %q. Usage: flux-cli relay [on|off|url HOST:PORT|serve]", first(args))
	}
	var s struct {
		Settings struct {
			Relay    bool   `json:"relay"`
			RelayURL string `json:"relayURL"`
		} `json:"settings"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	if s.Settings.Relay {
		url := s.Settings.RelayURL
		if url == "" {
			url = "(not set)"
		}
		fmt.Printf("Relay is on. URL: %s\n", url)
		fmt.Println("Direct LAN or Tailscale is still preferred when either works.")
		fmt.Println("Turn it off with: flux-cli relay off")
	} else {
		fmt.Println("Relay is off. Turn it on with: flux-cli relay on")
		if s.Settings.RelayURL != "" {
			fmt.Printf("Saved URL: %s\n", s.Settings.RelayURL)
		}
	}
	return nil
}

func setRelay(on bool) (bool, error) {
	if err := call("settings.set", map[string]any{"key": "relay", "value": on}); err != nil {
		return false, err
	}
	var s struct {
		Settings struct {
			Relay bool `json:"relay"`
		} `json:"settings"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return false, err
	}
	return s.Settings.Relay, nil
}

// relayServe runs a local TCP rendezvous for tests. Both desks dial this
// host. It is not a public TURN service.
func relayServe(args []string) error {
	listen := fmt.Sprintf(":%d", relay.DefaultPort)
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--listen" && i+1 < len(args):
			i++
			listen = args[i]
		case strings.HasPrefix(a, "--listen="):
			listen = strings.TrimPrefix(a, "--listen=")
		default:
			return fmt.Errorf("unknown relay serve argument %q. Usage: flux-cli relay serve [--listen ADDR]", a)
		}
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Flux relay listening on %s\n", ln.Addr())
	fmt.Fprintf(os.Stderr, "On each computer:\n")
	fmt.Fprintf(os.Stderr, "  flux-cli relay url %s\n", ln.Addr().String())
	fmt.Fprintf(os.Stderr, "  flux-cli relay on\n")
	fmt.Fprintf(os.Stderr, "Then pair invite / pair join as usual. Ctrl-C stops the helper.\n")
	srv := relay.NewServer()
	srv.Logf = func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "relay: "+format+"\n", args...)
	}
	return srv.Serve(ln)
}
