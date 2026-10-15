# Flux for Windows

[Documentation index](README.md)

Flux for Windows connects a Windows computer to an Omarchy computer that runs `fluxd`.
Windows takes the place of a phone, as the Mac does: it uses Flux protocol version 8 and pairs only with computers that run `fluxd`.
The app follows the Mac app. Its core library, FluxKit, is a port of the Swift FluxKit, and its views follow the macOS section of the [design system](../DESIGN.md).
The app requires Windows 10 version 2004 or later, or Windows 11.

The Windows app is new. Its views run on the Windows runner of CI, but nobody checked them on a Windows computer yet.

## Build and run

Install the .NET 10 SDK. From the repository root, run the tests and build the app:

```powershell
dotnet test windows/FluxKit.Tests -c Release
dotnet run --project windows/Flux.UiTests -c Release
dotnet publish windows/Flux -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -o windows/artifacts/win-x64
windows/artifacts/win-x64/Flux.exe
```

`Flux.exe` is 1 file that holds .NET, so the computer needs no .NET runtime.
The Windows workflow builds the same file on each push to `master` that changes `windows/`, and keeps it as the artifact `Flux-win-x64`.

On Linux, the tests and the build run in the .NET SDK container, because WPF builds for Windows on any system:

```sh
docker run --rm -v "$PWD":/src -w /src mcr.microsoft.com/dotnet/sdk:10.0 dotnet test windows/FluxKit.Tests -c Release
```

`Flux.UiTests` runs only on Windows.

## Pair a Windows computer

1. On the Omarchy computer, run `flux-cli setup` once.
2. Start Flux on Windows. Before the first pairing, Chat shows the pairing guide with the computers that Flux found.
3. Select the computer, then select **Pair…**. The dialog shows a key of 16 characters.
4. Select **Send request**. Accept the request on the computer when it shows the same key.

A request from the computer shows in Chat and as a notification with the key. Accept it only when both screens show the same key.
Flux looks for computers for 10 seconds at the start and after **Search again** in Computers. A paired computer connects by itself.

Windows asks once whether Flux may use the network. Allow private networks, or the computer cannot connect to Windows.

## Features

| Feature | What Windows does |
| --- | --- |
| Files | Sends files to the computer from the **+** menu of Chat, a drop on Chat, or the tray. Receives files from `flux-cli send` in Downloads, with resumable transfers |
| Text and links | Sends the text of the Chat field. A single web address opens in the browser of the computer, and other text goes on its clipboard. A link from the computer waits in a notification with **Open** |
| Clipboard | Syncs copied text both ways. **Send** in the dock of Chat sends the clipboard at once |
| Theme | Draws the Omarchy theme of the computer in scope. Settings has Computer, System, Light, and Dark |
| Battery | Sends the battery of a laptop. Shows the battery of a computer in the scope menu and in Computers |
| Notifications | Shows the notifications of `flux-cli notify` as Windows notifications |
| Commands | Runs the commands of the computer from Control |
| Media | Plays, pauses, skips, seeks, and sets the volume of the players of the computer, from Control |
| Ping | Sends a ping from the tray. A ping from the computer shows in the window |

These features of the Mac app are not in the Windows app yet: herdr agents, fingerprint approval, the touchpad, the remote desktop, the Omarchy panel, Get files, the microphone, the webcam, the screen mirror, and the camera modes.

Windows has no public interface that turns Do Not Disturb on or off, so the Windows app does not sync Do Not Disturb.

## Chat and navigation

The window has a sidebar with Chat, Control, and Computers, as the Mac app has.
`Ctrl+1` to `Ctrl+3` open them. `Esc` and `Alt+Left` go back from a page. `Ctrl+,` opens the settings.

- **Chat** shows 1 thread of the computers in scope, the newest entry at the bottom. The computers write on the left: pair requests, received files, and the last clip. What Windows sent shows on the right.
- **Control** shows the tools of the computers in scope, and a player dock while a computer plays media.
- **Computers** shows this computer, the paired computers, and the computers to pair. A click on a paired computer sets the scope.

The scope menu in the header picks 1 computer or all computers. The scope filters Chat and Control, and the Computer theme follows it.

The tray icon is the Flux mark. It is dim while no paired computer is connected, and a red dot shows when an item needs you. A click opens a panel with the items and a menu for each online computer. The right button opens Open Flux, Settings, and Quit Flux.
Flux keeps running in the tray after the window closes. Settings > Start > **Open at login** starts Flux in the tray when you log in.

