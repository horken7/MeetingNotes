using System.Drawing;
using System.Drawing.Drawing2D;
using MeetingNotes.Core;
using Forms = System.Windows.Forms;

namespace MeetingNotes;

/// The notification-area icon: a waveform when idle, a red dot while recording (a stop square while auto-stop
/// counts down), an hourglass while transcribing or writing notes. Its menu has start/stop and the window.
sealed class Tray : IDisposable
{
    readonly Forms.NotifyIcon icon = new();
    readonly AppModel model;
    readonly Action quit;
    readonly Dictionary<string, Icon> icons = new();
    string shown = "";

    public Tray(AppModel model, Action quit)
    {
        this.model = model;
        this.quit = quit;
        icon.ContextMenuStrip = new Forms.ContextMenuStrip();
        icon.ContextMenuStrip.Opening += (_, _) => BuildMenu();
        icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) App.ShowMainWindow(); };
        BuildMenu();
        model.Changed += Refresh;
        Refresh();
        icon.Visible = true;
    }

    void Refresh()
    {
        string state;
        string tip;
        if (model.Recording is { } r)
        {
            state = r.StopsAt == null ? "recording" : "stopping";
            tip = $"Recording: {r.Title}";
        }
        else if (model.Meetings.Any(m => m.Status is "transcribing" or "summarizing"))
        {
            state = "busy";
            tip = "Meeting Notes: working on notes";
        }
        else
        {
            state = "idle";
            tip = "Meeting Notes";
        }
        if (state != shown)
        {
            icon.Icon = Icon(state);
            shown = state;
        }
        icon.Text = tip.Length > 63 ? tip[..63] : tip;
    }

    void BuildMenu()
    {
        var menu = icon.ContextMenuStrip!;
        menu.Items.Clear();
        if (model.Recording is { } r)
        {
            menu.Items.Add(new Forms.ToolStripMenuItem($"Recording: {r.Title} · {Format.Duration((DateTime.Now - r.Start).TotalSeconds)}") { Enabled = false });
            if (r.StopsAt is { } at)
                menu.Items.Add(new Forms.ToolStripMenuItem($"Call ended. Stopping in {Math.Max(0, (int)(at - DateTime.Now).TotalSeconds)} s") { Enabled = false });
            menu.Items.Add("Stop and take notes", null, (_, _) => model.Stop());
        }
        else
        {
            var start = new Forms.ToolStripMenuItem("Start meeting notes", null, (_, _) => model.Start()) { Enabled = !model.Starting };
            menu.Items.Add(start);
        }
        foreach (var m in model.Meetings.Where(m => m.Status is "transcribing" or "summarizing"))
            menu.Items.Add(new Forms.ToolStripMenuItem($"{(m.Status == "transcribing" ? "Transcribing" : "Writing notes")}: {m.Title}") { Enabled = false });
        menu.Items.Add(new Forms.ToolStripSeparator());
        var open = new Forms.ToolStripMenuItem("Open Meeting Notes", null, (_, _) => App.ShowMainWindow());
        open.Font = new Font(open.Font, System.Drawing.FontStyle.Bold);
        menu.Items.Add(open);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Meeting Notes", null, (_, _) => quit());
    }

    Icon Icon(string state)
    {
        if (icons.TryGetValue(state, out var cached)) return cached;
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            var green = Color.FromArgb(46, 125, 91);
            switch (state)
            {
                case "recording":
                    using (var b = new SolidBrush(Color.FromArgb(211, 47, 47))) g.FillEllipse(b, 3, 3, 26, 26);
                    using (var b = new SolidBrush(Color.White)) g.FillEllipse(b, 11, 11, 10, 10);
                    break;
                case "stopping":
                    using (var p = new Pen(Color.FromArgb(211, 47, 47), 3)) g.DrawEllipse(p, 3, 3, 26, 26);
                    using (var b = new SolidBrush(Color.FromArgb(211, 47, 47))) g.FillRectangle(b, 11, 11, 10, 10);
                    break;
                case "busy":
                    using (var b = new SolidBrush(green))
                    {
                        g.FillPolygon(b, new[] { new Point(7, 3), new Point(25, 3), new Point(16, 16) });
                        g.FillPolygon(b, new[] { new Point(16, 16), new Point(25, 29), new Point(7, 29) });
                    }
                    break;
                default:
                    using (var b = new SolidBrush(green))
                    {
                        using var path = new GraphicsPath();
                        path.AddArc(1, 1, 10, 10, 180, 90);
                        path.AddArc(21, 1, 10, 10, 270, 90);
                        path.AddArc(21, 21, 10, 10, 0, 90);
                        path.AddArc(1, 21, 10, 10, 90, 90);
                        g.FillPath(b, path);
                    }
                    using (var w = new SolidBrush(Color.White))
                    {
                        int[] heights = { 8, 16, 22, 12, 18, 8 };
                        for (var i = 0; i < heights.Length; i++)
                            g.FillRectangle(w, 5 + i * 4, 16 - heights[i] / 2, 2, heights[i]);
                    }
                    break;
            }
        }
        var handle = bmp.GetHicon();
        var result = (Icon)System.Drawing.Icon.FromHandle(handle).Clone();
        Native.DestroyIcon(handle);
        icons[state] = result;
        return result;
    }

    public void Dispose()
    {
        model.Changed -= Refresh;
        icon.Visible = false;
        icon.Dispose();
        foreach (var i in icons.Values) i.Dispose();
    }
}
