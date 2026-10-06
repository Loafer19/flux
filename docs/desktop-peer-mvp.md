# Desktop peer

[Documentation index](README.md)

This note is the role decision for two or more Omarchy computers that each run `fluxd` and pair with each other.
Clipboard text, clipboard images, and file share work with no phone and no Mac in the path.
Each desk accepts inbound TCP 12070–12108 from the other.
The setup steps are in [Connect two computers](desktop-peer.md).

The code is on `master` of this fork.
It is not a separate branch, and this note is not an upstream pull request.

The first cut reused pairing, clipboard, and file share.
Later cuts added `flux.edge` (pointer, clicks, and scroll), a discovery-less invite, an optional TCP relay, desk-to-desk remote desktop, and home browse.
Where this note and [Connect two computers](desktop-peer.md) disagree, the setup page matches the window.

## Decision

A desktop peer is another `fluxd`.
The phone app and the Mac app stay remotes: they open `flux.tunnel`, and this computer dials them.
A peer does not advertise `flux.tunnel` as outgoing, and this computer must not treat it as a phone.

Pairing, clipboard, and share run between two daemons in `internal/e2e/e2e_test.go` (`TestTwoDaemons`) on loopback.
The role makes that path a real device on a LAN or Tailscale link, and keeps phone-only features off that role.

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

1. UDP identity broadcasts on port 12100.
2. mDNS `_flux._udp` through Avahi. `fluxd` publishes and browses. `onMDNS` dials the resolved address.
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

Pairing is `kdeconnect.pair` with a 16-character key from `proto.VerificationKey`, a 30 second timer, and a 30 minute clock skew check (`internal/core/pairing.go`).
The key is the first 8 bytes of a SHA-256, as uppercase hex, in 4 groups of 4.
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
A peer does not, so the sender listens on a port from 12070 to 12099 and the receiver dials in.
`TestTwoDaemons` already sends a file this way on loopback, keeps the transfer history, reconnects after a restart, and reaches the other daemon through an extra address when the last IP is dead.

`Device.plugins` builds the feature list the window reads (`internal/core/device.go`).
A peer offers clipboard, share, battery, desktop, and home browse.
Ring is `findmyphone`, which `fluxd` does not accept, and `ring` returns an error for a computer.
Messages need `kdeconnect.sms.messages`, which `fluxd` does not send.

Phone commands are hidden while a peer is selected (`gui/qml/FluxView.qml`).
The pair notification names the other computer when the incoming device is a peer.
`peerIgnores` drops approve, herdr, shortcuts, a notification request, Do Not Disturb, telephony, SMS, webcam, mic, the phone screen, and run-command from a peer.
Clipboard, share, ping, battery, and a desktop notification stay.
`flux.desktop` and `kdeconnect.mousepad.request` stay, and the remote-desktop and remote-input switches gate them.
Home browse uses `kdeconnect.sftp.request`.

## Peer role

The device view has `role`:

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

- `flux.approve` (fingerprint and sudo)
- `flux.herdr` and `flux.shortcuts`
- `kdeconnect.notification.request` (there is no phone notification stream on a desk)
- `flux.dnd`, `kdeconnect.telephony`, SMS, webcam, mic, the phone screen, and run-command

`kdeconnect.notification` from `flux-cli notify` displays on the other daemon.
Keep that.
It is a desktop notification, not a phone inbox.

`flux.edge` carries the screen-edge pointer, clicks, and scroll.
It does not use `remote_input`.
The keyboard stays on the computer where the keys are pressed and ends the lease.
`flux.desktop` and `kdeconnect.mousepad.request` are the desk remote-desktop path.
Mouse and keys from that viewer run only while `remote_input` is on.
Home browse uses the existing SFTP request.
The first cut added none of these.

## Pairing

Same 16-character key and the same Accept and Reject actions.
The desktop notification names the other computer, not "the phone", when the incoming device is a peer.
The window pair card stays the one in `gui/qml/components/PairCard.qml`.
Reconnect uses the pinned certificate and `lastIp` / `lastPort`, as a phone does today.
Unpair removes the pin on both sides. `TestTwoDaemons` already covers that.

## Discovery and addresses

LAN: UDP 12100 and mDNS `_flux._udp`. The old KDE Connect ports are not used.
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

Accepted for the MVP: each desk accepts inbound TCP 12070–12108 from the other.

