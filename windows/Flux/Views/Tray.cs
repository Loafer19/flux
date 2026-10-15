using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FluxKit;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace Flux;

// The Flux mark in the tray: dimmed while no paired computer is connected,
// with the count of the items that need the user. A click opens the panel,
// and the right button opens the menu. The menu bar extra of the Mac app has
// the same job.
public sealed class Tray : IDisposable
{
    readonly AppModel model;
    readonly Forms.NotifyIcon icon = new();
    readonly TrayPanel panel;
    Drawing.Icon? drawn;
    string drawnKey = "";

    public Tray(AppModel model, Action showMain, Action showSettings, Action quit)
    {
        this.model = model;
        panel = new TrayPanel(model, showMain, showSettings, quit);
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open Flux", null, (_, _) => showMain());
        menu.Items.Add("Settings…", null, (_, _) => showSettings());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Flux", null, (_, _) => quit());
        icon.ContextMenuStrip = menu;
        icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left)
            {
                panel.Toggle();
            }
        };
        icon.Visible = true;
        model.PropertyChanged += (_, _) => Draw();
        Tn.Changed += Draw;
        Draw();
    }

    // Draws the icon and the tooltip for the state.
    public void Draw()
    {
        var count = Inbox.NeedsYou(model);
        var online = model.ConnectedPaired.Count > 0;
        var light = ThisComputer.TaskbarLight;
        icon.Text = count == 0 ? "Flux" : $"Flux, {Texts.NeedsText(count)}";
        var key = $"{count}|{online}|{light}|{Tn.Current.Palette.Accent}";
        if (key == drawnKey)
        {
            return;
        }
        drawnKey = key;
        var old = drawn;
        drawn = Mark(32, online, light, count);
        icon.Icon = drawn;
        old?.Dispose();
    }

    // The mark on a 16-unit grid: a square ring of 10 units at 3 units with
    // a 2-unit stroke, and a bar of 2 by 14 units at 7 units in the accent.
    static Drawing.Icon Mark(int size, bool online, bool light, int count)
    {
        using var bitmap = new Drawing.Bitmap(size, size);
        using (var g = Drawing.Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
            var unit = size / 16f;
            var alpha = online ? 255 : 115;
            var ink = light ? Drawing.Color.FromArgb(alpha, 0x34, 0x3B, 0x58) : Drawing.Color.FromArgb(alpha, 0xE6, 0xE9, 0xF5);
            var a = Tn.Current.Palette.Accent;
            var accent = Drawing.Color.FromArgb(alpha, (a >> 16) & 0xFF, (a >> 8) & 0xFF, a & 0xFF);
            using (var pen = new Drawing.Pen(ink, 2 * unit))
            {
                g.DrawRectangle(pen, 3 * unit + unit, 3 * unit + unit, 8 * unit, 8 * unit);
            }
            using (var bar = new Drawing.SolidBrush(accent))
            {
                g.FillRectangle(bar, 7 * unit, 1 * unit, 2 * unit, 14 * unit);
            }
            if (count > 0)
            {
                var r = Tn.Current.Palette.Red;
                using var red = new Drawing.SolidBrush(Drawing.Color.FromArgb(255, (r >> 16) & 0xFF, (r >> 8) & 0xFF, r & 0xFF));
                g.FillEllipse(red, size - 7 * unit, 0, 7 * unit, 7 * unit);
            }
        }
        var handle = bitmap.GetHicon();
        try
        {
            return (Drawing.Icon)Drawing.Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        drawn?.Dispose();
        panel.Close();
    }
}

// The panel of the tray: the count of the items that need the user, the
// items, a menu for each online computer, and the app actions. It shows near
// the tray and hides when it loses the focus.
public sealed class TrayPanel : Window
{
    readonly AppModel model;
    readonly Action showMain;
    readonly Action showSettings;
    readonly Action quit;
    readonly PanelView view;

    public TrayPanel(AppModel model, Action showMain, Action showSettings, Action quit)
    {
        this.model = model;
        this.showMain = showMain;
        this.showSettings = showSettings;
        this.quit = quit;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = 360;
        SizeToContent = SizeToContent.Height;
        FontFamily = Faces.Body;
        view = new PanelView(this);
        Content = view;
        Deactivated += (_, _) => Hide();
        InputBindings.Add(new KeyBinding(new Relay(Hide), Key.Escape, ModifierKeys.None));
        // The panel only hides, until the app quits.
        Closing += (_, e) => e.Cancel = !quitting;
    }

