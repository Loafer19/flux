using System.Security.Principal;

namespace Flux;

static class Program
{
    // 1 Flux runs for each Windows user. A second start brings the window of
    // the running Flux to the front and ends.
    [STAThread]
    static int Main(string[] args)
    {
        var user = WindowsIdentity.GetCurrent().User?.Value ?? "user";
        using var single = new Mutex(true, @"Local\Flux-" + user, out var first);
        using var wake = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Flux-show-" + user);
        if (!first)
        {
            wake.Set();
            return 0;
        }
        var app = new App();
        var watcher = new Thread(() =>
        {
            while (wake.WaitOne())
            {
                App.Activate();
            }
        }) { IsBackground = true, Name = "Flux wake" };
        watcher.Start();
        app.Startup += (_, _) => app.Start(args.Contains("--background"));
        return app.Run();
    }
}
