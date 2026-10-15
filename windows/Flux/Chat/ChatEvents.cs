using System.Collections.Immutable;
using System.ComponentModel;
using FluxKit;

namespace Flux;

// The times of the chat and the reply of the dock: the first time that this
// computer saw each Inbox item, and the reply that the dock writes to an
// agent. AppModel.swift of the Mac app has the same parts.
public sealed partial class AppModel
{
    readonly SeenClock seenClock = new();
    ImmutableDictionary<string, DateTimeOffset> seen = ImmutableDictionary<string, DateTimeOffset>.Empty;
    ChatReply? chatReply;
    bool watchingEvents;

    // The first time that this computer saw each Inbox item of all
    // computers, by key. See WatchEvents.
    public IReadOnlyDictionary<string, DateTimeOffset> Seen => seen;

    // The reply that the dock of the chat writes to an agent in the place of
    // a choice, or null.
    public ChatReply? ChatReply
    {
        get => chatReply;
        set => Set(ref chatReply, value);
    }

    // The Inbox items of all computers: the agents and the pair requests.
    public IReadOnlyList<InboxItem> InboxItems() => FluxKit.Inbox.Items(Core, State.Devices);

    // Keeps the times and the prompts of the Inbox items of all computers
    // while the app runs, also while no window shows them. It runs again
    // after each change of the computers or of the agents. Call it once at
    // the start.
    public void WatchEvents()
    {
        if (watchingEvents)
        {
            return;
        }
        watchingEvents = true;
        PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(State))
            {
                EventsChanged();
            }
        };
        if (Core.Plugin<HerdrPlugin>() is { } herdr)
        {
            herdr.Model.PropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(HerdrModel.States))
                {
                    EventsChanged();
                }
            };
        }
        EventsChanged();
    }

    // Records the first time of each new item, and keeps the prompt of each
    // agent that waits or works. A reply to an agent ends when the agent no
    // longer waits. A new set of items changes Seen, so that the views that
    // count the items draw again.
    void EventsChanged()
    {
        var items = InboxItems();
        var next = seenClock.Update(items.Select(i => i.Key), DateTimeOffset.Now);
        if (next.Count != seen.Count || next.Any(e => !seen.TryGetValue(e.Key, out var at) || at != e.Value))
        {
            seen = next;
            Changed(nameof(Seen));
        }
        var keys = new HashSet<string>();
        foreach (var item in items)
        {
            if (item.Content is InboxContent.Agent { Value.Status: AgentStatus.Blocked or AgentStatus.Working } a)
            {
                keys.Add(HerdrModel.PromptKey(a.DeviceId, a.Value.Pane));
            }
        }
        Core.Plugin<HerdrPlugin>()?.KeepPrompts(keys);
        // A reply ends when its agent no longer waits for the choice.
        if (ChatReply is { } r && !items.Any(i => i.Content is InboxContent.Agent { Value.Status: AgentStatus.Blocked } a &&
                                                   a.DeviceId == r.DeviceId && a.Value.Pane == r.Pane))
        {
            ChatReply = null;
        }
    }

    // The times of the chat for the items: the first time of each item, or
    // now for an item that WatchEvents did not record yet.
    public IReadOnlyDictionary<string, DateTimeOffset> ChatSeen(IEnumerable<InboxItem> items, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.Now;
        var missing = items.Where(i => !seen.ContainsKey(i.Key)).ToArray();
        if (missing.Length == 0)
        {
            return seen;
        }
        var output = seen.ToBuilder();
        foreach (var item in missing)
        {
            output[item.Key] = at;
        }
        return output.ToImmutable();
    }

    // The models that a view of the Inbox items watches: the app model and
    // the agents.
    public IEnumerable<INotifyPropertyChanged> InboxModels() =>
        new INotifyPropertyChanged?[] { this, Core.Plugin<HerdrPlugin>()?.Model }.OfType<INotifyPropertyChanged>();
}