`fluxd` listens on a TCP port from 12100 to 12108.
The other daemon dials that port.
File and image payloads use a second TCP connection on 12070–12099, from the receiver back to the sender.
The default Omarchy firewall allows mDNS and blocks other inbound TCP.
A phone still works, because the phone listens and this computer dials out.
Two desks need each side to accept inbound TCP 12070–12108 from the other.

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

`plugins` for a peer are `clipboard`, `share`, `battery` when the peer sends battery, `desktop`, and `browse`.
They are not `sms`, `findmyphone`, `notifications`, `runcommand`, or `connectivity`.
Home browse is on Overview.
Ring stays hidden.
The Phone commands tab is hidden while a peer is selected.
Overview, Clipboard, and Files stay.
Notifications stay, because `notify` between daemons already works.
Screen edge and view desktop are on Overview.
Network shows the device row, and Stop while a desk view is live.

The device row keeps the existing desktop or laptop icon (`Fmt.kindIcon`).
An empty device type still falls back to `phone` for an old packet.
A peer always has a type, so it does not take that fallback.

`flux-cli status` prints the role next to the device type.
`flux-cli --device <id-or-name> send` and `flux-cli clip` already take a device id or name.
They keep working for a peer with no new subcommand.

## Security

Share, clipboard, and `notify` run only after pair, as they do now.
Screen-edge clicks use `flux.edge` and do not need `remote_input`.
Desk remote desktop sends `kdeconnect.mousepad.request` only when `remote_input` is on.
`flux.approve` from a peer is ignored.
Enrollment and the root helper do not gain a peer path.
`herdr_control` does not apply to a peer.
Home browse of a paired computer is on.
Ring, SMS, camera, and fingerprint approval are not.

## Compatibility

A paired phone is still `role: remote`.
Its plugins, Browse storage, SMS, ring, camera, and approval stay on the current checks.
A paired Mac stays `role: remote` because it sends `flux.tunnel`.
KDE Connect devices that are not Flux stay `remote` and keep today's plugin inference.
Existing `devices.json` entries gain no required field.
`role` is computed from the live identity.

## Tests

`TestTwoDaemons` covers two daemons on loopback:

- Each side reports the other as `role: peer`.
- Plugins include clipboard, share, and battery. Desktop and browse are peer plugins too.
- `ring` fails for a computer.
- Clipboard text still arrives.
- A clipboard image arrives when both sides accept `flux.clipboard.image`.
- A file still lands in the download directory and the transfer history.
- A `flux.approve` packet from a peer does not change local state.
- A mousepad packet from a peer runs only while remote input is on.

The role rule has a unit test: fluxd peer, Mac-shaped remote (laptop plus outgoing `flux.tunnel`), phone, and a desktop that does not accept `flux.tunnel`.

`make build test vet` is the check.
`make snapshot` runs if the QML tabs or the pair copy change.

## First cut

These files landed the role. Later cuts added the edge, the invite, the relay, desk remote desktop, and home browse on top. The handler row does not drop SFTP or remote desktop.

| Path | Change |
| --- | --- |
| `internal/core/device.go` | `role`, peer plugin list |
| `internal/core/daemon.go` | `onPairedLink` skips herdr, input, DND, and notification request for a peer |
| `internal/core/handlers.go` | Drop approve, herdr, shortcuts, and phone streams from a peer |
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

The setup page is [Connect two computers](desktop-peer.md).
Discovery-less first pairing is on that page: `flux-cli pair invite` / `pair join` dial a host from an invite when mDNS and UDP do not cross the path.
The invite carries the device ID, so Flux does not invent pair-by-arbitrary-IP.
A paired peer stays on the dial schedule from the merged issue 49: `TestPeerDialBackoff` covers the fast and slow intervals.
Two mDNS reports for one id stay one device: `TestMDNSReportsStayOneDevice`.
An IPv6 mDNS answer is dropped before it becomes a row.
The Android list can still show one computer twice. That is issue 7, and this phase does not change the phone app.

The pointer crosses one screen edge through `flux.edge`, configured with `edge_side` and `edge_device` (`flux-cli edge`, the Overview chips, or IPC).
Clicks and scroll cross with the pointer.
The keyboard stays on the computer where the keys are pressed and ends the lease.
`remote_input` stays the phone touchpad and the desk viewer, not the edge.
Still separate: drag across that edge, and focus follow.
