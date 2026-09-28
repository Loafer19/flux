# Connect two computers

[Documentation index](README.md)

Two Omarchy computers that each run `fluxd` can pair with each other.
They share clipboard text, clipboard images, and files.
`flux-cli status` shows the other computer with the role `peer`.

A phone and a Mac stay remotes.
This page does not turn a computer into a phone: there is no Browse storage, ring, SMS, camera, or fingerprint approval between two desks.

## Requirements

- Flux is installed on both computers, and `fluxd` is running.
- Both computers are on the same local network for the first pair.
- Each computer accepts inbound TCP 1716–1764 from the other.

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

In `flux-cli status --json` the same device has `"role": "peer"`.

## Share

```sh
flux-cli --device "other-desk" clip "from this desk"
flux-cli --device "other-desk" send "$HOME/Downloads/report.txt"
```

Clipboard text uses the link that is already open.
A copied image and a file also use a TCP port in 1716–1764, back toward the computer that sends them.
The allow rule on both computers covers that path.
Received files use `download_dir`.

`flux-cli notify` can show a notification on the other computer.
Browse storage stays off.
`flux-cli ring` returns an error for a computer.

## Tailscale

Pair on the local network first.
Tailscale does not carry the mDNS and UDP broadcasts Flux uses to find a device, so the first pair cannot go through Tailscale alone.

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
