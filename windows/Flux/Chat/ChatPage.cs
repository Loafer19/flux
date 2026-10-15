using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using FluxKit;

namespace Flux;

// Chat: 1 thread of what happens between this computer and the computers in
// scope, with the newest entry at the bottom. The computers write on the
// left, and what this computer sent shows on the right. Before the first
// pairing, the page shows the pairing guide. ChatView.swift of the Mac app
// has the same layout.
public sealed class ChatPage : Page
{
    readonly ScrollViewer scroll = Ui.Scroll(new Border());
    readonly ChatDock chatDock;
    readonly DockPanel layout = new();
    readonly Border lineHost = new();
    readonly EventCards cards;
    bool atEnd = true;
    int lastCount;
    string online = "";

    public ChatPage(AppModel model) : base(model)
    {
        chatDock = new ChatDock(model);
        cards = new EventCards(model);
        // Files, text, and links that the user drops on the page go to the computer.
        AllowDrop = true;
        Drop += (_, e) => ShareViews.Drop(model, e);
        DockPanel.SetDock(lineHost, Dock.Top);
        layout.Children.Add(lineHost);
        DockPanel.SetDock(chatDock.Root, Dock.Bottom);
        layout.Children.Add(chatDock.Root);
        Ui.Detach(scroll);
        layout.Children.Add(scroll);
        foreach (var m in ChatFeed.Models(model))
        {
            Watch(m);
        }
        scroll.ScrollChanged += (_, e) =>
        {
            if (e.ExtentHeightChange == 0)
            {
                atEnd = scroll.VerticalOffset >= scroll.ScrollableHeight - 48;
            }
        };
    }

    public override string Title => "Chat";

    public override string Subtitle => Model.Paired.Count == 0 ? "" : Status().Context;

    ChatStatus Status() => ChatStatus.Make(Model);

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        lineHost.Child = Parts.ProgressLine(ChatFeed.Progress(Model));
        if (Model.Paired.Count == 0)
        {
            chatDock.Root.Visibility = Visibility.Collapsed;
            scroll.Content = Ui.Column(PairGuide.Build(Model), 12, 16);
            return layout;
        }
        chatDock.Root.Visibility = Visibility.Visible;
        chatDock.Update();
        // The chat asks each computer that comes online for its agents.
        var ids = string.Join(",", Model.ConnectedPaired.Select(d => d.Id));
        if (ids != online)
        {
            online = ids;
            foreach (var d in Model.ConnectedPaired)
            {
                Model.Core.Plugin<HerdrPlugin>()?.Request(d.Id);
            }
        }

        var entries = ChatFeed.Entries(Model, cards);
        var items = new List<UIElement?>();
        if (entries.Count == 0)
        {
            items.Add(Ui.Text("Agents that need you, approvals, and files from your computers show here. So do the links, text, and files that you send. To send files, drop them on this page.",
                12, color: tn.Sub, wrap: true, align: TextAlignment.Center).Margin(24, 0, 24, 0));
        }
        DateTimeOffset? last = null;
        foreach (var e in entries)
        {
            if (last is null || last.Value.ToLocalTime().Date != e.At.ToLocalTime().Date)
            {
                items.Add(Ui.Text(Texts.DayText(e.At), 11, color: tn.Sub, align: TextAlignment.Center).Align(HorizontalAlignment.Center).Margin(0, 2, 0, 2));
            }
            last = e.At;
            items.Add(e.View);
        }
        items.Add(ChatNotices.Build(Model, Status()));
        var column = Ui.V(10, items);
        var thread = new Border
        {
            Child = column,
            MaxWidth = Metrics.MaxContentWidth,
            Padding = new Thickness(14, 14, 14, 16),
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        scroll.Content = thread;
        // The view follows a new entry while it shows the end. When the user
        // scrolls up, it stays there, unless this computer sent the entry.
        if (entries.Count != lastCount && (atEnd || entries.LastOrDefault()?.Mine == true))
        {
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, scroll.ScrollToEnd);
        }
        lastCount = entries.Count;
        return layout;
    }
}

// 1 entry of the chat: its time, its view, and whether this computer wrote it.
public sealed record ChatEntryView(string Id, DateTimeOffset At, UIElement View, bool Mine = false);

