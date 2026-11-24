using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;
using System.Drawing;
using System.Windows.Forms;

internal sealed class StatusWindow : Form
{
    readonly string path;
    readonly Process owner;
    readonly Label phase = new Label();
    readonly Label detail = new Label();
    readonly ProgressBar progress = new ProgressBar();
    readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    DateTime closeAt = DateTime.MaxValue;
    string last;

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            var p = base.CreateParams;
            p.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
            return p;
        }
    }

    public StatusWindow(string path, int ownerId)
    {
        this.path = path;
        owner = Process.GetProcessById(ownerId);
        Text = "Silero · Cortar silencios";
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        ControlBox = false;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(352, 112);
        var screen = Screen.FromHandle(owner.MainWindowHandle).WorkingArea;
        Location = new Point(screen.Right - Width - 16, screen.Bottom - Height - 16);
        BackColor = Color.FromArgb(36, 38, 42);
        phase.SetBounds(14, 12, 324, 26);
        phase.ForeColor = Color.White;
        phase.Font = new Font("Segoe UI", 11, FontStyle.Bold);
        phase.Text = "Preparando…";
        detail.SetBounds(14, 42, 324, 40);
        detail.ForeColor = Color.Gainsboro;
        detail.AutoEllipsis = true;
        progress.SetBounds(14, 88, 324, 8);
        progress.Style = ProgressBarStyle.Marquee;
        Controls.AddRange(new Control[] { phase, detail, progress });
        timer.Interval = 100;
        timer.Tick += delegate { RefreshStatus(); };
        timer.Start();
    }

    void RefreshStatus()
    {
        if (owner.HasExited || DateTime.UtcNow >= closeAt) { Close(); return; }
        string record;
        try
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var reader = new StreamReader(stream))
                record = reader.ReadToEnd();
        }
        catch (IOException) { return; }
        if (record == last || !record.EndsWith("\n")) return;
        var parts = record.TrimEnd('\r', '\n').Split('\t');
        if (parts.Length != 4) return;
        last = record;
        phase.Text = parts[2];
        detail.Text = parts[3];
        int value;
        if (int.TryParse(parts[1], out value) && value >= 0)
        {
            progress.Style = ProgressBarStyle.Continuous;
            progress.Value = Math.Min(value, 100);
        }
        else progress.Style = ProgressBarStyle.Marquee;
        if (parts[0] == "done") closeAt = DateTime.UtcNow.AddSeconds(5);
        if (parts[0] == "error")
        {
            progress.Visible = false;
            ControlBox = true;
            closeAt = DateTime.UtcNow.AddSeconds(35);
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        timer.Dispose();
        owner.Dispose();
        try { File.Delete(path); } catch (IOException) { }
        base.OnFormClosed(e);
    }
}

