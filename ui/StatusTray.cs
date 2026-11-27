using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace CampusRecovery {
    internal enum TrayTone { Online, Busy, Waiting, Error, Account }

    internal sealed class TrayTheme {
        internal readonly Color Surface, Text, Muted, Border, Soft, Accent, OnAccent;
        internal TrayTheme(TrayTone tone) {
            if (SystemInformation.HighContrast) {
                Surface = SystemColors.Window; Text = Muted = SystemColors.WindowText;
                Border = SystemColors.WindowText; Soft = SystemColors.Window;
                Accent = SystemColors.Highlight; OnAccent = SystemColors.HighlightText;
                return;
            }
            bool dark = false;
            try {
                dark = Convert.ToInt32(Registry.GetValue(
                    @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                    "AppsUseLightTheme", 1)) == 0;
            } catch (System.Security.SecurityException) {} catch (UnauthorizedAccessException) {} catch (IOException) {}
            Surface = Rgb(dark ? 0x202528 : 0xFCFDFC);
            Text = Rgb(dark ? 0xF1F5F3 : 0x192C28);
            Muted = Rgb(dark ? 0xBCC9C5 : 0x50635D);
            Border = Rgb(dark ? 0x465550 : 0xC9D6D0);
            int accent, soft;
            switch (tone) {
                case TrayTone.Error: accent = dark ? 0xFFAA99 : 0xA43D29; soft = dark ? 0x4C302B : 0xFCE8E2; break;
                case TrayTone.Waiting: accent = dark ? 0xEEC17B : 0x815214; soft = dark ? 0x443929 : 0xF8EDD9; break;
                case TrayTone.Busy: accent = dark ? 0x98C8F1 : 0x245D85; soft = dark ? 0x283E50 : 0xE4EFF8; break;
                default: accent = dark ? 0x81D6BB : 0x086B56; soft = dark ? 0x254339 : 0xDFF2E9; break;
            }
            Accent = Rgb(accent); Soft = Rgb(soft);
            OnAccent = dark ? Rgb(0x11251F) : Color.White;
        }
        static Color Rgb(int value) { return Color.FromArgb(255, Color.FromArgb(value)); }
    }

    internal static class TrayArt {
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point point, uint flags);
        [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);

        internal static int Dpi(Rectangle area) {
            var center = new Point(area.Left + area.Width / 2, area.Top + area.Height / 2);
            try {
                uint x, y;
                if (GetDpiForMonitor(MonitorFromPoint(center, 2), 0, out x, out y) == 0 && x > 0) return (int)x;
            } catch (DllNotFoundException) {} catch (EntryPointNotFoundException) {}
            using (var g = Graphics.FromHwnd(IntPtr.Zero)) return (int)Math.Round(g.DpiX);
        }
        internal static GraphicsPath Round(RectangleF rect, float radius) {
            var path = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
            if (d <= 1) { path.AddRectangle(rect); return path; }
            path.AddArc(rect.Left, rect.Top, d, d, 180, 90);
            path.AddArc(rect.Right - d, rect.Top, d, d, 270, 90);
            path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
            path.AddArc(rect.Left, rect.Bottom - d, d, d, 90, 90);
            path.CloseFigure(); return path;
        }
        internal static void Draw(Graphics g, Rectangle box, TrayTone tone, Color background, Color ink) {
            var saved = g.Save();
            try {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TranslateTransform(box.X, box.Y);
                g.ScaleTransform(box.Width / 32f, box.Height / 32f);
                using (var fill = new SolidBrush(background))
                using (var glyph = new SolidBrush(ink))
                using (var line = new Pen(ink, 2.1f))
                using (var tile = Round(new RectangleF(1, 1, 30, 30), 8)) {
                    line.StartCap = line.EndCap = LineCap.Round; line.LineJoin = LineJoin.Round;
                    g.FillPath(fill, tile);
                    switch (tone) {
                        case TrayTone.Online:
                            g.DrawLines(line, new[]{new Point(9,21),new Point(9,16),new Point(23,16),new Point(23,21)});
                            g.DrawLine(line, 16, 11, 16, 16);
                            g.FillRectangle(glyph, 12, 7, 8, 5); g.FillRectangle(glyph, 6, 20, 6, 5); g.FillRectangle(glyph, 20, 20, 6, 5);
                            break;
                        case TrayTone.Busy:
                            g.DrawLines(line, new[]{new Point(8,12),new Point(23,12),new Point(19,8)});
                            g.DrawLines(line, new[]{new Point(24,20),new Point(9,20),new Point(13,24)});
                            break;
                        case TrayTone.Waiting:
                            g.DrawEllipse(line, 8, 8, 16, 16); g.DrawLines(line, new[]{new Point(16,11),new Point(16,16),new Point(20,18)}); break;
                        case TrayTone.Account:
                            g.DrawEllipse(line, 12, 7.5f, 8, 8); g.DrawArc(line, 7, 17, 18, 14, 195, 150); break;
                        case TrayTone.Error:
                            g.DrawLine(line, 16, 8, 16, 18); g.FillEllipse(glyph, 14.4f, 21, 3.2f, 3.2f); break;
                    }
                }
            } finally { g.Restore(saved); }
        }
        internal static Icon IconFor(TrayTone tone, int dpi) {
            var theme = new TrayTheme(tone);
            int px = Math.Max(16, (int)Math.Round(16.0 * dpi / 96));
            using (var bmp = new Bitmap(px, px)) {
                using (var graphics = Graphics.FromImage(bmp)) Draw(graphics, new Rectangle(0,0,px,px), tone, theme.Accent, theme.OnAccent);
                IntPtr handle = bmp.GetHicon();
                try { using (var borrowed = Icon.FromHandle(handle)) return (Icon)borrowed.Clone(); }
                finally { DestroyIcon(handle); }
            }
        }
    }

    internal sealed class TrayButton : Button {
        readonly TrayTheme theme;
        readonly bool primary, close;
        bool hovered;
        internal TrayButton(string text, TrayTheme theme, bool primary, bool close) {
            this.theme = theme; this.primary = primary; this.close = close;
            Text = text; AccessibleName = close ? "关闭" : text; UseMnemonic = false;
            FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; UseVisualStyleBackColor = false;
            Cursor = Cursors.Hand;
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hovered = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hovered = false; Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            float unit = Math.Max(1f, Font.Height / 18f);
            var rect = new RectangleF(1, 1, Width - 2, Height - 2);
            Color fill = primary ? theme.Accent : (hovered ? theme.Soft : theme.Surface);
            Color ink = primary ? theme.OnAccent : (close ? theme.Muted : theme.Text);
            using (var path = TrayArt.Round(rect, 6 * unit))
            using (var brush = new SolidBrush(fill))
            using (var border = new Pen(primary ? theme.Accent : theme.Border, unit)) {
                g.FillPath(brush, path); if (!close && !primary) g.DrawPath(border, path);
            }
            if (close) {
                float cx = Width / 2f, cy = Height / 2f, r = Math.Min(Width,Height) * .145f;
                using (var pen = new Pen(ink, 1.6f * unit)) {
                    pen.StartCap = pen.EndCap = LineCap.Round;
                    g.DrawLine(pen,cx-r,cy-r,cx+r,cy+r); g.DrawLine(pen,cx+r,cy-r,cx-r,cy+r);
                }
            } else {
                var textRect = Rectangle.Inflate(ClientRectangle, -(int)(10*unit), -2);
                var measured = TextRenderer.MeasureText(g,Text,Font,new Size(textRect.Width,Int32.MaxValue),TrayCard.Wrap);
                textRect.Y += Math.Max(0,(textRect.Height - measured.Height)/2);
                TextRenderer.DrawText(g, Text, Font, textRect, ink, TrayCard.Wrap | TextFormatFlags.HorizontalCenter);
            }
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(ClientRectangle,-4,-4),ink,fill);
        }
    }

    internal class TrayCard : Form {
        internal const TextFormatFlags Wrap = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl;
        internal readonly Rectangle WorkArea;
        internal readonly int DisplayDpi;
        internal readonly TrayTheme Theme;
        internal readonly Panel Viewport = new Panel { AutoScroll = true };
        internal readonly Panel Rows = new Panel();
        readonly List<Font> ownedFonts = new List<Font>();
        readonly Label brand, headline;
        readonly TrayButton dismiss;
        readonly PictureBox mark = new PictureBox();
        readonly bool centered, passive;
        readonly float textFactor, rendererDpi;
        protected readonly Font bodyFont;

        internal TrayCard(Rectangle area, int dpi, TrayTone tone, string title, bool centered, bool passive) {
            WorkArea = area; DisplayDpi = dpi; this.centered = centered; this.passive = passive;
            Theme = new TrayTheme(tone); textFactor = ReadTextFactor();
            rendererDpi = TrayArt.Dpi(Screen.PrimaryScreen.WorkingArea);
            AutoScaleMode = AutoScaleMode.None; FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual; TopMost = true; ShowInTaskbar = false;
            Text = "校园网 · " + title; AccessibleName = Text; KeyPreview = true;
            BackColor = Theme.Surface; ForeColor = Theme.Text;
            SetStyle(ControlStyles.ResizeRedraw | ControlStyles.OptimizedDoubleBuffer, true);
            bodyFont = MakeFont(15, FontStyle.Regular); Font = bodyFont;
            brand = LabelFor("校园网", MakeFont(12,FontStyle.Regular), Theme.Muted);
            headline = LabelFor(title, MakeFont(20,FontStyle.Bold), Theme.Text);
            dismiss = new TrayButton("",Theme,false,true);
            dismiss.Click += delegate { Dismiss(); };
            mark.Paint += delegate(object sender, PaintEventArgs e) { TrayArt.Draw(e.Graphics, mark.ClientRectangle,tone,Theme.Soft,Theme.Accent); };
            mark.TabStop = false;
            Controls.AddRange(new Control[]{mark,brand,headline,dismiss,Viewport});
            Viewport.Controls.Add(Rows);
        }
        internal Action OnDismiss;
        internal void Dismiss() { if (OnDismiss == null) Close(); else OnDismiss(); }
        protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
            if (keyData == Keys.Escape) { Dismiss(); return true; }
            return base.ProcessCmdKey(ref msg,keyData);
        }
        protected override bool ShowWithoutActivation { get { return passive; } }
        protected override CreateParams CreateParams {
            get { var cp = base.CreateParams; cp.ExStyle |= 0x80; cp.ClassStyle |= 0x20000; return cp; }
        }
        static float ReadTextFactor() {
            try { return Math.Max(1, Math.Min(2.25f, Convert.ToSingle(Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Accessibility","TextScaleFactor",100)) / 100f)); }
            catch (System.Security.SecurityException) {} catch (UnauthorizedAccessException) {} catch (IOException) {}
            return 1;
        }
        internal int Px(float value) { return (int)Math.Round(value * DisplayDpi / 96.0); }
        Font MakeFont(float pixels, FontStyle style) {
            // WinForms converts the font to a GDI HFONT at the desktop DC's resolution.
            // Convert the intended on-screen height to points exactly once.
            float points = pixels * (DisplayDpi / 96f) * textFactor * 72f / rendererDpi;
            var font = new Font(SystemFonts.MessageBoxFont.FontFamily, points, style, GraphicsUnit.Point);
            ownedFonts.Add(font); return font;
        }
        static Label LabelFor(string text, Font font, Color ink) {
            return new Label { Text = text, Font = font, ForeColor = ink, UseMnemonic = false,
                AutoEllipsis = false, AutoSize = false, UseCompatibleTextRendering = false };
        }
        internal Label AddText(string text, int gap) {
            var label = LabelFor(text,bodyFont,Theme.Muted); AddRow(label,gap); return label;
        }
        protected void AddRow(Control control, int gap) {
            control.Margin = new Padding(0,Px(gap),0,0); control.TabIndex = Rows.Controls.Count;
            Rows.Controls.Add(control);
        }
        int TextHeight(Label label, int width) {
            var size = new Size(Math.Max(1,width),0);
            return Math.Max(label.GetPreferredSize(size).Height,
                TextRenderer.MeasureText(label.Text,label.Font,new Size(size.Width,Int32.MaxValue),Wrap).Height) + Px(2);
        }
        int ArrangeRows(int width) {
            int y = 0;
            foreach (Control row in Rows.Controls) {
                y += row.Margin.Top;
                int h;
                var label = row as Label;
                if (label != null) h = TextHeight(label,width);
                else h = row.Height;
                row.SetBounds(0,y,width,h); y += h;
            }
            Rows.Size = new Size(width,y); return y;
        }
        internal void Fit() {
            int gap = Px(12), pad = Px(18);
            int width = Math.Max(1,Math.Min(Px(366),WorkArea.Width-2*gap));
            int maxHeight = Math.Max(1,WorkArea.Height-2*gap);
            bool compact = width < Px(245);
            if (compact) pad = Px(10);
            int symbol = Px(44), closeSize = Px(28);
            mark.Visible = !compact;
            int x = compact ? pad : pad+symbol+Px(11);
            int textWidth = Math.Max(1,width-x-pad-closeSize-Px(6));
            int brandH = TextHeight(brand,textWidth), titleH = TextHeight(headline,textWidth);
            int header = Math.Max(compact ? 0 : symbol,brandH+titleH);
            mark.SetBounds(pad,pad+(header-symbol)/2,symbol,symbol);
            brand.SetBounds(x,pad,textWidth,brandH);
            headline.SetBounds(x,pad+brandH,textWidth,titleH);
            dismiss.SetBounds(width-pad-closeSize,pad,closeSize,closeSize);
            int divider = pad+header+Px(12);
            int bodyWidth = Math.Max(1,width-2*pad);
            int available = Math.Max(1,maxHeight-divider-pad);
            Point oldScroll = Viewport.AutoScrollPosition;
            Viewport.AutoScrollPosition = Point.Empty;
            int contentH = ArrangeRows(bodyWidth);
            if (contentH > available) {
                int bar = Math.Max(SystemInformation.VerticalScrollBarWidth,Px(17)) + Px(2);
                contentH = ArrangeRows(Math.Max(1,bodyWidth-bar));
            }
            int visibleH = Math.Min(available,contentH);
            ClientSize = new Size(width,Math.Min(maxHeight,divider+visibleH+pad));
            Viewport.SetBounds(pad,divider,bodyWidth,visibleH);
            Viewport.AutoScrollMinSize = new Size(0,contentH);
            Viewport.AutoScrollPosition = new Point(0,Math.Max(0,-oldScroll.Y));
            Location = centered ? new Point(WorkArea.Left+(WorkArea.Width-Width)/2,WorkArea.Top+(WorkArea.Height-Height)/2) :
                new Point(WorkArea.Right-Width-gap,WorkArea.Bottom-Height-gap);
        }
        protected override void OnSizeChanged(EventArgs e) {
            base.OnSizeChanged(e);
            if (DisplayDpi <= 0 || Width < 2 || Height < 2) return;
            using (var shape = TrayArt.Round(new RectangleF(0,0,Width,Height),Px(12))) {
                var old = Region; Region = new Region(shape); if (old != null) old.Dispose();
            }
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = TrayArt.Round(new RectangleF(.5f,.5f,Width-1,Height-1),Px(12)))
            using (var pen = new Pen(Theme.Border,Math.Max(1,Px(1)))) e.Graphics.DrawPath(pen,path);
        }
        protected override void Dispose(bool disposing) {
            base.Dispose(disposing);
            if (disposing) foreach (var f in ownedFonts) f.Dispose();
        }
    }

    public static class StatusTray {
        static readonly AutoResetEvent WakeEvent = new AutoResetEvent(false);
        static readonly ManualResetEvent TrayReady = new ManualResetEvent(false);
        static int pending;
        static Thread ui;
        static void Wake() { Interlocked.Exchange(ref pending,1); WakeEvent.Set(); }
        public static bool TakeWake() { return Interlocked.Exchange(ref pending,0) != 0; }
        public static bool Wait(int ms) { return WakeEvent.WaitOne(ms); }
        public static bool IsSleepGap(DateTime before, DateTime after) { return (after-before).TotalSeconds > 12; }

        public static bool Start(string path) {
            if (ui != null) return TrayReady.WaitOne(0);
            ui = new Thread(delegate() {
                PowerModeChangedEventHandler power = delegate(object s,PowerModeChangedEventArgs e) { if (e.Mode == PowerModes.Resume) Wake(); };
                SessionSwitchEventHandler session = delegate(object s,SessionSwitchEventArgs e) { if (e.Reason == SessionSwitchReason.SessionUnlock) Wake(); };
                try {
                    try { SystemEvents.PowerModeChanged += power; SystemEvents.SessionSwitch += session; } catch (InvalidOperationException) {}
                    using (new LoginScreen.DpiScope())
                    using (var tray = new TrayContext(path)) { TrayReady.Set(); Application.Run(tray); }
                } catch (Exception e) { Trace.WriteLine(e); }
                finally { SystemEvents.PowerModeChanged -= power; SystemEvents.SessionSwitch -= session; }
            });
            ui.Name = "Campus network status"; ui.SetApartmentState(ApartmentState.STA); ui.IsBackground = true; ui.Start();
            return TrayReady.WaitOne(5000);
        }

        internal static TrayTone Describe(string phase, out string title) {
            switch (phase) {
                case "online": title = "已连接"; return TrayTone.Online;
                case "error": title = "连接异常"; return TrayTone.Error;
                case "away": title = "等待接入校园网"; return TrayTone.Waiting;
                case "adapter": title = "等待网卡就绪"; return TrayTone.Waiting;
                case "account": title = "等待确认账号"; return TrayTone.Account;
                case "auth": case "ready": title = "正在认证"; break;
                case "loading": case "client": title = "正在打开天翼"; break;
                case "wake": title = "正在恢复连接"; break;
                case "restore": case "proxy-off": title = "正在调整代理"; break;
                default: title = "正在检查连接"; break;
            }
            return TrayTone.Busy;
        }
        internal static TrayCard MakeStatus(string phase, string detail, Rectangle area, int dpi) {
            string title; var tone = Describe(phase,out title);
            var card = new TrayCard(area,dpi,tone,title,false,true);
            card.AddText(detail,0); card.Fit(); return card;
        }

        internal static ContextMenuStrip MakeSettingsMenu(Action<bool> open) {
            var menu = new ContextMenuStrip { ShowImageMargin = false };
            menu.Items.Add("添加账号…",null,delegate { open(true); }).Name = "AddAccount";
            menu.Items.Add("账号与设置…",null,delegate { open(false); }).Name = "Settings";
            return menu;
        }
        internal static ProcessStartInfo SettingsStartInfo(string statusFile, bool add) {
            string root = Path.GetDirectoryName(Path.GetFullPath(statusFile));
            string script = Path.Combine(root,@"tools\settings.ps1");
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            return new ProcessStartInfo(ps,"-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \""+script+"\""+(add ? " -AddAccount" : "")) {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = root
            };
        }

        sealed class TrayContext : ApplicationContext {
            readonly string path;
            readonly NotifyIcon icon = new NotifyIcon();
            readonly ContextMenuStrip menu;
            readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
            Icon image;
            TrayCard panel;
            string phase = "check", detail = "正在检查校园网连接。";
            string snapshot;
            bool pinned;
            DateTime hideAt;
            internal TrayContext(string file) {
                path = file;
                menu = MakeSettingsMenu(OpenSettings);
                menu.Opening += delegate { HidePanel(); };
                icon.ContextMenuStrip = menu;
                UpdateIcon(); icon.Visible = true;
                icon.MouseClick += delegate(object sender, MouseEventArgs e) {
                    if (e.Button != MouseButtons.Left) return;
                    if (pinned && panel != null && panel.Visible) { HidePanel(); return; }
                    pinned = true;
                    Open(Screen.FromPoint(Cursor.Position).WorkingArea,true);
                };
                timer.Interval = 450; timer.Tick += delegate { Poll(); }; timer.Start();
            }
            void OpenSettings(bool add) {
                try {
                    var command = SettingsStartInfo(path,add);
                    if (!File.Exists(Path.Combine(command.WorkingDirectory,@"tools\settings.ps1")))
                        throw new FileNotFoundException();
                    using (var process = Process.Start(command)) { }
                } catch (Exception error) {
                    Trace.WriteLine(error);
                    MessageBox.Show("无法打开设置，请使用完整安装包中的「校园网设置.cmd」，或重新安装校园网工具。",
                        "校园网设置",MessageBoxButtons.OK,MessageBoxIcon.Warning);
                }
            }
            void UpdateIcon() {
                string title; var tone = Describe(phase,out title);
                var next = TrayArt.IconFor(tone,TrayArt.Dpi(Screen.PrimaryScreen.WorkingArea));
                var old = image; image = next; icon.Icon = next; if (old != null) old.Dispose();
                icon.Text = "校园网 · " + title;
            }
            void HidePanel() { pinned = false; if (panel != null) panel.Hide(); }
            void Open(Rectangle area, bool activate) {
                int dpi = TrayArt.Dpi(area);
                if (panel == null || panel.WorkArea != area || panel.DisplayDpi != dpi) {
                    if (panel != null) panel.Dispose();
                    panel = MakeStatus(phase,detail,area,dpi); panel.OnDismiss = HidePanel;
                }
                hideAt = DateTime.UtcNow.AddSeconds(Math.Max(5,Math.Min(18,3+detail.Length/8)));
                if (!panel.Visible) panel.Show();
                if (activate) panel.Activate();
            }
            internal void Poll() {
                try {
                    string body = File.ReadAllText(path,Encoding.UTF8);
                    int split = body.IndexOf('\n');
                    if (split >= 0 && body != snapshot) {
                        string nextPhase = body.Substring(0,split).Trim();
                        detail = body.Substring(split+1).TrimEnd('\r','\n');
                        if (nextPhase != phase) { phase = nextPhase; UpdateIcon(); }
                        snapshot = body;
                        var area = pinned && panel != null ? panel.WorkArea : Screen.PrimaryScreen.WorkingArea;
                        if (panel != null) { panel.Dispose(); panel = null; }
                        Open(area,false);
                    } else if (pinned && panel != null && !panel.Visible) { Open(panel.WorkArea,false); }
                } catch (IOException) {} catch (UnauthorizedAccessException) {}
                if (!pinned && panel != null && panel.Visible && DateTime.UtcNow >= hideAt &&
                    !panel.Bounds.Contains(Cursor.Position)) panel.Hide();
            }
            protected override void Dispose(bool disposing) {
                if (disposing) {
                    timer.Dispose(); icon.Visible = false; icon.Dispose(); menu.Dispose(); if (image != null) image.Dispose();
                    if (panel != null) panel.Dispose();
                }
                base.Dispose(disposing);
            }
        }
    }
}