## Clipboard

Flux syncs text only. It reads the clipboard every 0.5 seconds while a paired computer is connected.
Flux does not sync a copy that its source marks as private. A password manager marks a copy with the clipboard formats `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory`, or `CanUploadToCloudClipboard`.
Text from a computer never goes back to that computer. Text larger than 1 MB does not sync. Send it as a file.

## Received files

Files go to the Downloads folder of Windows. Settings > Features > Files picks another folder.
Flux never opens a received file by itself. It writes the Mark of the Web on each received file, so Windows and Office check the file before it opens, as a file from the internet.

## Pairing data

Flux keeps its data in `%LOCALAPPDATA%\Flux`:

| File | Content |
| --- | --- |
| `identity\identity.bin` | The certificate and private key of this computer, protected with DPAPI for the Windows user |
| `trusted.json` | The paired computers and their pinned certificates |
| `settings.json` | The settings of Flux and of the features |
| `incoming\` | Parts of resumable files, removed after 7 days |
| `flux.log` | The log. It never holds clipboard text, file contents, or notification text |

The certificate uses an ECDSA P-256 key. Its common name is the device ID.
To pair from scratch, quit Flux and delete `%LOCALAPPDATA%\Flux`.

## Network

| Use | Port |
| --- | --- |
| Discovery | UDP 12100 and mDNS `_flux._udp` |
| Links | TCP 12100 to 12108, the first free port |
| Files and streams | TCP 12070 to 12099 |

TLS uses version 1.2, as the Mac and Android apps do.

## Test against a computer

The FluxKit tests pair with a headless `fluxd` when `FLUX_E2E_BIN` names a folder with `fluxd` and `flux-cli`:

```sh
mkdir -p windows/artifacts/e2e
CGO_ENABLED=0 go build -o windows/artifacts/e2e/fluxd ./cmd/fluxd
CGO_ENABLED=0 go build -o windows/artifacts/e2e/flux-cli ./cmd/flux
docker run --rm -v "$PWD":/src -w /src -e FLUX_E2E_BIN=/src/windows/artifacts/e2e mcr.microsoft.com/dotnet/sdk:10.0 dotnet test windows/FluxKit.Tests -c Release
```

The container keeps the test network apart from a `fluxd` that runs on the computer. The `fluxd` job of the Windows workflow runs these tests on each push.

To point the app at a headless `fluxd`, set these variables:

| Variable | Effect |
| --- | --- |
| `FLUX_DATA_DIR` | Identity, trust store, and settings in a separate folder |
| `FLUX_UDP_PORT` | UDP port that receives identity broadcasts. The default is `12100` |
| `FLUX_PEER_UDP_PORT` | UDP port of the computer that Windows announces itself to. The default is `12100` |
| `FLUX_TCP_PORT` | First TCP port for links. The default is `12100` |
| `FLUX_LOOPBACK=1` | Announce only to 127.0.0.1 and skip mDNS |

## Layout

| Path | Content |
| --- | --- |
| `windows/FluxKit/Protocol` | Packets, identity, certificates, and the verification key |
| `windows/FluxKit/Net` | UDP discovery, mDNS, TCP links, TLS, payload servers, and tunnels |
| `windows/FluxKit/Core` | The core, computers, pairing, the trust store, the plugin interface, notifications, and settings |
| `windows/FluxKit/Plugins` | 1 folder per feature |
| `windows/FluxKit/Theme` | The theme packet, the contrast guard, and the palettes |
| `windows/FluxKit.Tests` | xUnit tests, and the tests against `fluxd` |
| `windows/Flux` | The WPF app. `Features/Features.cs` lists the plugins and their views |
| `windows/Flux/Kit` | The theme brushes, the stack panel, the buttons, and the parts of the design system |
| `windows/Flux/Shell` | The main window, the sidebar, the header, and the scope menu |
| `windows/Flux/Chat` | Chat: the thread, the cards, the dock, the notices, and the pairing guide |
| `windows/Flux/Destinations` | Control, Computers, and the pairing pages |
| `windows/Flux/Platform` | DPAPI, toasts, the clipboard, the battery, and other Windows parts |
| `windows/Flux.UiTests` | Builds each page with sample computers on Windows |

The views are C# code, not XAML, so that the compiler checks each property. Each view draws itself from the models again after a change, as a SwiftUI view does.