    bool quitting;

    public new void Close()
    {
        quitting = true;
        base.Close();
    }

    public void Toggle()
    {
        if (IsVisible)
        {
            Hide();
            return;
        }
        view.Redraw();
        Background = Tn.Current.Bg;
        Show();
        UpdateLayout();
        // Near the tray: the bottom right of the work area of the screen
        // with the pointer.
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 12;
        Top = area.Bottom - ActualHeight - 12;
        Activate();
    }

    sealed class PanelView : View
    {
        readonly TrayPanel panel;

        public PanelView(TrayPanel panel)
        {
            this.panel = panel;
            Watch(panel.model);
        }

        protected override UIElement Build()
        {
            var tn = Tn.Current;
            var model = panel.model;
            var count = Inbox.NeedsYou(model);
            var items = new List<UIElement?>
            {
                Ui.H(8, count > 0 ? Ui.Dot(tn.Red) : null, Ui.Text(Texts.NeedsText(count), 13, FontWeights.SemiBold)),
            };
            if (model.Paired.Count == 0)
            {
                items.Add(Ui.Text("No computer is paired. Open Flux to pair your Omarchy computer.", 12, color: tn.Sub, wrap: true));
            }
            foreach (var d in model.State.Devices.Where(d => d.PairState == PairState.Incoming))
            {
                items.Add(Cards.PairCard(model, d, DateTimeOffset.Now));
            }
            var online = model.ConnectedPaired;
            if (online.Count > 0)
            {
                items.Add(Ui.Divider());
                foreach (var d in online)
                {
                    items.Add(ComputerMenu(d));
                }
            }
            items.Add(Ui.Divider());
            items.Add(Ui.H(4,
                new FluxButton("Open Flux", ButtonKind.Text, () => Run(panel.showMain)),
                new FluxButton("Settings…", ButtonKind.Text, () => Run(panel.showSettings)),
                Ui.Spacer(8),
                new FluxButton("Quit Flux", ButtonKind.Text, () => Run(panel.quit))));
            return new Border
            {
                Child = Ui.V(10, items),
                Background = tn.Bg,
                BorderBrush = tn.LineHi,
                BorderThickness = new Thickness(1),
                Padding = new Thickness(12),
            };
        }

        void Run(Action action)
        {
            panel.Hide();
            action();
        }

        // A row for an online computer. Its menu holds the actions of the features.
        UIElement ComputerMenu(DeviceSnapshot d)
        {
            var tn = Tn.Current;
            var row = Ui.H(10, Parts.LinkDot(true), Ui.Text(d.Name, 13, FontWeights.SemiBold).Fill(), Ui.Icon(Icons.ChevronRight, 11, tn.Sub));
            var tile = Ui.Tile(row, tn.Tile, tn.Line, 0, Metrics.SmallCorner);
            tile.Padding = new Thickness(10, 6, 10, 6);
            tile.MinHeight = Metrics.RowHeight;
            var button = new PlainButton(tile, () => { }).Named(d.Name);
            var menu = new ContextMenu();
            foreach (var (title, run) in TrayActions.For(panel.model, d))
            {
                var item = new MenuItem { Header = title };
                item.Click += (_, _) => Run(run);
                menu.Items.Add(item);
            }
            button.Click += (_, _) =>
            {
                menu.PlacementTarget = button;
                menu.IsOpen = true;
            };
            return button;
        }
    }
}

// The actions of the features for 1 computer in the tray panel.
public static class TrayActions
{
    public static List<Func<AppModel, DeviceSnapshot, (string Title, Action Run)?>> Makers { get; } = [];

    public static IEnumerable<(string Title, Action Run)> For(AppModel model, DeviceSnapshot d)
    {
        foreach (var make in Makers)
        {
            if (make(model, d) is { } a)
            {
                yield return a;
            }
        }
        yield return ("Ping", () => model.Core.Plugin<PingPlugin>()?.Ping(d.Id));
    }
}
