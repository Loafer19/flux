using System.Windows;
using System.Windows.Controls;
using FluxKit;

namespace Flux;

// The share feature in the chat: what this computer sent, the files in both
// directions, file drops, Send files, and the received files folder.
// ChatCards.swift and ShareActions.swift of the Mac app have the same parts.
public static class ShareViews
{
    // The entries of the chat from the share feature in the scope.
    public static IEnumerable<ChatEntryView> Entries(AppModel model)
    {
        if (model.Core.Plugin<SharePlugin>() is not { } share)
        {
            yield break;
        }
        var scope = model.Scope;
        var many = scope is null && model.Paired.Count > 1;
        foreach (var s in share.Model.Sent.Where(s => scope is null || s.DeviceId == scope))
        {
            var text = s.Text.Length == 0 ? "A private clip" : s.Text;
            yield return new ChatEntryView("sent|" + s.Id, s.At, Cards.OutBubble(Ui.Text(text, 12.5, mono: true, wrap: true), SentMeta(model, s, many)), true);
        }
        foreach (var t in share.Model.Transfers.Where(t => scope is null || t.DeviceId == scope))
        {
            var view = t.Incoming ? ReceivedFile(model, share, t) : SentFile(model, share, t, many);
            yield return new ChatEntryView("file|" + t.Id, t.Started, view, !t.Incoming);
        }
    }

    // The progress of the files that come in or go out in the scope, or null.
    public static double? Progress(AppModel model)
    {
        if (model.Core.Plugin<SharePlugin>() is not { } share)
        {
            return null;
        }
        var running = share.Model.Transfers.Where(t => t.State == TransferState.Running && t.Size > 0 &&
            (model.Scope is null || t.DeviceId == model.Scope)).ToArray();
        if (running.Length == 0)
        {
            return null;
        }
        var size = running.Sum(t => t.Size);
        var done = running.Sum(t => Math.Min(t.Bytes, t.Size));
        return size > 0 ? (double)done / size : 0;
    }

    static string Name(AppModel model, string id) => model.DeviceOf(id)?.Name ?? "the computer";

    // The line under a link, a text, or a clip, such as "Link · opened in the
    // browser · 13:20". With more computers in scope, it names the computer.
    static string SentMeta(AppModel model, SentItem s, bool many)
    {
        var time = Texts.ClockTime(s.At);
        var to = Name(model, s.DeviceId);
        return s.Kind switch
        {
            SentKind.Link => many ? $"Link · opened on {to} · {time}" : $"Link · opened in the browser · {time}",
            SentKind.Text => many ? $"Text · on the clipboard of {to} · {time}" : $"Text · on the clipboard · {time}",
            SentKind.Scan => many ? $"Scan · saved on {to} · {time}" : $"Scan · saved as a text file · {time}",
            _ => many ? $"Clipboard · to {to} · {time}" : $"Clipboard · {time}",
        };
    }

    static UIElement ReceivedFile(AppModel model, SharePlugin share, FileTransfer t)
    {
        var tn = Tn.Current;
        var computer = Name(model, t.DeviceId);
        var folder = t.File is { } f ? Path.GetFileName(Path.GetDirectoryName(f)) ?? "Downloads" : "Downloads";
        var (state, color, detail) = t.State switch
        {
            TransferState.Running => ("Receiving", tn.Accent, t.Fraction is { } p ? $"{(int)(p * 100)}% of {Texts.Bytes(t.Size)}" : $"{Texts.Bytes(t.Bytes)} so far"),
            TransferState.Done => ("Received", tn.Green, $"In {folder}"),
            TransferState.Canceled => ("Canceled", tn.Sub, ""),
            _ => ("Not received", tn.Red, $"Send it again from {computer}"),
        };
        UIElement mark = t.State == TransferState.Running ? Parts.Spinner(11) : Ui.Dot(color, 8);
        var bar = t.State == TransferState.Running && t.Fraction is { } fraction ? Bar(fraction) : null;
        UIElement? action = t.State == TransferState.Done && t.File is { } file
            ? Cards.TextAction("Open", () => ThisComputer.Open(file), $"Open {t.Name}")
            : t.State == TransferState.Running ? Cards.TextAction("Cancel", () => share.Cancel(t.Id), $"Cancel {t.Name}") : null;
        var card = Cards.InCard(Cards.Head(state, color, computer, Texts.ClockTime(t.Started), mark), t.Name, detail, mono: true, extra: bar, action: action);
        card.SetValue(FrameworkElement.ContextMenuProperty, Menu(share, t));
        return card;
    }

