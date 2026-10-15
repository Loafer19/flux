using System.Windows;
using FluxKit;

namespace Flux;

// The features of the app. Each feature adds 1 line to each list that it
// uses. Keep 1 entry per line, so that features merge without conflicts.
// Features.swift of the Mac app has the same job.
public static class Features
{
    // The clipboard of Windows, for the clipboard sync and the dock of the chat.
    public static readonly WindowsClipboard Clipboard = new();

    static Features()
    {
        ControlTools.ModelMakers.Add(m => m.Core.Plugin<MprisPlugin>()?.Model);
        ControlTools.ModelMakers.Add(m => m.Core.Plugin<RunCommandPlugin>()?.Model);
        ControlTools.Tools.Add(m => m.Core.Plugin<RunCommandPlugin>() is null || !ControlTools.HasFeature(m, PacketType.RunCommandRequest) ? null
            : ControlTools.Tool(m, Icons.Commands, "Commands", "Run a command", PacketType.RunCommandRequest,
                d => m.Push(new Route.Feature(Card.Commands, d.Id))));
        // The dock opens the media, so the tool shows only while no player shows there.
        ControlTools.Tools.Add(m => m.Core.Plugin<MprisPlugin>() is null || !ControlTools.HasFeature(m, PacketType.MprisRequest) || MediaDock.Shows(m) ? null
            : ControlTools.Tool(m, Icons.Audio, "Media", "Play, pause, and volume", PacketType.MprisRequest,
                d => m.Push(new Route.Feature(Card.Media, d.Id))));

        FeatureSettings.ModelMakers.Add(m => m.Core.Plugin<ClipboardPlugin>()?.Model);
        FeatureSettings.Makers.Add(ClipboardSettings);

        TrayActions.Makers.Add((m, d) => m.Core.Plugin<ClipboardPlugin>() is { } c && d.Accepts(PacketType.Clipboard)
            ? ("Send clipboard", () => _ = c.SendClipboardAsync(d.Id))
            : null);
        TrayActions.Makers.Add((m, d) => m.Core.Plugin<MprisPlugin>() is { } p && p.Model.Media(d.Id).Player is { } player
            ? (player.Playing ? "Pause" : "Play", () => p.Action(d.Id, "PlayPause"))
            : null);
        TrayActions.Makers.Add((m, d) => m.Core.Plugin<RunCommandPlugin>() is not null && d.Accepts(PacketType.RunCommandRequest)
            ? ("Commands…", () =>
            {
                m.Go(Destination.Control);
                m.Push(new Route.Feature(Card.Commands, d.Id));
                m.ShowMain?.Invoke();
            })
            : null);
    }

    public static IReadOnlyList<IFluxPlugin> Plugins() =>
    [
        new PingPlugin(),
        new ClipboardPlugin(Clipboard),
        new RunCommandPlugin(),
        new MprisPlugin(),
        new NotificationsPlugin(new ToastHistory()),
        new BatteryPlugin(new BatterySource()),
        new ThemePlugin(),
    ];

    // The page of a destination root.
    public static Page Root(AppModel model, Destination d) => d switch
    {
        Destination.Chat => new ChatPage(model),
        Destination.Control => new ControlPage(model),
        _ => new ComputersPage(model),
    };

    // The page of a route.
    public static Page Route(AppModel model, Route route) => route switch
    {
        Flux.Route.Pairing p => new PairingPage(model, p.DeviceId),
        Flux.Route.Computer c => new ComputerPage(model, c.DeviceId),
        Flux.Route.Feature { Card: Card.Commands } f => new CommandsPage(model, f.DeviceId),
        Flux.Route.Feature { Card: Card.Media } f => new MediaPage(model, f.DeviceId),
        _ => new ComputersPage(model),
    };

    // Runs once after the start, before the network starts.
    public static void DidLaunch(AppModel model)
    {
        if (model.Core.Plugin<NotificationsPlugin>() is { } notifications)
        {
            // A click on a notification of a computer opens its chat.
            notifications.Opened += id =>
            {
                if (model.PairedDevice(id) is not null)
                {
                    model.SetScope(id);
                }
                model.Go(Destination.Chat);
                model.ShowMain?.Invoke();
            };
        }
    }

    // Runs when the app quits.
    public static void WillQuit(AppModel model)
    {
        model.Core.Plugin<ClipboardPlugin>()?.Dispose();
    }

    static (string Label, UIElement Content)? ClipboardSettings(AppModel model)
    {
        if (model.Core.Plugin<ClipboardPlugin>() is not { } clipboard)
        {
            return null;
        }
        return ("Clipboard", SettingsView.Group(
            SettingsView.Toggle("Sync clipboard", clipboard.Model.Sync, clipboard.SetSync),
            SettingsView.Note("Text that you copy goes to the connected computers, and text that they copy comes here. Copies that a password manager marks as private stay on this computer.")));
    }
}
