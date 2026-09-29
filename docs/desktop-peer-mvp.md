# Desktop peer MVP

[Documentation index](README.md)

This note is the design for two or more Omarchy computers that each run `fluxd` and pair with each other.
Clipboard text, clipboard images, and file share should work with no phone and no Mac in the path.
The reachability rule below is accepted: each desk accepts inbound TCP 1716–1764 from the other.

The work lives on the fork branch `docs/desktop-peer-mvp`.
Nothing here is an upstream pull request.

## Decision

A desktop peer is another `fluxd`.
The phone app and the Mac app stay remotes: they open `flux.tunnel`, and this computer dials them.
A peer does not advertise `flux.tunnel` as outgoing, and this computer must not treat it as a phone.

No new packet type for the MVP.
Pairing, clipboard, and share already run between two daemons in `internal/e2e/e2e_test.go` (`TestTwoDaemons`) on loopback.
The MVP makes that path a real device role on a LAN or Tailscale link, and keeps phone-only features off that role.

## What already happens

`fluxd` is the desktop side.
Its device id is the CN of `~/.local/share/flux/certificate.pem`.
`proto.DeviceType` reports `laptop` when sysfs says so, and `desktop` otherwise.
`proto.NewIdentity` advertises one fixed capability set in `internal/proto/identity.go`: every phone-facing type this daemon accepts or sends.
That set stays.
Phones and Macs read it.
The peer filter belongs in the device view, not in a second identity.

The phone and the Mac are remotes.
Both listen, both send `flux.tunnel` in outgoing capabilities, and `fluxd` connects out to them.
The Mac's own device type is also `desktop` or `laptop` (`macos/Sources/FluxKit/Core/FluxCore.swift`).
`Identity.isFlux` on the Mac is "the other side is a desktop or laptop whose incoming list contains `flux.tunnel`".
That is how the Mac recognizes `fluxd`.
A peer is the same shape with one extra check: outgoing does not contain `flux.tunnel`.
The Mac fails that check because `SharePlugin` and `BrowsePlugin` send `flux.tunnel`.
A phone fails it because its device type is `phone` or `tablet`.

Discovery has three paths, all in `internal/lan` and `internal/core/daemon.go`:

1. UDP identity broadcasts on port 1716.
2. mDNS `_kdeconnect._udp` through Avahi. `fluxd` publishes and browses. `onMDNS` dials the resolved address.
3. After pairing, `dialKnown` dials `lastIp` and then the extra addresses stored on that device.

`~/.config/flux/config.toml` holds this computer's name, folders, and feature switches.
It does not hold peer addresses.
Paired devices, pinned certificates, `lastIp`, `lastPort`, and extra addresses live in `~/.local/share/flux/devices.json` (`internal/config/trust.go`).
`flux-cli addresses add` writes those extra addresses.
Tailscale is one of them.
`docs/tailscale.md` already says mDNS and UDP do not cross Tailscale, and the first pair happens on a network where TCP connects.
The same rule applies to a second desk.

The state list hides an unpaired device until a TLS link exists (`internal/core/api.go`).
mDNS alone does not put a row in the window.
Both daemons dial.
`lan.Preferred` keeps the socket opened by the device with the larger id when the two handshakes overlap, so the links do not kill each other.

Pairing is `kdeconnect.pair` with an 8-character key from `proto.VerificationKey`, a 30 second timer, and a 30 minute clock skew check (`internal/core/pairing.go`).
The certificate is pinned in `devices.json` on accept.
The next link must present that certificate.
Unpair deletes the pin.

`handlePacket` drops every packet except `kdeconnect.pair` and `flux.tunnel` until the device is paired.
Share and clipboard already sit behind that gate.

Clipboard text is `kdeconnect.clipboard` on the TLS link.
`clipboard.send` and `auto_clipboard` already do this both ways.
Clipboard images are `flux.clipboard.image` plus a payload, from the merged image sync (issue 32).
Both daemons already list that type as incoming and outgoing.
`SendClipboard` sends an image when the other side accepts the type.
Between two daemons it does.

Files are `kdeconnect.share.request` plus a payload (`internal/core/share.go`).
`SendWithPayload` uses a tunnel only when the peer lists `flux.tunnel` as outgoing (`lan.Link.CanTunnel`).
A peer does not, so the sender listens on a port from 1739 to 1764 and the receiver dials in.
`TestTwoDaemons` already sends a file this way on loopback, keeps the transfer history, reconnects after a restart, and reaches the other daemon through an extra address when the last IP is dead.

