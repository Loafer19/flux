using System.Windows;
using Flux;
using FluxKit;
using static Harness;

// The shell: the pairing guide, Chat, Computers, the pairing pages, Control,
// the scope, the theme, the settings, and the tray panel.
public static class ShellChecks
{
    public static void Run(Harness h)
    {
        var window = h.Window;
        var model = h.Model;
        window.Show();
        Pump();
        h.Check(Shows(window, "Pair your Omarchy computer"), "the chat shows the pairing guide before the first pairing");
        h.Check(Shows(window, "flux-cli setup"), "the guide shows the setup command");

        h.ApplyDevices();
        Pump();
        h.Check(Shows(window, "omarchy-new asks to pair"), "the chat shows the pair request");
        h.Check(Shows(window, "1 need you"), "the context line counts the request");
        h.Check(Shows(window, "omarchy-desk is not reachable"), "the chat shows the offline computer");

        model.Go(Destination.Computers);
        Pump();
        h.Check(Shows(window, "Paired") && Shows(window, "Available"), "Computers shows its groups");
        h.Check(Shows(window, "omarchy-xps") && Shows(window, "omarchy-lab"), "Computers lists the computers");
        h.Check(Shows(window, "1 of 2 online"), "Computers shows the online count");

        model.Push(new Route.Pairing(h.Asking.Id));
        Pump();
        h.Check(Shows(window, "omarchy-new wants to pair"), "the pairing page shows the request");
        h.Check(Shows(window, "5EE6 825F 974E D59A"), "the pairing page shows the key in groups");
        model.Back();
        model.Push(new Route.Computer(h.Paired.Id));
        Pump();
        h.Check(Shows(window, "Unpair omarchy-xps…"), "the computer page shows Unpair");

        model.Go(Destination.Control);
        Pump();
        h.Check(window.CurrentPage is ControlPage, "Control opens");

        model.SetScope(h.Paired.Id);
        model.Go(Destination.Chat);
        Pump();
        h.Check(Shows(window, "omarchy-xps"), "the scope menu names the computer in scope");
        model.SetScope(null);

        var before = window.Background;
        Tn.Apply(ThemePalette.TokyoNightDay);
        Pump();
        h.Check(window.Background != before, "the window takes the light theme");
        Tn.Apply(ThemePalette.TokyoNight);

        var settings = new SettingsWindow(model);
        settings.Show();
        Pump();
        h.Check(Shows(settings, "Flux is on") && Shows(settings, "Open at login"), "the settings show General");
        h.Check(Shows(settings, "Computer: "), "the settings name the theme of the Computer choice");
        Click(settings, "Features");
        h.Check(Shows(settings, "Received files") && Shows(settings, "Sync clipboard"), "the settings show the features");
        settings.Close();

        var panel = new TrayPanel(model, () => { }, () => { }, () => { });
        panel.Toggle();
        Pump();
        h.Check(Shows(panel, "1 item needs you"), "the tray panel counts the request");
        h.Check(Shows(panel, "omarchy-xps"), "the tray panel lists the online computer");
        panel.Close();
    }
}
