package core

import (
	"crypto/x509"
	"slices"
	"time"

	"flux/internal/config"
	"flux/internal/lan"
	"flux/internal/proto"
)

// Device is one known device: paired, or seen on the network.
type Device struct {
	ID       string
	Name     string
	Type     string
	IP       string
	Port     int // TCP listener port of the device
	Version  int
	Incoming []string
	Outgoing []string
	Paired   bool
	PairedAt string
	Cert     *x509.Certificate
	LastSeen time.Time

	// App and AppVersion come from the identity of the device.
	App        string
	AppVersion string

	// Addresses are the extra host names and IP addresses of a paired
	// device. They come from the trust store.
	Addresses []string

	link     *lan.Link
	mdnsSeen time.Time
	// inviteHost is the host from a discovery-less invite. After pair,
	// fluxd keeps it as an extra address when it differs from lastIp.
	inviteHost string
	// dialTries counts the dials since the device was last seen. dialAt is
	// the time of the last dial.
	dialTries int
	dialAt    time.Time
	// inputRefused is true after fluxd logged remote input that it
	// ignored, so that it logs that once.
	inputRefused bool

	pairState string // "", "requested", or "incoming"
	pairTime  int64
	pairKey   string
	pairTimer *time.Timer

	battery       *Battery
	batteryLow    bool // the low-battery notification of this discharge showed
	notifications []*PhoneNotification
	notifDesktop  map[string]uint32
	conversations map[int64]*Conversation
	threadWait    map[int64][]chan []SmsMessage
	theme         string
}

// Battery is the battery state of a device.
type Battery struct {
	Charge   int  `json:"charge"`
	Charging bool `json:"charging"`
}

func newDevice(id string) *Device {
	return &Device{
		ID:            id,
		notifDesktop:  map[string]uint32{},
		conversations: map[int64]*Conversation{},
		threadWait:    map[int64][]chan []SmsMessage{},
	}
}

func (dev *Device) applyTrust(t config.TrustedDevice) {
	dev.Name, dev.Type, dev.IP, dev.Port = t.Name, t.Type, t.LastIP, t.LastPort
	dev.Addresses = t.Addresses
	dev.Paired, dev.PairedAt = true, t.PairedAt
	if c, err := proto.ParseCertPEM(t.CertPEM); err == nil {
		dev.Cert = c
	}
}

func (dev *Device) setIdentity(id proto.Identity) {
	dev.Name = proto.CleanName(id.DeviceName)
	dev.Type = id.DeviceType
	dev.Version = id.ProtocolVersion
	dev.Incoming = id.IncomingCapabilities
	dev.Outgoing = id.OutgoingCapabilities
	dev.App, dev.AppVersion = id.App, id.AppVersion
}

// supports reports whether the device sends packets of the type.
func (dev *Device) supports(typ string) bool { return slices.Contains(dev.Outgoing, typ) }

// accepts reports whether the device receives packets of the type.
func (dev *Device) accepts(typ string) bool { return slices.Contains(dev.Incoming, typ) }

// fluxApp reports whether the device runs Flux for Android or Flux for
// macOS. Only the Flux apps send flux.tunnel.
func (dev *Device) fluxApp() bool { return dev.supports(proto.TypeFluxTunnel) }

// peer reports whether the device is another fluxd. fluxd accepts
// flux.tunnel and does not send it. A phone or a Mac sends flux.tunnel.
// A desktop that does not accept flux.tunnel is some other program.
func (dev *Device) peer() bool {
	if dev.Type != "desktop" && dev.Type != "laptop" {
		return false
	}
	return dev.accepts(proto.TypeFluxTunnel) && !dev.supports(proto.TypeFluxTunnel)
}

// role is "peer" for another fluxd and "remote" for a phone, a tablet, a
// Mac, or any other device. It follows the live identity.
func (dev *Device) role() string {
	if dev.peer() {
		return "peer"
	}
	return "remote"
}

