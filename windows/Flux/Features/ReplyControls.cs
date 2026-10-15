using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FluxKit;

namespace Flux;

// The dock of an agent under its thread. A blocked agent shows its question
// and the choices, with Write for a text answer. A working agent shows its
// step and Interrupt. A finished agent shows the end of its turn. The key
// row shows while the Keys toggle is on. Under that, the composer takes a
// prompt as text or as dictation. Each reply asks for Windows Hello first,
// see ReplyLock. ReplyControls.swift and ReplyField.swift of the Mac app
// have the same parts.
public sealed class ReplyControls : View
{
    readonly AgentsWindowModel model;
    readonly string pane;
    readonly AgentDetail detail;
    readonly TextBox field;
    readonly TextBlock hint = Ui.Text("", 13);
    readonly Border fieldFrame;
    readonly Border sendTile = new() { Width = 34, Height = 34, CornerRadius = new CornerRadius(17) };
    readonly PlainButton sendKey;
    readonly Border micTile = new() { Width = 34, Height = 34, CornerRadius = new CornerRadius(17) };
    readonly PlainButton micKey;
    // The parts of the dock stay across the drawings, so that the reply
    // field keeps its place and its focus.
    readonly Border topHost = new();
    readonly Border keysHost = new();
    readonly Border listeningHost = new();
    readonly Border problemHost = new();
    readonly Stack composerRow;
    readonly Border dock;
    // Moves the time of a dictation each second.
    readonly System.Windows.Threading.DispatcherTimer listenClock = new() { Interval = TimeSpan.FromSeconds(1) };
    HerdrAgent? agent;
    HerdrOutput? output;
    AgentThread? thread;
    AgentAsk? ask;
    Action? review;
    string? lockError;
    // True while a blocked agent shows the composer in the place of its choices.
    bool writing;
    // The output that the last answer answered.
    HerdrOutput? answered;
    // The number of the last reply that cleared the field.
    int handledReply;

    public ReplyControls(AgentsWindowModel model, string pane, AgentDetail detail)
    {
        this.model = model;
        this.pane = pane;
        this.detail = detail;
        field = AgentParts.ReplyField(Send);
        field.Text = model.Drafts.GetValueOrDefault(pane) ?? "";
        field.CaretIndex = field.Text.Length;
        field.TextChanged += (_, _) =>
        {
            model.Drafts[pane] = field.Text;
            UpdateSend();
        };
        var clear = AgentParts.ClearKey(field);
        var row = Ui.H(4, AgentParts.WithHint(field, hint).Fill(), clear.Margin(0, 0, 8, 0));
        fieldFrame = new Border { Child = row, CornerRadius = new CornerRadius(18), BorderThickness = new Thickness(1), Padding = new Thickness(6, 0, 0, 0) };
        sendKey = new PlainButton(sendTile, Send).Named("Send");
        micKey = new PlainButton(micTile, Dictate).Named("Dictate").Help("Dictate the text");
        composerRow = Ui.H(8, fieldFrame.Fill(), micKey.Top(), sendKey.Top());
        dock = Parts.PageDock(Ui.V(10, topHost, keysHost, composerRow, listeningHost, problemHost), 14);
        handledReply = Reply?.Seq ?? 0;
        Watch(model.Dictation);
        listenClock.Tick += (_, _) => Invalidate();
        Unloaded += (_, _) => listenClock.Stop();
    }

    HerdrPlugin Plugin => model.Plugin;
    HerdrReply? Reply => Plugin.Model.Reply(model.DeviceId, pane);
    Dictation Dictation => model.Dictation;

    // The text in the field. Tests read it.
    internal TextBox Field => this.field;

    // Puts the text of a first task that did not go in the field, unless
    // the user wrote something there.
    public void Fill(string text)
    {
        if (field.Text.Length == 0)
        {
            field.Text = text;
            field.CaretIndex = text.Length;
        }
    }