`Device.plugins` builds the feature list the window reads (`internal/core/device.go`).
Browse storage is `sftp`, and `sharesStorage` is false for device types `desktop` and `laptop`.
Ring is `findmyphone`, which `fluxd` does not accept, and `ring` already returns an error for a computer.
Messages need `kdeconnect.sms.messages`, which `fluxd` does not send.

The window still shows Phone commands and Notifications for every selected device (`gui/qml/FluxView.qml`).
The pair notification still says "the phone" (`internal/core/pairing.go`).
`onPairedLink` sends battery, the command list, clipboard connect, a notification request, Do Not Disturb, remote-input state, and herdr to any peer that accepts those types.
Another `fluxd` accepts herdr, Do Not Disturb, and remote-input state, because those types are in the shared identity.
That is the behavior the MVP must narrow.

## Peer role

Add `role` on the device view:

| Role | Rule |
| --- | --- |
| `peer` | Device type `desktop` or `laptop`, incoming contains `flux.tunnel`, outgoing does not contain `flux.tunnel` |
| `remote` | Everything else that links: phone, tablet, Mac, or a KDE Connect device |

`fluxApp()` stays "outgoing contains `flux.tunnel`".
That remains the phone and the Mac.
A peer is not a `fluxApp`.

Do not add `flux.tunnel` to `fluxd` outgoing.
That flag means "this side opens tunnel listeners for a desktop".
The phone and the Mac depend on it.
A peer that advertised it would look like a remote to `CanTunnel` and to `fluxApp`.

Do not remove phone capabilities from the identity this daemon broadcasts.
The phone still needs them when it is the other side.

## Packets

Reuse, both directions, only after pair:

| Use | Packet |
| --- | --- |
| Pair, reject, unpair | `kdeconnect.pair` |
| Clipboard text, including connect-on-link | `kdeconnect.clipboard`, `kdeconnect.clipboard.connect` |
| Clipboard image | `flux.clipboard.image` with the existing payload |
| File, text, and URL share | `kdeconnect.share.request`, `kdeconnect.share.request.update` |
| Presence | `kdeconnect.identity`, `kdeconnect.ping`, `kdeconnect.battery` |

Leave these on the wire identity so a phone still works.
For a `peer`, do not send them on connect, and drop them if one arrives:

- `kdeconnect.mousepad.request` and `flux.input` (pointer and remote desktop)
- `flux.approve` (fingerprint and sudo)
- `flux.herdr` and `flux.shortcuts`
- `kdeconnect.sftp` and `kdeconnect.sftp.request` (phone storage and Browse PC toward this peer)
- `kdeconnect.notification.request` (there is no phone notification stream on a desk)
- `flux.dnd`, `kdeconnect.telephony`, SMS, webcam, mic, screen, and `flux.desktop`

`kdeconnect.notification` from `flux-cli notify` already displays on the other daemon in `TestTwoDaemons`.
Keep that.
It is a desktop notification, not a phone inbox.

No new packet, port, or capability string in this MVP.

## Pairing

Same 8-character key and the same Accept and Reject actions.
The desktop notification names the other computer, not "the phone", when the incoming device is a peer.
The window pair card stays the one in `gui/qml/components/PairCard.qml`.
Reconnect uses the pinned certificate and `lastIp` / `lastPort`, as a phone does today.
Unpair removes the pin on both sides. `TestTwoDaemons` already covers that.

## Discovery and addresses

LAN: keep UDP 1716 and mDNS `_kdeconnect._udp`.
Both daemons already publish and dial.
The device shows in the list once the TLS link is up, then the user pairs it.
`flux-cli pair "name"` uses that row.

Tailscale and any other extra host: `flux-cli addresses add` after the first pair, stored in `devices.json`, dialed by `dialKnown`.
Five addresses maximum, host only, no port, same checks as today.
`config.toml` gains no address keys.

Issue 7 is an Android list that shows one computer twice because Avahi publishes IPv4 and IPv6.
`onMDNS` already keys the desktop list by device id, and `resolve` drops non-IPv4 answers.
A peer row does not duplicate today.
Phase 3 touches that only if a desk actually shows two rows for one peer.

## Reachability

Accepted for the MVP: each desk accepts inbound TCP 1716–1764 from the other.

`fluxd` listens on a TCP port from 1716 to 1764.
The other daemon dials that port.
File and image payloads use a second TCP connection on 1739–1764, from the receiver back to the sender.
The default Omarchy firewall allows mDNS and blocks other inbound TCP.
A phone still works, because the phone listens and this computer dials out.
Two desks need each side to accept inbound TCP 1716–1764 from the other.