    static UIElement SentFile(AppModel model, SharePlugin share, FileTransfer t, bool many)
    {
        var tn = Tn.Current;
        var to = Name(model, t.DeviceId);
        var pct = t.Fraction is { } p ? $"{(int)(p * 100)}% of {Texts.Bytes(t.Size)}" : $"{Texts.Bytes(t.Bytes)} so far";
        var time = Texts.ClockTime(t.Ended ?? t.Started);
        var meta = t.State switch
        {
            TransferState.Running => (many ? $"Sending to {to}" : "Sending") + " · " + pct,
            TransferState.Done => (many ? $"Sent to {to}" : "Sent") + " · " + time,
            TransferState.Canceled => "Canceled · " + time,
            _ => "Not sent · " + time,
        };
        UIElement state = t.State switch
        {
            TransferState.Running => Parts.Spinner(14),
            TransferState.Done => Ui.Icon(Icons.Check, 13, tn.Green),
            _ => Ui.Icon(Icons.Close, 13, t.State == TransferState.Failed ? tn.Red : tn.Sub),
        };
        var image = Path.GetExtension(t.Name).ToLowerInvariant() is ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".heic" or ".bmp";
        var row = Ui.H(10,
            Ui.Icon(image ? Icons.Photo : Icons.Document, 18, tn.Accent, 22),
            Ui.V(2, Ui.Text(t.Name, 13, FontWeights.Medium, mono: true), Ui.Text(meta, 12, color: t.State == TransferState.Failed ? tn.Red : tn.Sub, wrap: true)).Fill(),
            state);
        var body = Ui.V(8, row, t.State == TransferState.Running && t.Fraction is { } f ? Bar(f) : null);
        var card = new Border
        {
            Child = body,
            Width = 236,
            Background = tn.AccentTile,
            BorderBrush = tn.LineHi,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16, 16, 4, 16),
            Padding = new Thickness(12, 10, 12, 10),
            HorizontalAlignment = HorizontalAlignment.Right,
            ToolTip = t.Name,
            ContextMenu = Menu(share, t),
        };
        return card;
    }

    // A bar of 3 px with the part done in the accent.
    static UIElement Bar(double fraction)
    {
        var bar = Parts.ProgressLine(fraction);
        bar.Height = 3;
        return bar.Margin(0, 2, 0, 0);
    }

    static ContextMenu Menu(SharePlugin share, FileTransfer t)
    {
        var menu = new ContextMenu();
        if (t.State == TransferState.Done && t.File is { } file)
        {
            if (t.Incoming)
            {
                menu.Items.Add(Item("Open", () => ThisComputer.Open(file)));
            }
            menu.Items.Add(Item("Show in folder", () => ThisComputer.ShowInFolder(file)));
        }
        if (t.State == TransferState.Running)
        {
            menu.Items.Add(Item("Cancel", () => share.Cancel(t.Id)));
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Clear finished transfers", share.Model.ClearFinished));
        return menu;
    }

    static MenuItem Item(string header, Action run)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => run();
        return item;
    }

    // Sends the files to the computer for the action: the computer in scope,
    // or the 1 online computer, or the one that the user picks. A folder is
    // not sent.
    public static void SendFiles(AppModel model, IReadOnlyList<string> files)
    {
        if (files.Count == 0 || model.Core.Plugin<SharePlugin>() is not { } share)
        {
            return;
        }
        if (Targets.Pick(model, PacketType.Share) is { } id)
        {
            share.SendFiles(files, id);
        }
    }

    // Asks for files and sends them.
    public static void PickAndSend(AppModel model)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = "Send files" };
        if (dialog.ShowDialog(Application.Current?.MainWindow) == true)
        {
            SendFiles(model, dialog.FileNames);
        }
    }

    // Takes files or text that the user drops on the chat.
    public static void Drop(AppModel model, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files)
        {
            SendFiles(model, files.Where(File.Exists).ToArray());
        }
        else if (e.Data.GetData(DataFormats.UnicodeText) is string text && text.Trim().Length > 0 &&
                 model.Core.Plugin<SharePlugin>() is { } share && Targets.Pick(model, PacketType.Share) is { } id)
        {
            share.SendText(text.Trim(), id);
        }
    }

    // The received files folder, with Choose.
    public static (string Label, UIElement Content)? Settings(AppModel model)
    {
        if (model.Core.Plugin<SharePlugin>() is not { } share)
        {
            return null;
        }
        var choose = new FluxButton("Choose…", ButtonKind.Outlined, () =>
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Received files", InitialDirectory = share.DownloadFolder };
            if (dialog.ShowDialog(Application.Current?.MainWindow) == true)
            {
                share.SetDownloadFolder(dialog.FolderName);
            }
        });
        return ("Files", SettingsView.Group(
            SettingsView.Field("Received files", Ui.H(8, Ui.Text(share.DownloadFolder, 12, mono: true).Fill(), choose)),
            SettingsView.Toggle("Show Flux in the Send to menu", SendToMenu.Enabled, on =>
            {
                if (!SendToMenu.Set(on))
                {
                    model.Show("Windows did not change the Send to menu");
                }
            }),
            SettingsView.Note("Received files never open by themselves. Windows checks them before they open, as files from the internet.")));
    }
}