// The entries of the chat in the order of Chat.Entries of FluxKit: the
// files, the texts, and the clips of the share feature, the last clip, the
// answers to approvals, and the Inbox items with the times of the app model.
// ChatView.swift of the Mac app has the same order.
public static class ChatFeed
{
    public static IEnumerable<System.ComponentModel.INotifyPropertyChanged> Models(AppModel model) =>
        new System.ComponentModel.INotifyPropertyChanged?[]
        {
            model.Core.Plugin<ClipboardPlugin>()?.Model,
            model.Core.Plugin<SharePlugin>()?.Model,
            model.Core.Plugin<HerdrPlugin>()?.Model,
            model.Core.Plugin<ApprovePlugin>()?.Model,
            ChatAnswers.Shared,
        }.OfType<System.ComponentModel.INotifyPropertyChanged>();

    // The progress of the files that come in or go out, or null.
    public static double? Progress(AppModel model) => ShareViews.Progress(model);

    // The entries of the chat in scope, oldest first. cards keeps the cards
    // of the Inbox items between the drawings.
    public static IReadOnlyList<ChatEntryView> Entries(AppModel model, EventCards cards)
    {
        var all = model.InboxItems();
        var share = model.Core.Plugin<SharePlugin>()?.Model;
        var herdr = model.Core.Plugin<HerdrPlugin>()?.Model;
        var answers = (IEnumerable<ApproveRecord>?)model.Core.Plugin<ApprovePlugin>()?.Model.History ?? [];
        var entries = Chat.Entries((IEnumerable<SentItem>?)share?.Sent ?? [], (IEnumerable<FileTransfer>?)share?.Transfers ?? [],
            model.Core.Plugin<ClipboardPlugin>()?.Model.Last, answers, all, (id, pane) => herdr?.AgentSince(id, pane), model.ChatSeen(all), model.Scope);
        var shared = ShareViews.Entries(model).ToDictionary(e => e.Id);
        cards.Keep(all.Select(i => i.Key));
        var list = new List<ChatEntryView>();
        foreach (var e in entries)
        {
            switch (e)
            {
                case ChatEntry.Event ev:
                    list.Add(new ChatEntryView(e.Id, e.At, cards.Card(ev.Item, ev.Time)));
                    break;
                case ChatEntry.Clip c:
                    list.Add(new ChatEntryView(e.Id, e.At, Cards.ClipCard(c.Value)));
                    break;
                case ChatEntry.Answer a:
                    // The user just answered, so the thread follows it.
                    list.Add(new ChatEntryView(e.Id, e.At, ApproveCards.AnswerCard(a.Record), Mine: true));
                    break;
                default:
                    if (shared.TryGetValue(e.Id, out var view))
                    {
                        list.Add(view);
                    }
                    break;
            }
        }
        return list;
    }
}

// The texts of the context line and the notices of the chat.
public sealed record ChatStatus(int Needs, int Elsewhere, string? ScopeName, IReadOnlyList<string> Offline, string? Connecting, string? PairedName)
{
    // "omarchy-xps · 2 need you". With all computers in scope, only the count shows.
    public string Context => Texts.ContextLine(ScopeName ?? "", Needs > 0 ? $"{Needs} need you" : "nothing needs you");

    public string? OfflineLine => Offline.Count switch
    {
        0 => null,
        1 => $"{Offline[0]} is not reachable. Its agents do not show here.",
        _ => $"{Offline.Count} computers are not reachable. Their agents do not show here.",
    };

    public static ChatStatus Make(AppModel model)
    {
        var all = model.InboxItems();
        var reach = FluxKit.Inbox.Reach(model.Scope, model.State.Devices);
        var needs = FluxKit.Inbox.NeedsYou(FluxKit.Inbox.InScope(all, model.Scope));
        string? pairedName = null;
        if (model.NewlyPairedId is { } id && (model.Scope is null || model.Scope == id))
        {
            pairedName = model.PairedDevice(id)?.Name;
        }
        string? connecting = null;
        if (reach.NoneOnline && model.Connecting)
        {
            connecting = reach.Offline.Count == 1 ? reach.Offline[0].Name : "";
        }
        return new ChatStatus(needs, FluxKit.Inbox.NeedsYou(all) - needs, model.PairedDevice(model.Scope)?.Name,
            model.Connecting ? [] : reach.Offline.Select(d => d.Name).ToArray(), connecting, pairedName);
    }
}

