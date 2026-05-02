// TrayService.cs
//
// Keeps RAVEN alive in the system tray when the main window is closed,
// so the BLE mesh continues to participate (advertise + relay + bridge)
// while the user is "done" with the GUI.
//
// Implementation: thin wrapper around System.Windows.Forms.NotifyIcon.
// Yes, WinForms — it's the only painless way to get a Windows tray icon
// from a WinUI 3 app without writing custom shell hooks. We don't ship
// any actual WinForms UI; just the notification icon.

#if WINDOWS

using System;
using System.Drawing;
using System.Windows.Forms;
using Microsoft.UI.Xaml;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Ui;

public sealed class TrayService : IDisposable
{
    private readonly Window _mainWindow;
    private readonly BleEngine _ble;
    private NotifyIcon? _notifyIcon;
    private bool _quitRequested;

    public TrayService(Window mainWindow, BleEngine ble)
    {
        _mainWindow = mainWindow;
        _ble = ble;
    }

    public void Install()
    {
        _notifyIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application, // TODO: replace with raven icon resource
            Text = "RAVEN — Mesh active",
            Visible = true,
        };

        var ctx = new ContextMenuStrip();
        var openItem = new ToolStripMenuItem("Open RAVEN");
        openItem.Click += (_, _) => Show();
        ctx.Items.Add(openItem);

        ctx.Items.Add(new ToolStripSeparator());

        var statusItem = new ToolStripMenuItem("Mesh: idle") { Enabled = false };
        ctx.Items.Add(statusItem);

        ctx.Items.Add(new ToolStripSeparator());

        var quitItem = new ToolStripMenuItem("Quit RAVEN");
        quitItem.Click += (_, _) => Quit();
        ctx.Items.Add(quitItem);

        _notifyIcon.ContextMenuStrip = ctx;

        // Live-update the mesh status menu item.
        var refreshTimer = new System.Windows.Forms.Timer { Interval = 5000 };
        refreshTimer.Tick += (_, _) =>
        {
            var n = _ble.Peers.Count;
            statusItem.Text = n switch
            {
                0 => "Mesh: idle (no peers)",
                1 => "Mesh: active · 1 peer",
                _ => $"Mesh: active · {n} peers",
            };
            _notifyIcon.Text = "RAVEN — " + statusItem.Text;
        };
        refreshTimer.Start();

        // Single-click → open.
        _notifyIcon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) Show();
        };

        // Hide-instead-of-close.
        _mainWindow.Closed += OnWindowClosed;
    }

    private void OnWindowClosed(object sender, WindowEventArgs e)
    {
        if (_quitRequested) return;
        // Cancel the close — hide the window instead.
        e.Handled = true;
        _mainWindow.AppWindow.Hide();
    }

    private void Show()
    {
        try
        {
            _mainWindow.AppWindow.Show();
            _mainWindow.Activate();
        }
        catch { /* window disposed */ }
    }

    private void Quit()
    {
        _quitRequested = true;
        try { _mainWindow.Close(); } catch { }
        Application.Current.Exit();
    }

    public void Dispose()
    {
        if (_notifyIcon is not null)
        {
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _notifyIcon = null;
        }
    }
}

#else

using System;
using Microsoft.UI.Xaml;
using RAVEN.Windows.Mesh;

namespace RAVEN.Windows.Ui;

/// <summary>Non-Windows stub — tray support is Windows-only (System.Windows.Forms).</summary>
public sealed class TrayService : IDisposable
{
    public TrayService(Window mainWindow, BleEngine ble) { }
    public void Install() { }
    public void Dispose() { }
}

#endif