// peerIgnores reports a packet that a desktop peer must not apply on this
// computer. Clipboard, share, ping, battery, and notifications stay.
// Remote desktop (flux.desktop) and remote input (mousepad) are allowed
// when the matching settings are on: runDesktop and handleMousepad gate them.
// A peer still must not run this computer's commands, approve, or phone streams.
func peerIgnores(typ string) bool {
	switch typ {
	case proto.TypeFluxApprove, proto.TypeFluxHerdr,
		proto.TypeFluxShortcuts, proto.TypeSftp, proto.TypeSftpRequest,
		proto.TypeNotificationRequest, proto.TypeFluxDnd, proto.TypeTelephony,
		proto.TypeSmsMessages, proto.TypeFluxWebcam, proto.TypeFluxMic,
		proto.TypeFluxScreen, proto.TypeRunCommandRequest:
		return true
	}
	return false
}

// plugins returns the features that the device offers to this computer.
// The window uses them to show or hide tabs. Each check looks at the
// direction that the feature needs.
// A peer offers clipboard, share, battery, and desktop. It does not offer phone
// storage, SMS, ring, or phone notifications.
func (dev *Device) plugins() []string {
	if dev.peer() {
		out := []string{}
		if dev.supports(proto.TypeClipboard) || dev.accepts(proto.TypeClipboard) {
			out = append(out, "clipboard")
		}
		if dev.accepts(proto.TypeShare) {
			out = append(out, "share")
		}
		if dev.supports(proto.TypeBattery) {
			out = append(out, "battery")
		}
		// Peer remote desktop: this desk can ask the peer to stream when
		// the peer accepts flux.desktop (every fluxd does).
		if dev.accepts(proto.TypeFluxDesktop) {
			out = append(out, "desktop")
		}
		return out
	}
	checks := []struct {
		name string
		ok   bool
	}{
		{"battery", dev.supports(proto.TypeBattery)},
		{"clipboard", dev.supports(proto.TypeClipboard) || dev.accepts(proto.TypeClipboard)},
		{"share", dev.accepts(proto.TypeShare)},
		{"notifications", dev.supports(proto.TypeNotification)},
		{"findmyphone", dev.accepts(proto.TypeFindMyPhone)},
		{"sms", dev.supports(proto.TypeSmsMessages)},
		{"runcommand", dev.supports(proto.TypeRunCommandRequest)},
	}
	out := []string{}
	for _, c := range checks {
		if c.ok {
			out = append(out, c.name)
		}
	}
	return out
}

// DeviceView is the device as the UI sees it.
type DeviceView struct {
	ID            string               `json:"id"`
	Name          string               `json:"name"`
	Type          string               `json:"type"`
	IP            string               `json:"ip"`
	Addresses     []string             `json:"addresses"`
	Paired        bool                 `json:"paired"`
	Online        bool                 `json:"online"`
	PairState     string               `json:"pairState"`
	PairKey       string               `json:"pairKey"`
	PairedAt      string               `json:"pairedAt"`
	Role          string               `json:"role"`
	LastSeen      int64                `json:"lastSeen"`
	Battery       *Battery             `json:"battery"`
	Plugins       []string             `json:"plugins"`
	Notifications []*PhoneNotification `json:"notifications"`
	Conversations []*Conversation      `json:"conversations"`

	// App and AppVersion name the Flux app of the device and its version,
	// or are empty for an earlier app. AppUpdate is the version of a newer
	// Android app in the latest release, or "".
	App        string `json:"app"`
	AppVersion string `json:"appVersion"`
	AppUpdate  string `json:"appUpdate"`
}

func (dev *Device) view() DeviceView {
	state := dev.pairState
	if state == "" && dev.Paired {
		state = "paired"
	} else if state == "" {
		state = "none"
	}
	v := DeviceView{
		ID: dev.ID, Name: dev.Name, Type: dev.Type, IP: dev.IP, Addresses: dev.Addresses,
		Paired: dev.Paired, Online: dev.link != nil,
		PairState: state, PairKey: dev.pairKey, PairedAt: dev.PairedAt, Role: dev.role(),
		Battery: dev.battery,
		Plugins: dev.plugins(), Notifications: dev.notifications,
		App: dev.App, AppVersion: dev.AppVersion,
	}
	if v.Type == "" {
		v.Type = "phone"
	}
	if !dev.LastSeen.IsZero() {
		v.LastSeen = dev.LastSeen.Unix()
	}
	if v.Notifications == nil {
		v.Notifications = []*PhoneNotification{}
	}
	if v.Addresses == nil {
		v.Addresses = []string{}
	}
	v.Conversations = sortedConversations(dev.conversations)
	return v
}