// The notices under the entries of the chat: that Flux connects, a new
// pairing, the items on other computers that need the user, and the
// computers that are not reachable.
public static class ChatNotices
{
    public static UIElement Build(AppModel model, ChatStatus status)
    {
        var tn = Tn.Current;
        var rows = new List<UIElement?>();
        if (status.Connecting is { } name)
        {
            rows.Add(Ui.H(10, Parts.Spinner(), Ui.Text(name.Length == 0 ? "Connecting to your computers" : $"Connecting to {name}", 12, color: tn.Sub))
                .Margin(10, 0, 10, 0));
        }
        if (status.PairedName is { } paired)
        {
            rows.Add(Notice(Ui.Icon(Icons.Check, 15, tn.Green), $"{paired} is paired. What waits for you on {paired} shows here first."));
        }
        if (status.Elsewhere > 0)
        {
            rows.Add(Notice(Ui.Dot(tn.Red), status.Elsewhere == 1
                    ? "1 item on another computer needs you"
                    : $"{status.Elsewhere} items on other computers need you",
                new FluxButton("Show all computers", ButtonKind.Text, () => model.SetScope(null))));
        }
        if (status.OfflineLine is { } offline)
        {
            rows.Add(Notice(Parts.LinkDot(false), offline, new FluxButton("Retry", ButtonKind.Text, model.Retry)));
        }
        return Ui.V(Metrics.Gap, rows);
    }

    // 1 notice: a mark, the text, and the action at the end of the row.
    public static UIElement Notice(UIElement mark, string text, UIElement? action = null)
    {
        var tn = Tn.Current;
        var row = Ui.H(10, Ui.Box(mark, 0, 0, 0, 0).Width(18), Ui.Text(text, 12, wrap: true).Fill(), action);
        var tile = Ui.Tile(row, tn.OffTile, tn.Line, 0);
        tile.Padding = new Thickness(10, 6, 10, 6);
        tile.MinHeight = 36;
        return tile;
    }
}

// The guide before the first pairing: what Flux is, how to set up Flux on
// the Omarchy computer, and the computers to pair, in a large tile with the
// active border.
public static class PairGuide
{
    const string InstallGuide = "https://github.com/bjarneo/flux/blob/master/docs/install.md";
    const string SetupCommand = "flux-cli setup";

    public static UIElement Build(AppModel model)
    {
        var tn = Tn.Current;
        var available = model.Available.Where(d => d.Online).ToArray();
        var items = new List<UIElement?>
        {
            Ui.Text("Pair your Omarchy computer", 20, FontWeights.SemiBold, wrap: true),
            Paragraph("Flux lets this computer answer agents, approve sudo, and send files to your Omarchy computer."),
        };
        var install = new FluxButton("Read the install guide", ButtonKind.Text, () => App.OpenUrl(InstallGuide), Icons.Open).Margin(-8, 0, 0, 0);
        if (available.Length == 0)
        {
            items.Add(Step("1. Set up Flux on the computer",
                Paragraph("Install the Flux package on the computer. Then start fluxd for your desktop user:"),
                Parts.CommandBlock(SetupCommand),
                install));
            items.Add(Step("2. Pair this computer", PairStep(model, available)));
        }
        else
        {
            items.Add(Step("Pair this computer", PairStep(model, available)));
            items.Add(Step("Another computer", Paragraph($"To add a computer, run {SetupCommand} on it."), install));
        }
        var tile = new Border
        {
            Child = Ui.V(10, items),
            Background = tn.Tile,
            BorderBrush = tn.ActiveBorder(),
            BorderThickness = new Thickness(2),
            CornerRadius = new CornerRadius(Metrics.TileCorner),
            Padding = new Thickness(20),
        };
        return tile;
    }

    static UIElement Paragraph(string text) => Ui.Text(text, 13, color: Tn.Current.Sub, wrap: true);

    static UIElement Step(string title, params UIElement?[] content) =>
        Ui.V(8, new UIElement?[] { Ui.Text(title, 15, FontWeights.SemiBold) }.Concat(content)).Margin(0, 6, 0, 0);

    static UIElement PairStep(AppModel model, IReadOnlyList<DeviceSnapshot> available)
    {
        var items = new List<UIElement?> { Paragraph("Select the computer. Then compare the key on both screens.") };
        foreach (var d in available)
        {
            items.Add(Shared.AvailableRow(d, () => model.Push(new Route.Pairing(d.Id))));
        }
        items.Add(Shared.ScanRow(model, true, available.Count == 0,
            $"Check that you ran {SetupCommand} on the computer, and that both are on the same network."));
        return Ui.V(8, items);
    }
}

// The cards of the chat.
public static class Cards
{
    // The top row of a card: the state in its color, the source in mono, and the time.
    public static UIElement Head(string state, Brush color, string source, string time, UIElement? mark = null)
    {
        var tn = Tn.Current;
        var row = Ui.H(6,
            mark,
            Ui.Text(state, 12, FontWeights.Medium, color),
            source.Length > 0 ? Ui.Text("· " + source, 12, color: tn.Sub, mono: true).Fill() : Ui.Spacer(),
            Ui.Text(time, 11, color: tn.Sub, mono: true));
        return row.Named(Texts.ContextLine(state, source, time).Replace(" · ", ", "));
    }

