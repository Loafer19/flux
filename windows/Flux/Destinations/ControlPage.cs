using System.Windows;
using FluxKit;

namespace Flux;

// Control: the tools for the computers in scope. It opens with 1 master
// tool, then groups of tool rows under section labels. The features add the
// tools. ControlView.swift of the Mac app has the same order.
public sealed class ControlPage : Page
{
    public ControlPage(AppModel model) : base(model)
    {
        foreach (var m in ControlTools.Models(model))
        {
            Watch(m);
        }
    }

    public override string Title => "Control";

    public override string Subtitle => Texts.ContextLine(Shared.OnlineText(Model), Model.Paired.Count == 0 ? "" : $"{Shared.ScopeName(Model)} in scope");

    protected override UIElement Build()
    {
        if (Model.Paired.Count == 0)
        {
            return Parts.Unavailable(Icons.Control, "No computer is paired", "Pair your Omarchy computer in Computers. Its tools then show here.");
        }
        var sections = ControlTools.Sections(Model).ToArray();
        if (sections.Length == 0)
        {
            return Parts.Unavailable(Icons.Control, "No tools", "The tools of your computers show here.");
        }
        var items = new List<UIElement?>();
        foreach (var (label, content) in sections)
        {
            if (label.Length > 0)
            {
                items.Add(Parts.SectionLabel(label));
            }
            items.Add(content);
        }
        return Ui.Scroll(Ui.Column(Ui.V(Metrics.Gap, items), 8, 24));
    }
}

// The sections of Control that the features add, in reading order: a label
// and the content. A feature returns nothing when no computer in scope can
// take it.
public static class ControlTools
{
    public static List<Func<AppModel, (string Label, UIElement Content)?>> Makers { get; } = [];
    public static List<Func<AppModel, System.ComponentModel.INotifyPropertyChanged?>> ModelMakers { get; } = [];

    public static IEnumerable<System.ComponentModel.INotifyPropertyChanged> Models(AppModel model) =>
        ModelMakers.Select(m => m(model)).OfType<System.ComponentModel.INotifyPropertyChanged>();

    public static IEnumerable<(string Label, UIElement Content)> Sections(AppModel model)
    {
        foreach (var make in Makers)
        {
            if (make(model) is { } s)
            {
                yield return s;
            }
        }
    }
}
