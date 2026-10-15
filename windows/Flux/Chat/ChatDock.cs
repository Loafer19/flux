using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using FluxKit;

namespace Flux;

// The dock under the chat: the tools behind +, and a field for text or a
// link with Send. Enter sends, and Shift+Enter adds a line. The field keeps
// its text and its focus while the chat draws again. ChatDock.swift of the
// Mac app has the same parts.
public sealed class ChatDock
{
    readonly AppModel model;
    readonly TextBox field;
    readonly Popup tools = new() { StaysOpen = false, AllowsTransparency = true, Placement = PlacementMode.Top };
    readonly PlainButton plus;
    readonly PlainButton send;
    readonly Border plusTile = new() { Width = 36, Height = 36, CornerRadius = new CornerRadius(18) };
    readonly Border sendTile = new() { Width = 36, Height = 36, CornerRadius = new CornerRadius(18), BorderThickness = new Thickness(1) };
    readonly TextBlock plusIcon = Ui.Icon(Icons.Add, 16);
    readonly TextBlock sendIcon = Ui.Icon(Icons.Send, 15);
    readonly Border frame;

    // The dock. It stays the same element, so that the field keeps its focus.
    public Border Root { get; }

    public ChatDock(AppModel model)
    {
        this.model = model;
        field = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MaxHeight = 140,
            MinHeight = 36,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalContentAlignment = VerticalAlignment.Center,
            Padding = new Thickness(10, 6, 10, 6),
            FontSize = 13,
        };
        System.Windows.Automation.AutomationProperties.SetName(field, "Text or a link to send");
        field.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.None)
            {
                e.Handled = true;
                Send();
            }
        };
        field.TextChanged += (_, _) => Update();
        field.GotKeyboardFocus += (_, _) => Update();
        field.LostKeyboardFocus += (_, _) => Update();
        plusTile.Child = plusIcon;
        sendTile.Child = sendIcon;
        plus = new PlainButton(plusTile, OpenTools).Named("Tools").Help("Tools");
        send = new PlainButton(sendTile, Send).Named("Send").Help("Send (Enter)");
        var row = Ui.H(8, plus, field.Fill(), send);
        tools.PlacementTarget = plus;
        frame = new Border
        {
            Child = new Border { Child = row, MaxWidth = Metrics.MaxContentWidth },
            BorderThickness = new Thickness(1, 1, 1, 0),
            CornerRadius = new CornerRadius(20, 20, 0, 0),
            Padding = new Thickness(Metrics.Gutter, 12, Metrics.Gutter, 10),
        };
        Root = frame;
        Update();
    }

    // The features that send text or a link. The share feature sets it.
    public static Func<AppModel, string, string, bool>? SendText { get; set; }

    // The tools of the + menu, as a title, an icon, and an action for the
    // computer in the scope. The features add them.
    public static List<Func<AppModel, (string Title, string Glyph, Action Run)?>> Tools { get; } = [];

    void Send()
    {
        var text = field.Text.Trim();
        if (text.Length == 0 || SendText is null)
        {
            return;
        }
        if (Targets.Pick(model, PacketType.Share) is not { } id)
        {
            return;
        }
        if (SendText(model, id, text))
        {
            field.Clear();
        }
    }

    // Draws the colors and the state of the keys. The field stays.
    public void Update()
    {
        var tn = Tn.Current;
        frame.Background = tn.Tile;
        frame.BorderBrush = tn.Line;
        field.Background = tn.Bg;
        field.Foreground = tn.Text;
        field.BorderBrush = field.IsKeyboardFocused ? tn.Accent : tn.LineHi;
        field.CaretBrush = tn.Accent;
        field.FontFamily = Faces.Body;
        plusTile.Background = tn.Line;
        plusIcon.Foreground = tn.Text;
        var canSend = SendText is not null && field.Text.Trim().Length > 0;
        sendTile.Background = canSend ? tn.Accent : tn.Tile;
        sendTile.BorderBrush = canSend ? tn.Accent : tn.Line;
        sendIcon.Foreground = canSend ? tn.OnAccent : tn.Dim;
        send.IsEnabled = canSend;
    }

    void OpenTools()
    {
        var tn = Tn.Current;
        var tiles = new List<UIElement>();
        foreach (var make in Tools)
        {
            if (make(model) is { } t)
            {
                tiles.Add(Parts.GridTool(t.Glyph, t.Title, "", () =>
                {
                    tools.IsOpen = false;
                    t.Run();
                }, small: true));
            }
        }
        var go = new UIElement[]
        {
            Parts.GridTool(Icons.Control, "Control", "", () =>
            {
                tools.IsOpen = false;
                model.Go(Destination.Control);
            }, small: true),
            Parts.GridTool(Icons.Laptop, "Computers", "", () =>
            {
                tools.IsOpen = false;
                model.Go(Destination.Computers);
            }, small: true),
        };
        tools.Child = new Border
        {
            Child = Ui.V(Metrics.Gap, tiles.Count > 0 ? Parts.GridRows(tiles, 3) : null, Parts.GridRows(go, 2)),
            Background = tn.Bg,
            BorderBrush = tn.LineHi,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(20),
            Padding = new Thickness(10),
            Width = 340,
            Margin = new Thickness(0, 0, 0, 10),
        };
        tools.IsOpen = true;
    }
}

// The computer for an action: the computer in scope, or the only online
// computer that takes it. With more computers, the user picks 1.
public static class Targets
{
    public static string? Pick(AppModel model, string accepts)
    {
        var ready = model.ConnectedPaired.Where(d => d.Accepts(accepts) && (model.Scope is null || d.Id == model.Scope)).ToArray();
        switch (ready.Length)
        {
            case 0:
                model.Show(model.Scope is null ? "No computer is connected" : $"{Shared.ScopeName(model)} is not reachable");
                return null;
            case 1:
                return ready[0].Id;
            default:
                return Choose(model, ready);
        }
    }

    // Asks which computer takes the action.
    static string? Choose(AppModel model, IReadOnlyList<DeviceSnapshot> devices)
    {
        string? chosen = null;
        Window? w = null;
        var rows = devices.Select(d => (UIElement)new PlainButton(Ui.Tile(Ui.H(10,
                Ui.Icon(Texts.Symbol(d), 15, Tn.Current.Accent), Ui.Text(d.Name, 13, FontWeights.SemiBold).Fill()), padding: 10), () =>
            {
                chosen = d.Id;
                w!.Close();
            }).Named(d.Name)).ToList();
        var body = Ui.V(Metrics.Gap, new UIElement[] { Ui.Text("Which computer?", 17, FontWeights.SemiBold) }.Concat(rows));
        w = new Window
        {
            Title = "Which computer?",
            Owner = Application.Current?.MainWindow,
            Width = 340,
            SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
            Background = Tn.Current.TileHi,
            Content = Ui.Box(body, 20, 18, 20, 18),
        };
        w.InputBindings.Add(new KeyBinding(new Relay(w.Close), Key.Escape, ModifierKeys.None));
        w.ShowDialog();
        return chosen;
    }
}
