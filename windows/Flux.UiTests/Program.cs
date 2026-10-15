using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Flux;
using FluxKit;

// Builds the window of Flux with sample computers, and opens each page, the
// settings, and the tray panel. A view that throws, or a text that does not
// show, fails the run. It runs only on Windows, in the Windows workflow.
static class Program
{
    static int failures;

    static void Check(bool ok, string what)
    {
        if (!ok)
        {
            failures++;
            Console.WriteLine("FAIL: " + what);
        }
    }

    // Runs the UI thread until the queued work is done.
    static void Pump()
    {
        for (var i = 0; i < 3; i++)
        {
            var frame = new DispatcherFrame();
            Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () => frame.Continue = false);
            Dispatcher.PushFrame(frame);
        }
    }

    // The texts that the element shows.
    static List<string> Texts(DependencyObject root)
    {
        var list = new List<string>();
        void Walk(DependencyObject e)
        {
            switch (e)
            {
                case TextBlock t:
                    list.Add(t.Text);
                    break;
                case TextBox b:
                    list.Add(b.Text);
                    break;
            }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(e); i++)
            {
                Walk(VisualTreeHelper.GetChild(e, i));
            }
        }
        Walk(root);
        return list;
    }

    static bool Shows(DependencyObject root, string text) => Texts(root).Any(t => t.Contains(text, StringComparison.Ordinal));

    static DeviceSnapshot Device(string id, string name, bool paired, bool online, PairState state, string key = "") =>
        new(id.PadRight(32, '0'), name, "laptop", "192.168.1.20", true, paired, online, state, key,
            ValueList.From(new[] { PacketType.Tunnel, PacketType.Ping, PacketType.Share }), ValueList<string>.Empty, "fluxd", "0.17.0");

    [STAThread]
    static int Main()
    {
        var data = Path.Combine(Path.GetTempPath(), "flux-ui-" + Guid.NewGuid().ToString("N"));
        try
        {
            new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            var host = new FluxHost
            {
                DeviceName = () => "Test PC",
                DeviceType = "laptop",
                Post = action => Dispatcher.CurrentDispatcher.BeginInvoke(action),
            };
            using var core = new FluxCore(new FluxPaths(data), host, new LanConfig { LoopbackOnly = true }, Features.Plugins());
            var model = new AppModel(core);
            var window = new MainWindow(model, Features.Root, Features.Route);
            window.Show();
            Pump();
            Check(Shows(window, "Pair your Omarchy computer"), "the chat shows the pairing guide before the first pairing");
            Check(Shows(window, "flux-cli setup"), "the guide shows the setup command");

            var paired = Device("a", "omarchy-xps", true, true, PairState.Paired);
            var offline = Device("b", "omarchy-desk", true, false, PairState.Paired);
            var asking = Device("c", "omarchy-new", false, true, PairState.Incoming, "5EE6825F974ED59A");
            var found = Device("d", "omarchy-lab", false, true, PairState.None);
            model.Apply(new CoreState
            {
                DeviceName = "Test PC",
                DeviceId = new string('f', 32),
                Devices = ValueList.From(new[] { paired, offline, asking, found }),
                TcpPort = 12101,
            });
            Pump();
            Check(Shows(window, "omarchy-new asks to pair"), "the chat shows the pair request");
            Check(Shows(window, "1 need you"), "the context line counts the request");
            Check(Shows(window, "omarchy-desk is not reachable"), "the chat shows the offline computer");

            model.Go(Destination.Computers);
            Pump();
            Check(Shows(window, "Paired") && Shows(window, "Available"), "Computers shows its groups");
            Check(Shows(window, "omarchy-xps") && Shows(window, "omarchy-lab"), "Computers lists the computers");
            Check(Shows(window, "1 of 2 online"), "Computers shows the online count");

            model.Push(new Route.Pairing(asking.Id));
            Pump();
            Check(Shows(window, "omarchy-new wants to pair"), "the pairing page shows the request");
            Check(Shows(window, "5EE6 825F 974E D59A"), "the pairing page shows the key in groups");
            model.Back();
            model.Push(new Route.Computer(paired.Id));
            Pump();
            Check(Shows(window, "Unpair omarchy-xps…"), "the computer page shows Unpair");

            model.Go(Destination.Control);
            Pump();
            Check(window.CurrentPage is ControlPage, "Control opens");

            model.SetScope(paired.Id);
            model.Go(Destination.Chat);
            Pump();
            Check(Shows(window, "omarchy-xps"), "the scope menu names the computer in scope");

            var before = window.Background;
            Tn.Apply(Palette.TokyoNightDay);
            Pump();
            Check(window.Background != before, "the window takes the light theme");
            Tn.Apply(Palette.TokyoNight);

            var settings = new SettingsWindow(model);
            settings.Show();
            Pump();
            Check(Shows(settings, "Flux is on") && Shows(settings, "Open at login"), "the settings show General");
            settings.Close();

            var panel = new TrayPanel(model, () => { }, () => { }, () => { });
            panel.Toggle();
            Pump();
            Check(Shows(panel, "1 item needs you"), "the tray panel counts the request");
            Check(Shows(panel, "omarchy-xps"), "the tray panel lists the online computer");
            panel.Close();

            window.Quitting = true;
            window.Close();
        }
        catch (Exception e)
        {
            failures++;
            Console.WriteLine("FAIL: " + e);
        }
        finally
        {
            try
            {
                Directory.Delete(data, true);
            }
            catch (IOException)
            {
            }
        }
        Console.WriteLine(failures == 0 ? "PASS: the views of Flux" : $"{failures} checks failed");
        return failures == 0 ? 0 : 1;
    }
}
