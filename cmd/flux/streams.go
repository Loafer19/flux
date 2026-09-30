package main

import (
	"fmt"
)

// mic shows the phone microphone state, or stops it.
func mic(args []string) error {
	if first(args) == "stop" {
		return call("mic.stop", nil)
	}
	var s struct {
		Mic *struct {
			Active   bool   `json:"active"`
			Source   string `json:"source"`
			FromName string `json:"fromName"`
			Rate     int    `json:"rate"`
			Channels int    `json:"channels"`
			Error    string `json:"error"`
		} `json:"mic"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	m := s.Mic
	switch {
	case m == nil:
		fmt.Println("No phone microphone. Start it in Flux for Android: Microphone, then Start.")
	case m.Error != "":
		fmt.Println("The phone microphone failed:", m.Error)
	case m.Active:
		fmt.Printf("%s is live as %s, %d Hz, %s\n", m.FromName, m.Source, m.Rate, channelsName(m.Channels))
	default:
		fmt.Printf("%s is starting as %s\n", m.FromName, m.Source)
	}
	return nil
}

func channelsName(n int) string {
	if n == 2 {
		return "stereo"
	}
	return "mono"
}

// remoteSettings holds the settings that give a paired device access to
// this computer.
type remoteSettings struct {
	RemoteDesktop bool `json:"remoteDesktop"`
	RemoteInput   bool `json:"remoteInput"`
}

// setRemote turns a remote setting on or off. fluxd saves the change in
// config.toml. setRemote returns the settings after the change.
func setRemote(key string, on bool) (remoteSettings, error) {
	var s struct {
		Settings remoteSettings `json:"settings"`
	}
	if err := call("settings.set", map[string]any{"key": key, "value": on}); err != nil {
		return s.Settings, err
	}
	err := callInto("state", nil, &s)
	return s.Settings, err
}

// remoteInput turns remote input on or off, or shows its state.
func remoteInput(args []string) error {
	switch first(args) {
	case "on":
		if _, err := setRemote("remoteInput", true); err != nil {
			return err
		}
		fmt.Println("Remote input is on. A paired phone, Mac, or desk peer can move the pointer and type on this computer.")
		return nil
	case "off":
		if _, err := setRemote("remoteInput", false); err != nil {
			return err
		}
		fmt.Println("Remote input is off.")
		return nil
	case "":
	default:
		return fmt.Errorf("unknown argument %q. Usage: flux-cli input [on|off]", first(args))
	}
	var s struct {
		Settings remoteSettings `json:"settings"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	if s.Settings.RemoteInput {
		fmt.Println("Remote input is on. Turn it off with: flux-cli input off")
	} else {
		fmt.Println("Remote input is off. Turn it on with: flux-cli input on")
	}
	return nil
}

// remoteDesktop turns the remote desktop on or off, shows whether a phone
// shows this screen, or stops it.
func remoteDesktop(args []string) error {
	switch first(args) {
	case "stop":
		return call("desktop.stop", nil)
	case "view":
		dev := ""
		if len(args) > 1 {
			dev = args[1]
		}
		if err := call("desktop.view", map[string]any{"device": dev}); err != nil {
			return err
		}
		fmt.Println("Showing the peer desktop. Close the player window, or run: flux-cli desktop view-stop")
		return nil
	case "view-stop":
		return call("desktop.viewStop", nil)
	case "on":
		s, err := setRemote("remoteDesktop", true)
		if err != nil {
			return err
		}
		fmt.Println("The remote desktop is on. A paired phone, Mac, or desk peer can show this screen.")
		if !s.RemoteInput {
			fmt.Println("To also control this computer from it, run: flux-cli input on")
		}
		return nil
	case "off":
		if _, err := setRemote("remoteDesktop", false); err != nil {
			return err
		}
		fmt.Println("The remote desktop is off.")
		return nil
	case "":
	default:
		return fmt.Errorf("unknown argument %q. Usage: flux-cli desktop [on|off|stop|view|view-stop]", first(args))
	}
	var s struct {
		Settings remoteSettings `json:"settings"`
		Desktop  *struct {
			Active  bool   `json:"active"`
			ToName  string `json:"toName"`
			Monitor string `json:"monitor"`
			Width   int    `json:"width"`
			Height  int    `json:"height"`
			Error   string `json:"error"`
		} `json:"desktop"`
		PeerDesktop *struct {
			Active   bool   `json:"active"`
			FromName string `json:"fromName"`
			Monitor  string `json:"monitor"`
			Width    int    `json:"width"`
			Height   int    `json:"height"`
			Player   string `json:"player"`
			Error    string `json:"error"`
		} `json:"peerDesktop"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	if pv := s.PeerDesktop; pv != nil {
		switch {
		case pv.Error != "":
			fmt.Println("Peer desktop failed:", pv.Error)
		case pv.Active:
			fmt.Printf("Showing %s", pv.FromName)
			if pv.Monitor != "" {
				fmt.Printf(" (%s)", pv.Monitor)
			}
			if pv.Width > 0 && pv.Height > 0 {
				fmt.Printf(", %dx%d", pv.Width, pv.Height)
			}
			fmt.Printf(" in %s. Stop with: flux-cli desktop view-stop\n", pv.Player)
		default:
			fmt.Printf("Starting peer desktop of %s\n", pv.FromName)
		}
	}
	v := s.Desktop
	switch {
	case v != nil && v.Error != "":
		fmt.Println("The remote desktop failed:", v.Error)
	case v != nil && v.Active:
		fmt.Printf("%s shows %s, %dx%d. Stop it with: flux-cli desktop stop\n", v.ToName, v.Monitor, v.Width, v.Height)
	case v != nil:
		fmt.Printf("%s is starting the remote desktop of %s\n", v.ToName, v.Monitor)
	case !s.Settings.RemoteDesktop:
		fmt.Println("The remote desktop is off. Turn it on with: flux-cli desktop on")
	case s.PeerDesktop == nil:
		fmt.Println("No one shows this screen. A phone uses Remote desktop; a peer: flux-cli desktop view NAME")
	}
	return nil
}

// screen shows the screen mirror state, or stops it.
func screen(args []string) error {
	if first(args) == "stop" {
		return call("screen.stop", nil)
	}
	var s struct {
		Screen *struct {
			Active   bool   `json:"active"`
			FromName string `json:"fromName"`
			Width    int    `json:"width"`
			Height   int    `json:"height"`
			Player   string `json:"player"`
			Error    string `json:"error"`
		} `json:"screen"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	v := s.Screen
	switch {
	case v == nil:
		fmt.Println("No phone screen. Start it in Flux for Android: Mirror screen.")
	case v.Error != "":
		fmt.Println("The screen mirror failed:", v.Error)
	case v.Active:
		fmt.Printf("%s shows its screen in %s, %dx%d\n", v.FromName, v.Player, v.Width, v.Height)
	default:
		fmt.Printf("%s is starting its screen mirror\n", v.FromName)
	}
	return nil
}