The MVP does not add a firewall rule in the package.
`docs/install.md` already says install adds none.
The setup doc tells the user to allow that range from the other desk, on the LAN or on the tailnet.
The first pair still needs that path.
Tailscale does not discover or pair by itself.

Text clipboard needs only the main TLS link.
Files and clipboard images need the payload ports in the same range.

An outbound-only payload, where neither desk accepts a new inbound connection, is a later protocol design.
It is not this MVP.
Putting `flux.tunnel` on `fluxd` would still need a listener on the receiving desk, and it would mark the desk as a remote.

## Window and CLI

`plugins` for a peer are `clipboard`, `share`, and `battery` when the peer sends battery.
They are not `sftp`, `sms`, `findmyphone`, `notifications`, `runcommand`, or `connectivity`.
Browse storage stays inactive.
Ring stays hidden.
The Phone commands tab is hidden while a peer is selected.
Overview, Clipboard, and Files stay.
Notifications stay, because `notify` between daemons already works.

The device row keeps the existing desktop or laptop icon (`Fmt.kindIcon`).
An empty device type still falls back to `phone` for an old packet.
A peer always has a type, so it does not take that fallback.

`flux-cli status` prints the role next to the device type.
`flux-cli --device <id-or-name> send` and `flux-cli clip` already take a device id or name.
They keep working for a peer with no new subcommand.

## Security

Share, clipboard, and `notify` run only after pair, as they do now.
Remote input stays off for a peer even when `remote_input` is true on this computer.
`flux.approve` from a peer is ignored.
Enrollment and the root helper do not gain a peer path.
`herdr_control` does not apply to a peer.
Browse PC is not offered to a peer in this MVP.
The SFTP server inside a tunnel stays a phone and Mac feature.

## Compatibility

A paired phone is still `role: remote`.
Its plugins, Browse storage, SMS, ring, camera, and approval stay on the current checks.
A paired Mac stays `role: remote` because it sends `flux.tunnel`.
KDE Connect devices that are not Flux stay `remote` and keep today's plugin inference.
Existing `devices.json` entries gain no required field.
`role` is computed from the live identity.

## Tests

Extend `TestTwoDaemons`:

- Each side reports the other as `role: peer`.
- Plugins are clipboard, share, and battery only.
- `sftp` is absent, and a browse call does not open storage.
- `ring` still fails.
- Clipboard text still arrives.
- A clipboard image arrives when both sides accept `flux.clipboard.image`.
- A file still lands in the download directory and the transfer history.
- A `flux.approve` packet and a mousepad packet from the peer do not change local state.

Add a unit test for the role rule: fluxd peer, Mac-shaped remote (laptop plus outgoing `flux.tunnel`), phone, and a desktop that does not accept `flux.tunnel`.

`make build test vet` is the check.
`make snapshot` runs if the QML tabs or the pair copy change.

## Phase 2 files

Change these in the MVP implementation.

| Path | Change |
| --- | --- |
| `internal/core/device.go` | `role`, peer plugin list |
| `internal/core/daemon.go` | `onPairedLink` skips herdr, input, DND, and notification request for a peer |
| `internal/core/handlers.go` | Drop input, approve, herdr, shortcuts, sftp, and phone streams from a peer |
| `internal/core/pairing.go` | Pair notification names the computer |
| `internal/core/api.go` | `role` on the state JSON |
| `cmd/flux/main.go` | `status` prints the role |
| `gui/qml/FluxView.qml` | Hide Phone commands for a peer. Browse and messages stay on their plugin checks |
| `gui/qml/tools/Snapshot.qml` | One paired peer fixture |
| `internal/e2e/e2e_test.go` | Role, plugins, image, and the ignored packets |
| `internal/core/device` test | Role table |
| `docs/architecture.md` | One short paragraph on the peer role |
| `docs/cli.md` | Status column |
| `docs/README.md` | Link this note |

Leave Android, the Mac app, `internal/approve`, and the firewall package files alone.

## Later

Phase 3 is the setup page [Connect two computers](desktop-peer.md).
A paired peer stays on the dial schedule from the merged issue 49: `TestPeerDialBackoff` covers the fast and slow intervals.
Two mDNS reports for one id stay one device: `TestMDNSReportsStayOneDevice`.
An IPv6 mDNS answer is dropped before it becomes a row.
The Android list can still show one computer twice. That is issue 7, and this phase does not change the phone app.

The pointer crosses one screen edge through `flux.edge`, configured with `edge_side` and `edge_device`.
Clicks and the keyboard stay on the computer where they were pressed, and `remote_input` stays the phone touchpad.
Still separate: drag across that edge, focus follow, and a real phone storage server.
