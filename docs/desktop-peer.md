# Connect two computers

[Documentation index](README.md)

Two Omarchy computers that each run `fluxd` can pair with each other.
They share clipboard text, clipboard images, and files.
`flux-cli status` shows the other computer with the role `peer`.

A phone and a Mac stay remotes.
This page does not turn a computer into a phone: there is no Browse storage, ring, SMS, camera, or fingerprint approval between two desks.

## Requirements

- Flux is installed on both computers, and `fluxd` is running.
- Each computer can reach the other on TCP 1716–1764 (same LAN with an allow rule, or the same Tailscale tailnet).
- For a first pair without mDNS, one computer shares an invite; see [Pair without discovery](#pair-without-discovery).

Omarchy's firewall allows mDNS and blocks other inbound TCP.
A phone still works, because the computer dials out to the phone.
Two computers each listen, and each dials the other, so both firewalls must allow that range.
Flux does not add this rule during installation.

## Allow the other computer

On each computer, read its LAN address:

```sh
ip -4 -br addr
```

Use the address on the interface that faces the other computer, for example `192.168.1.20` and `192.168.1.50`.

On the first computer, allow the second:

```sh
sudo ufw allow from 192.168.1.50 to any port 1716:1764 proto tcp comment 'flux peer'
```

On the second computer, allow the first:

```sh
sudo ufw allow from 192.168.1.20 to any port 1716:1764 proto tcp comment 'flux peer'
```

Check the rule, then check that the other computer answers:

```sh
sudo ufw status
timeout 3 bash -c '</dev/tcp/192.168.1.50/1716' && echo "port 1716 answers"
```

Run the port check from each computer toward the other.
`fluxd` may listen on a port from 1716 through 1764.
`flux-cli status` prints the port of this computer on its first line.
If 1716 does not answer, repeat the check with the port from the other computer's `flux-cli status`.

A home network can allow the LAN subnet instead of one address:

```sh
sudo ufw allow from 192.168.1.0/24 to any port 1716:1764 proto tcp comment 'flux peers'
```

## Pair

1. On both computers, run `flux-cli status` and confirm `fluxd` is up.
2. Open the window with `flux-cli open`.
3. Select **+ Pair new device**.
4. Select the other computer.
5. Compare the 8-character key on both screens.
6. Accept the matching request.

The other computer appears in the list after the TLS link is up.
An allow rule that is still missing looks like a computer that never shows up.

From a terminal, after the other computer is online:

```sh
flux-cli pair "other-desk"
flux-cli status
```

`pair` prints the key and waits.
Accept it on the other computer.
`status` then shows that computer as `laptop` or `desktop`, role `peer`, and `paired`.

Open **Network** in the window to see this computer and the paired devices.
A peer row shows clipboard and files on, and Do Not Disturb between desks off.
The computer named in `edge_device` shows that screen edge. The others stay unset.
Select the row to open that device.

Two computers with the same name need a device id:

```sh
flux-cli --device DEVICE_ID clip "from this desk"
```

`flux-cli status --json` prints the id.

In `flux-cli status --json` the same device has `"role": "peer"`.

## Pair without discovery

mDNS and UDP broadcasts do not cross NAT, guest Wi-Fi isolation, or Tailscale.
When the other computer never appears in the list, share an invite instead of opening the firewall to the whole internet.

### From the window

1. Pick a host the other computer can already reach: a Tailscale name or IP, or a LAN address after both sides allow TCP 1716–1764 from each other only.
2. On the computer that listens at that host, open **Network**.
3. Under **Pair with invite**, set the host (or leave empty when fluxd can pick the only Tailscale address), then **Create invite**.
4. Copy the `flux1:…` code, or show the QR when the window draws one.
5. On the other computer, open **Network**, paste the invite, and select **Join**.
6. Compare the 8-character key on both screens and accept.

### From the terminal

1. Pick the same reachable host.
2. On the computer that listens at that host:

   ```sh
   flux-cli pair invite --host other-desk
   ```

   Use the Tailscale name from `tailscale status`, or the LAN address from `ip -4 -br addr`.
   When this computer has exactly one Tailscale IPv4 address, you can omit `--host`.

3. On the other computer, paste the invite:

   ```sh
   flux-cli pair join 'flux1:…@other-desk:1716'
   ```

4. Compare the 8-character key on both screens and accept.

The invite carries the device ID, host, and port. It is not a secret.
Pairing still needs the verification key.
Flux dials only that host; it does not add a firewall rule and does not accept "pair by any IP" without the ID from the invite.

### Optional relay

Prefer LAN or Tailscale. Use a relay only when neither computer can dial the other.

1. On a host both sides can reach (or on one desk for a local test):

   ```sh
   flux-cli relay serve --listen :17777
   ```

2. On **both** computers:

   ```sh
   flux-cli relay url THAT_HOST:17777
   flux-cli relay on
   ```

3. Create and join an invite as above, without `--host` (the invite points at the relay).

4. Compare the 8-character key and accept.

`relay` defaults to off. The Network page has the same toggle and URL field.
The helper splices TCP only; Flux still runs its TLS handshake end to end.
A full STUN/TURN mesh is out of scope; this is a small rendezvous scaffold you can self-host for NAT/cross-network pairing.

After the pair, keep a Tailscale name as an extra address on both sides when you leave the LAN:

```sh
flux-cli --device "other-desk" addresses add other-desk
```

## Share

```sh
flux-cli --device "other-desk" clip "from this desk"
flux-cli --device "other-desk" send "$HOME/Downloads/report.txt"
flux-cli --device "other-desk" url "https://example.com"
```

`url` opens an `http` or `https` address on that computer.
A computer does not open a `file:` address.

## Screen edge

One edge of this screen can continue on the other computer.
The pointer moves there. Clicks and the keyboard stay on the computer where they were pressed.
`remote_input` stays off. This is not the phone touchpad.
Both computers must name the seam: this desk names the edge that leaves, the other desk names the opposite edge.

On this computer (for example dragon), point the left edge at the other desk:

```sh
flux-cli edge left vivobook
```

On the other computer, point the opposite edge back:

```sh
flux-cli edge right dragon
```

`left` meets `right`, and `top` meets `bottom`.
`flux-cli edge` shows the seam. `flux-cli edge off` clears it.
The same keys live in `~/.config/flux/config.toml` as `edge_side` and `edge_device`; a reload picks that up too:

```sh
systemctl --user reload fluxd
```

A daemon started by hand reloads on `SIGHUP`.
On the Network page, tap the edge chip on a peer row to cycle left, right, top, bottom, or off.

Move the pointer through that edge. It appears on the other screen.
Move it back inward on this computer to return.
Hyprland must be running: Flux reads the cursor from the Hyprland socket and moves the peer with `zwlr_virtual_pointer_v1` (no `/dev/uinput`, no `remote_input`).

Clipboard text uses the link that is already open.
A copied image and a file also use a TCP port in 1716–1764, back toward the computer that sends them.
The allow rule on both computers covers that path.
Received files use `download_dir`.

`flux-cli notify` can show a notification on the other computer.
Browse storage stays off.
`flux-cli ring` returns an error for a computer.


## Remote desktop between desks

A paired desk can show the other desk screen when both sides allow it.

1. On the computer that will be watched, turn the stream on:

   ```sh
   flux-cli desktop on
   flux-cli input on   # optional: let the viewer move the pointer and type
   ```

2. On the computer that watches, with the peer online, either open **Network**,
   select **View** on the peer row, or run:

   ```sh
   flux-cli desktop view vivobook
   ```

   Flux opens a TLS listener on a port from 1739 to 1764, sends `flux.desktop`
   start (same packet a phone sends), and the peer captures with
   `gpu-screen-recorder` or `wf-recorder`. This computer feeds Annex-B H.264
   into `mpv` or `ffplay`. With `mpv`, move and click in the window to control
   the peer when that desk has `remote_input` on.

3. Close the player window, tap **Stop** on the Network peer row, or run
   `flux-cli desktop view-stop`.

The peer role still hides phone-only features (Browse, ring, SMS, approve).
Remote desktop and remote input between desks reuse the phone packets and
the existing `remote_desktop` / `remote_input` switches. Screen-edge pointer
share (`flux-cli edge`) stays separate: it moves the cursor without a video
stream and does not need `remote_input`.

With `mpv`, the viewer window sends mouse and keys as `flux.mousepad.request`
(same packets as the phone). The watched desk runs them only while
`remote_input` is on (`flux-cli input on`). `ffplay` shows the stream only;
install `mpv` for control. Screen-edge pointer share stays separate and does
not use these packets.

Firewall: the watched desk dials back to the viewer's payload port, so both
sides still need TCP 1716–1764 open toward each other (same as file share).

## Tailscale

Tailscale does not carry the mDNS and UDP broadcasts Flux uses to find a device.
For a first pair over Tailscale, use [Pair without discovery](#pair-without-discovery) with the Tailscale name as `--host`.
You can still pair on the LAN first, then add Tailscale addresses.

On each computer, after the pair:

```sh
tailscale status
flux-cli --device "other-desk" addresses add other-desk
flux-cli addresses
flux-cli doctor
```

Use the name from the second column of `tailscale status`.
Add an address on both computers, each one naming the other.
When the computers leave the local network, `fluxd` dials that name.

The LAN rule matches the other computer's LAN address, not its Tailscale address.
If the Tailscale port does not answer, allow the range on the Tailscale interface on both computers:

```sh
sudo ufw allow in on tailscale0 to any port 1716:1764 proto tcp comment 'flux peer'
timeout 3 bash -c '</dev/tcp/other-desk/1716' && echo "port 1716 answers"
```

Other devices in the tailnet can then open those ports.
Limit them with Tailscale access controls the same way as for a [phone](tailscale.md#access-and-security).

The link still uses the certificates pinned at pairing.
See [Connect through Tailscale](tailscale.md) for MagicDNS, relays, and `flux-cli doctor`.

## When a computer goes away

A paired computer uses the same reconnect schedule as a paired phone.

- `fluxd` dials again 2 seconds after the link drops.
- It then dials every 30 seconds, 20 times, and after that every 2 minutes until the computer answers or the network changes.
- An mDNS answer or a returning UDP identity dials at once.
- The last address is tried first, then each extra address, including the Tailscale name.

`journalctl --user -u fluxd -n 50 --no-pager` shows `link up` with the address that answered.

## One row per computer

`avahi-browse -rt _kdeconnect._udp` can print the same computer twice, once for IPv4 and once for IPv6.
Flux stores one device for that id.
The window shows that computer once.
Flux dials the IPv4 address from mDNS.

## Remove

```sh
sudo ufw status numbered
sudo ufw delete NUMBER
flux-cli --device "other-desk" addresses remove other-desk
flux-cli unpair "other-desk"
```

`unpair` also removes the extra addresses.
Delete the firewall rule on both computers when the pair is gone.

## Troubleshoot

1. `flux-cli status` on both computers shows a TCP port.
2. `sudo ufw status` on both computers shows TCP 1716–1764 from the other computer.
3. The port check toward the other computer prints `port 1716 answers`, or answers on the port from its status line.
4. `systemctl status avahi-daemon` is running.
5. Guest Wi-Fi and client isolation still block two computers on the same access point.
6. Read dial errors:

   ```sh
   journalctl --user -u fluxd -n 50 --no-pager | grep "connect to"
   ```
