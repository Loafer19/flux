using FluxKit;

namespace Flux;

// The features of the app. Each feature adds 1 line to each list that it
// uses. Keep 1 entry per line, so that features merge without conflicts.
// Features.swift of the Mac app has the same job.
public static class Features
{
    public static IReadOnlyList<IFluxPlugin> Plugins() =>
    [
        new PingPlugin(),
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
        _ => new ComputersPage(model),
    };

    // Runs once after the start, before the network starts.
    public static void DidLaunch(AppModel model)
    {
    }
}