internal static class ResolveMenu
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int x, int y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    static AutomationElement Find(AutomationElement root, string name)
    {
        return root.FindFirst(TreeScope.Descendants, new AndCondition(
            new PropertyCondition(AutomationElement.NameProperty, name),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuItem)));
    }

    static void CheckCancellation(string session)
    {
        if (File.Exists(session + ".stop"))
            throw new OperationCanceledException("Resolve menu session was stopped.");
    }

    static void Click(AutomationElement item, uint process, string session)
    {
        CheckCancellation(session);
        uint active;
        GetWindowThreadProcessId(GetForegroundWindow(), out active);
        if (active != process) throw new InvalidOperationException("Resolve lost foreground focus.");
        var bounds = item.Current.BoundingRectangle;
        if (bounds.IsEmpty || item.Current.IsOffscreen)
            throw new InvalidOperationException("Resolve menu item is not visible.");
        if (!SetCursorPos((int)(bounds.X + bounds.Width / 2), (int)(bounds.Y + bounds.Height / 2)))
            throw new InvalidOperationException("Cannot access the Resolve menu item.");
        GetWindowThreadProcessId(GetForegroundWindow(), out active);
        if (active != process) throw new InvalidOperationException("Resolve lost foreground focus.");
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }

    static AutomationElement FindPopupItem(AutomationElement window, int process, string command)
    {
        var item = Find(window, command);
        if (item != null && !item.Current.IsOffscreen) return item;
        var roots = AutomationElement.RootElement.FindAll(TreeScope.Children,
            new PropertyCondition(AutomationElement.ProcessIdProperty, process));
        foreach (AutomationElement root in roots)
        {
            item = Find(root, command);
            if (item != null && !item.Current.IsOffscreen) return item;
        }
        return null;
    }

    static void Execute(string action, string session)
    {
        string menu, command;
        if (action == "Deselect")
        {
            menu = "Edit";
            command = "Deselect All";
        }
        else if (action == "Range")
        {
            menu = "Edit";
            command = "Ripple Delete";
        }
        else throw new ArgumentException("Unknown Resolve menu action.");

        DateTime deadline = DateTime.UtcNow.AddSeconds(20);
        IntPtr handle = IntPtr.Zero;
        uint id = 0;
        while (DateTime.UtcNow < deadline)
        {
            CheckCancellation(session);
            handle = GetForegroundWindow();
            GetWindowThreadProcessId(handle, out id);
            if (id != 0)
            {
                using (var process = Process.GetProcessById((int)id))
                {
                    var active = AutomationElement.FromHandle(handle);
                    if (process.ProcessName.Equals("Resolve", StringComparison.OrdinalIgnoreCase)
                        && active.Current.Name.StartsWith("DaVinci Resolve - ", StringComparison.Ordinal))
                        break;
                }
            }
            handle = IntPtr.Zero;
            Thread.Sleep(120);
        }
        if (handle == IntPtr.Zero)
            throw new InvalidOperationException("Return to the main Resolve window to apply cuts.");

        var window = AutomationElement.FromHandle(handle);
        var menuItem = Find(window, menu);
        if (menuItem == null) throw new InvalidOperationException("Resolve menu not found: " + menu);
        Click(menuItem, id, session);
        for (int attempt = 0; attempt < 20; attempt++)
        {
            CheckCancellation(session);
            var item = FindPopupItem(window, (int)id, command);
            if (item == null)
            {
                Thread.Sleep(50);
                continue;
            }
            if (!item.Current.IsEnabled)
            {
                Click(menuItem, id, session);
                if (action == "Deselect") return;
                throw new InvalidOperationException("Resolve menu item is disabled: " + command);
            }
            Click(item, id, session);
            return;
        }
        Click(menuItem, id, session);
        throw new InvalidOperationException("Resolve menu item not found: " + command);
    }

    static void WriteReply(string reply, string result)
    {
        string pending = reply + ".pending";
        File.WriteAllText(pending, result);
        File.Move(pending, reply);
    }

    [STAThread]
    static int Main(string[] args)
    {
        SetProcessDPIAware();
        if (args.Length == 3 && args[0] == "--estado")
        {
            Application.EnableVisualStyles();
            using (var status = new StatusWindow(args[1], int.Parse(args[2])))
                Application.Run(status);
            return 0;
        }
        if (args.Length != 1) return 2;
        string session = args[0];
        string stop = session + ".stop";
        var idle = Stopwatch.StartNew();
        int sequence = 1;
        try
        {
            while (idle.Elapsed < TimeSpan.FromSeconds(45) && !File.Exists(stop))
            {
                string request = session + "-" + sequence + ".request";
                if (!File.Exists(request))
                {
                    Thread.Sleep(15);
                    continue;
                }

                string action = File.ReadAllText(request);
                File.Delete(request);
                string result;
                try { Execute(action, session); result = "OK"; }
                catch (Exception error) { result = error.Message; }
                if (File.Exists(stop)) break;
                WriteReply(session + "-" + sequence + ".reply", result);
                if (result != "OK") return 1;
                sequence++;
                idle.Restart();
            }
            return 0;
        }
        finally
        {
            if (File.Exists(stop)) File.Delete(stop);
        }
    }
}