    // Draws the dock for the agent, its output, and its thread. The detail
    // calls it at each drawing.
    public void Show(HerdrAgent agent, HerdrOutput? output, AgentThread? thread, AgentAsk? ask, Action? review)
    {
        this.agent = agent;
        this.output = output;
        this.thread = thread;
        this.ask = ask;
        this.review = review;
        Redraw();
    }

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        if (agent is null)
        {
            return new Border();
        }
        var reply = Reply;
        // A prompt that the computer accepted leaves the field.
        if (reply is { Action: "prompt", Sending: false, Error: null } && reply.Seq != handledReply)
        {
            handledReply = reply.Seq;
            field.Clear();
            model.Drafts.Remove(pane);
            writing = false;
        }
        var blocked = agent.Status == AgentStatus.Blocked;
        var choices = blocked && output is not null ? output.Choices : ValueList<AgentChoice>.Empty;
        var asking = blocked && choices.Count > 0 && !writing;
        var sendingPrompt = reply is { Sending: true, Action: "prompt" };
        var top = new List<UIElement?>();
        if (blocked)
        {
            top.Add(AskHeader(choices.Count > 0));
            if (asking)
            {
                if (ask is not null)
                {
                    top.Add(AgentParts.AskText(ask, 15, true, 6).Margin(4, 0, 4, 0));
                }
                // A choice takes no click while a reply goes, and after an answer until the next output.
                var open = reply?.Sending != true && (answered is null || output != answered && output?.Loading == false);
                top.Add(Ui.V(6, choices.Select((c, i) => (UIElement)AgentParts.AskChoiceButton(c, i == 0, open, () => Answer(c)))));
            }
        }
        else if (agent.Status == AgentStatus.Working)
        {
            top.Add(WorkingRow());
        }
        else if (agent.Status == AgentStatus.Done)
        {
            top.Add(DoneRow());
        }
        Put(topHost, top.Count == 0 ? null : Ui.V(10, top));
        Put(keysHost, detail.KeysOpen ? KeyRow(blocked && choices.Count == 0) : null);
        var listening = Dictation.State != Dictation.Phase.Idle;
        if (listening)
        {
            listenClock.Start();
        }
        else
        {
            listenClock.Stop();
        }
        Composer(sendingPrompt);
        composerRow.Shown(!asking && !listening);
        Put(listeningHost, !asking && listening ? Listening() : null);
        Put(problemHost, (lockError ?? Dictation.Error ?? reply?.Error) is { } problem ? ProblemRow(problem, reply) : null);
        dock.Background = tn.Tile;
        dock.BorderBrush = tn.Line;
        return dock;
    }

    // Puts the content in the host, and hides an empty host, so that it takes no gap.
    static void Put(Border host, UIElement? content)
    {
        if (content is not null)
        {
            Ui.Detach(content);
        }
        host.Child = content;
        host.Shown(content is not null);
    }

    // The top row of the dock of a blocked agent: the agent asks, then
    // Write. Write shows the composer in the place of the choices, and
    // Choices shows the choices again.
    UIElement AskHeader(bool hasChoices)
    {
        var tn = Tn.Current;
        return Ui.H(8,
            AgentParts.PulseDot(tn.Red),
            Ui.Text($"{agent!.Agent} asks", 12, FontWeights.Medium, tn.Red).Fill(),
            hasChoices
                ? new FluxButton(writing ? "Choices" : "Write", ButtonKind.Text, () =>
                {
                    writing = !writing;
                    Invalidate();
                }, Icons.Edit).Help(writing ? "Show the choices" : "Write an answer in the place of the choices")
                : null).Margin(4, 0, 4, 0).MinHeight(24);
    }

    // The dock row of a working agent: its step and time, and Interrupt,
    // which sends Escape.
    UIElement WorkingRow()
    {
        var tn = Tn.Current;
        var step = thread?.Step is { Length: > 0 } s ? s : "Working";
        var line = string.Join(" · ", new[] { thread?.Elapsed ?? "", $"{agent!.Agent} is working" }.Where(p => p.Length > 0));
        var interrupt = new PlainButton(new Border
        {
            Child = Ui.H(6, Ui.Text("Interrupt", 12, FontWeights.SemiBold), Ui.Text("esc", 11, color: tn.Sub, mono: true)),
            Background = tn.Line,
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            Padding = new Thickness(12, 0, 12, 0),
            MinHeight = Metrics.ButtonHeight,
        }, () => Keys("esc")).Named($"Interrupt {agent.Agent}").Help($"Send Escape to {agent.Agent}");
        return Ui.H(12,
            Parts.Spinner(18, tn.Accent),
            Ui.V(2, Ui.Text(step, 13, FontWeights.SemiBold, maxLines: 2), Ui.Text(line, 11, color: tn.Sub, mono: true)).Fill(),
            interrupt).Margin(4, 0, 4, 0);
    }

    // The dock row of a finished agent: the end of its turn, and Review changes.
    UIElement DoneRow()
    {
        var tn = Tn.Current;
        return Ui.H(10,
            Ui.Icon(AgentGlyphs.Completed, 14, tn.Green),
            Ui.Text(AgentParts.DoneText(thread?.Worked ?? ""), 13, FontWeights.SemiBold).Fill(),
            review is { } r ? new FluxButton("Review changes", ButtonKind.Text, r).Named("Review changes").Help("Show the changes of the repository (Ctrl+D)") : null)
            .Margin(4, 0, 4, 0).MinHeight(24);
    }

    // The keys Esc, Tab, Up, Down, and Enter. accent marks Enter when the
    // dialog needs it.
    UIElement KeyRow(bool accent)
    {
        (string Label, string Key, string Help)[] keys =
            [("esc", "esc", "Escape"), ("tab", "tab", "Tab"), ("↑", "up", "Up"), ("↓", "down", "Down"), ("enter", "enter", "Enter")];
        var buttons = keys.Select(k => (UIElement)KeyButton(k.Label, k.Help, accent && k.Key == "enter", () => Keys(k.Key))).ToArray();
        return Parts.GridRows(buttons, buttons.Length);
    }

    static UIElement KeyButton(string label, string help, bool accent, Action action)
    {
        var tn = Tn.Current;
        var tile = new Border
        {
            Child = Ui.Text(label, 12, FontWeights.Medium, accent ? tn.Accent : tn.Sub, mono: true, align: TextAlignment.Center),
            Background = accent ? tn.AccentTile : tn.Bg,
            BorderBrush = accent ? tn.Accent : tn.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            MinHeight = Metrics.ButtonHeight,
        };
        return new PlainButton(tile, action).Named(help).Help(help);
    }

    // The composer: the reply field, the mic key, and the send key. While
    // this computer listens, a bar with the words and Stop takes its place.
    void Composer(bool sending)
    {
        var tn = Tn.Current;
        var a = agent!;
        hint.Text = a.Status switch
        {
            AgentStatus.Blocked => $"Tell {a.Agent} what to do differently",
            AgentStatus.Working => $"Steer {a.Agent} while it works",
            _ => $"Write to {a.Agent}",
        };
        hint.Foreground = tn.Dim;
        System.Windows.Automation.AutomationProperties.SetName(field, hint.Text);
        field.Foreground = tn.Text;
        field.CaretBrush = tn.Accent;
        fieldFrame.Background = tn.Bg;
        fieldFrame.BorderBrush = tn.LineHi;
        sendTile.Child = sending ? Parts.Spinner(14, tn.OnAccent) : Ui.Icon(AgentGlyphs.ArrowUp, 14, tn.OnAccent);
        sendTile.Background = tn.Accent;
        sendKey.Help($"Send the text to {a.Agent}");
        UpdateSend();
        micTile.Background = tn.Line;
        micTile.Child = Ui.Icon(Icons.Mic, 14, tn.Text);
    }

    void UpdateSend()
    {
        var sending = Reply is { Sending: true, Action: "prompt" };
        // The key keeps its color with no text. It takes no click then.
        sendKey.IsEnabled = field.Text.Trim().Length > 0 && !sending;
        sendKey.Opacity = 1;
    }

    // The bar while this computer listens: the time, the words, and Stop.
    UIElement Listening()
    {
        var tn = Tn.Current;
        var d = Dictation;
        var words = d.Partial.Length > 0 ? d.Partial : d.State == Dictation.Phase.Starting ? "Starting…" : "Listening…";
        var stop = new PlainButton(new Border
        {
            Child = Ui.Icon(AgentGlyphs.Stop, 13, tn.OnAccent),
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(17),
            Background = tn.Red,
        }, d.Stop).Named("Stop the dictation").Help("Stop the dictation");
        var language = Plugin.Model.DictationLanguage;
        var bar = Ui.H(10,
            AgentParts.PulseDot(tn.Red),
            Ui.V(2,
                Ui.Text(Texts.ContextLine(language.Length == 0 ? "Automatic" : DictationText.LanguageName(language), d.Clock), 11, color: tn.Sub, mono: true),
                Ui.Text(words, 13, wrap: true)).Fill(),
            stop);
        return new Border
        {
            Child = bar,
            Background = tn.Bg,
            BorderBrush = tn.Accent,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(18),
            Padding = new Thickness(14, 6, 6, 6),
        }.Named("Dictation");
    }

    // The problem under the dock, with the action that solves it.
    UIElement ProblemRow(string problem, HerdrReply? reply)
    {
        var tn = Tn.Current;
        var actions = new List<UIElement?>();
        if (problem == Dictation.Error && Dictation.LanguageError)
        {
            FluxButton? choose = null;
            choose = new FluxButton("Choose a language", ButtonKind.Text, () => LanguageMenu(choose!)).Named("Choose a language");
            actions.Add(choose);
        }
        if (problem is Dictation.SpeechDenied or Dictation.MicDenied)
        {
            var settings = problem == Dictation.SpeechDenied ? "ms-settings:privacy-speech" : "ms-settings:privacy-microphone";
            actions.Add(new FluxButton("Open Privacy Settings", ButtonKind.Text, () => ThisComputer.Open(settings)).Named("Open Privacy Settings"));
        }
        // fluxd refused the prompt because the agent waits for a choice. The
        // user can type the same text into the dialog.
        if (problem == reply?.Error && reply.Blocked && reply.Text is { } text)
        {
            actions.Add(new FluxButton("Send as answer", ButtonKind.Text, () => AnswerText(text)).Named("Send as answer").Help($"Type the text into the dialog of {agent!.Agent}"));
        }
        return Ui.H(10, new UIElement?[] { Ui.Text(problem, 12, color: tn.Red, wrap: true).Fill() }.Concat(actions));
    }

    // The languages of the recognizer, with Automatic first. A pick starts the dictation again.
    void LanguageMenu(FrameworkElement anchor)
    {
        var menu = new ContextMenu { PlacementTarget = anchor };
        var current = Plugin.Model.DictationLanguage;
        foreach (var tag in new[] { "" }.Concat(Dictation.Languages()))
        {
            var item = new MenuItem { Header = tag.Length == 0 ? "Automatic" : DictationText.LanguageName(tag), IsChecked = tag == current };
            item.Click += (_, _) =>
            {
                Plugin.Model.DictationLanguage = tag;
                Dictate();
            };
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    void Guarded(Action action)
    {
        lockError = null;
        ReplyLock.Run($"answer agents on {model.Name}", Window.GetWindow(this), action, message =>
        {
            lockError = message;
            Invalidate();
        });
    }

    void Keys(string key)
    {
        var deviceId = model.DeviceId;
        Guarded(() => Plugin.SendKeys(deviceId, pane, [key]));
    }

    // Sends the keys of a choice, and keeps the answer for the thread: the
    // digit of a numbered dialog, or the arrows and Enter of a menu.
    void Answer(AgentChoice c)
    {
        var deviceId = model.DeviceId;
        var shown = output;
        var last = thread?.Blocks.LastOrDefault();
        Guarded(() =>
        {
            answered = shown;
            detail.Answered(new SentAnswer(c.Label, c.SentMeta, last));
            Plugin.SendKeys(deviceId, pane, c.Keys);
            Invalidate();
        });
    }

    void Send()
    {
        var text = field.Text;
        if (text.Trim().Length == 0 || Reply is { Sending: true, Action: "prompt" })
        {
            return;
        }
        var deviceId = model.DeviceId;
        Guarded(() => Plugin.SendPrompt(deviceId, pane, text));
    }

    // Sends the text of a refused prompt again as the answer to the dialog of the agent.
    void AnswerText(string text)
    {
        if (Reply?.Sending == true)
        {
            return;
        }
        var deviceId = model.DeviceId;
        Guarded(() => Plugin.SendPrompt(deviceId, pane, text, answer: true));
    }

    // Starts a dictation into the field of this agent. The text waits in
    // the field for Send, so a prompt still needs the lock.
    void Dictate()
    {
        lockError = null;
        Dictation.Start(Plugin.Model.DictationLanguage, spoken =>
        {
            var edit = DictationText.Insert(field.Text, field.SelectionStart, field.SelectionStart + field.SelectionLength, spoken);
            field.Text = edit.Text;
            field.CaretIndex = edit.Cursor;
            field.Focus();
        });
    }
}