    // A card from a computer, on the left at 88% of the column. A card that
    // needs the user takes the full column and a red border of 2 px.
    public static UIElement InCard(UIElement head, string title, string detail = "", bool mono = false, bool ask = false,
                                   UIElement? extra = null, UIElement? action = null)
    {
        var tn = Tn.Current;
        var titleText = Ui.Text(title, 14, FontWeights.SemiBold, mono: mono, wrap: true);
        var body = Ui.V(5,
            head,
            titleText,
            detail.Length > 0 ? Ui.Text(detail, 12, color: tn.Sub, mono: true, wrap: true) : null,
            extra,
            action);
        var card = new Border
        {
            Child = body,
            Background = tn.Tile,
            BorderBrush = ask ? tn.Red : tn.Line,
            BorderThickness = new Thickness(ask ? 2 : 1),
            CornerRadius = new CornerRadius(14, 14, 14, 4),
            Padding = new Thickness(12, 10, 12, 10),
            HorizontalAlignment = ask ? HorizontalAlignment.Stretch : HorizontalAlignment.Left,
        };
        if (!ask)
        {
            return new PartWidth(card, 0.88);
        }
        return card;
    }

    // A bubble of what this computer sent, on the right at 82% of the column.
    public static UIElement OutBubble(UIElement content, string meta)
    {
        var tn = Tn.Current;
        var bubble = new Border
        {
            Child = Ui.V(4, content, Ui.Text(meta, 11, color: tn.Sub, mono: true)),
            Background = tn.AccentTile,
            BorderBrush = tn.LineHi,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16, 16, 4, 16),
            Padding = new Thickness(12, 9, 12, 9),
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        return new PartWidth(bubble, 0.82, right: true);
    }

    // A text action at the bottom of a card, in the accent.
    public static UIElement TextAction(string label, Action run, string help = "")
    {
        var t = Ui.Text(label, 13, FontWeights.SemiBold, Tn.Current.Accent).MinHeight(24);
        return new PlainButton(t, run) { HorizontalAlignment = HorizontalAlignment.Left }.Help(help.Length > 0 ? help : label);
    }

    // The last clip from a computer. A secret shows "Hidden text" in the
    // body face, and no part of the secret.
    public static UIElement ClipCard(ClipEvent clip)
    {
        var tn = Tn.Current;
        var text = clip.Secret ? ClipEvent.HiddenText : clip.Preview;
        return InCard(Head("Clipboard", tn.Cyan, clip.Computer, Texts.ClockTime(clip.At), Ui.Dot(tn.Cyan, 8)), text, mono: !clip.Secret);
    }

    // A computer that asks to pair. A click opens the pairing page.
    public static UIElement PairCard(AppModel model, DeviceSnapshot d, DateTimeOffset at)
    {
        var tn = Tn.Current;
        return InCard(Head("Pair request", tn.Red, "", Texts.ClockTime(at), Ui.Dot(tn.Red, 8)),
            $"{d.Name} asks to pair", $"Key {Certificates.FormatKey(d.PairKey)}", ask: true,
            action: TextAction("Compare the key", () =>
            {
                model.Go(Destination.Computers);
                model.Push(new Route.Pairing(d.Id));
            }));
    }
}

// A frame that gives its child a part of the width that it gets, at most,
// on the left or on the right.
public sealed class PartWidth : Decorator
{
    readonly double part;

    public PartWidth(UIElement child, double part, bool right = false)
    {
        this.part = part;
        Child = child;
        if (child is FrameworkElement fe)
        {
            fe.HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        }
    }

    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? available.Width : available.Width * part;
        Child?.Measure(new Size(width, available.Height));
        return new Size(available.Width is var w && double.IsInfinity(w) ? Child?.DesiredSize.Width ?? 0 : w, Child?.DesiredSize.Height ?? 0);
    }

    protected override Size ArrangeOverride(Size final)
    {
        if (Child is null)
        {
            return final;
        }
        var width = Math.Min(Child.DesiredSize.Width, final.Width * part);
        var left = Child is FrameworkElement { HorizontalAlignment: HorizontalAlignment.Right } ? final.Width - width : 0;
        Child.Arrange(new Rect(left, 0, width, final.Height));
        return final;
    }
}
