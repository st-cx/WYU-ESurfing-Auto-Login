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

    internal sealed class TrayField : Panel {
        internal readonly TextBox Edit;
        readonly TrayTheme theme;
        readonly int inset;
        internal TrayField(TrayTheme theme, Font nativeFont, int inset, string name, bool password) {
            this.theme = theme; this.inset = inset; BackColor = theme.Surface;
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw,true);
            Edit = new TextBox { Font=nativeFont, BorderStyle=BorderStyle.None, MaxLength=password ? 160 : 16,
                UseSystemPasswordChar=password, AccessibleName=name, BackColor=theme.Surface, ForeColor=theme.Text };
            Edit.GotFocus += delegate { Invalidate(); }; Edit.LostFocus += delegate { Invalidate(); };
            Controls.Add(Edit);
        }
        protected override void OnSizeChanged(EventArgs e) {
            base.OnSizeChanged(e);
            if (Edit != null) {
                int h = Edit.PreferredHeight;
                Edit.SetBounds(inset,Math.Max(0,(Height-h)/2),Math.Max(1,Width-2*inset),h);
            }
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var border = new Pen(Edit.Focused ? theme.Accent : theme.Border,Edit.Focused ? 2 : 1))
            using (var shape = TrayArt.Round(new RectangleF(1,1,Width-2,Height-2),inset/2f)) e.Graphics.DrawPath(border,shape);
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
        protected TextBox AddInput(string name, bool password) {
            // The native single-line EDIT uses its HFONT directly, unlike the GDI-drawn labels.
            var font = new Font(bodyFont.FontFamily,15f*DisplayDpi/96f*textFactor,FontStyle.Regular,GraphicsUnit.Pixel);
            ownedFonts.Add(font);
            var field = new TrayField(Theme,font,Px(10),name,password);
            AddRow(field,4); return field.Edit;
        }
        static Label LabelFor(string text, Font font, Color ink) {
            return new Label { Text = text, Font = font, ForeColor = ink, UseMnemonic = false,
                AutoEllipsis = false, AutoSize = false, UseCompatibleTextRendering = false };
        }
        internal Label AddText(string text, int gap) {
            var label = LabelFor(text,bodyFont,Theme.Muted); AddRow(label,gap); return label;
        }
        internal TrayButton AddAction(string text, bool primary, int gap) {
            var button = new TrayButton(text,Theme,primary,false) { Font = bodyFont };
            AddRow(button,gap); return button;
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
                else if (row is Button) {
                    int inset = Math.Max(Px(12), row.Font.Height);
                    int text = TextRenderer.MeasureText(row.Text,row.Font,new Size(Math.Max(1,width-2*inset),Int32.MaxValue),Wrap).Height;
                    h = Math.Max(Px(37),text + Px(12));
                } else if (row is TrayField) {
                    h = Math.Max(Px(37),((TrayField)row).Edit.PreferredHeight+Px(10));
                }
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

    internal sealed class AccountCard : TrayCard {
        readonly string primary;
        readonly Label countdown;
        readonly Panel progress = new Panel();
        readonly Stopwatch elapsed = new Stopwatch();
        readonly System.Windows.Forms.Timer tick = new System.Windows.Forms.Timer();
        int remaining = -1;
        internal string Selected { get; private set; }
        internal AccountCard(Rectangle area, int dpi, string primary, string[] others)
            : base(area,dpi,TrayTone.Account,"选择登录账号",false,false) {
            this.primary = Selected = primary;
            countdown = AddText("10 秒后自动使用默认账号",0);
            progress.Height = Math.Max(2,Px(3)); AddRow(progress,7);
            progress.Paint += delegate(object sender, PaintEventArgs e) {
                e.Graphics.Clear(Theme.Soft);
                using (var brush = new SolidBrush(Theme.Accent)) {
                    double fraction = Math.Max(0,1-elapsed.Elapsed.TotalSeconds/10);
                    e.Graphics.FillRectangle(brush,0,0,(int)Math.Ceiling(progress.Width*fraction),progress.Height);
                }
            };
            var usePrimary = AddAction("使用默认账号  " + primary,true,13);
            usePrimary.Click += delegate { Close(); }; AcceptButton = usePrimary;
            if (others != null && others.Length > 0) {
                foreach (string id in others) {
                    string choice = id;
                    var useAlternate = AddAction("备用账号  " + choice,false,7);
                    useAlternate.Click += delegate { Pick(choice); };
                }
            } else {
                var add = AddAction("使用其他账号…",false,7);
                add.Click += delegate { Pick("@add"); };
            }
            tick.Interval = 120;
            tick.Tick += delegate {
                int left = Math.Max(0,10-(int)elapsed.Elapsed.TotalSeconds);
                if (remaining != left) { countdown.Text = left + " 秒后自动使用默认账号"; remaining = left; }
                progress.Invalidate();
                if (elapsed.ElapsedMilliseconds >= 10000) Close();
            };
            Shown += delegate { elapsed.Start(); tick.Start(); };
            Fit();
        }
        void Pick(string choice) {
            Selected = StatusTray.SelectBeforeTimeout(primary,choice,elapsed.IsRunning ? elapsed.ElapsedMilliseconds : -1);
            Close();
        }
        protected override void Dispose(bool disposing) {
            if (disposing) tick.Dispose(); base.Dispose(disposing);
        }
    }

    internal sealed class AlternateCard : TrayCard {
        readonly TextBox userBox, passwordBox;
        readonly Label hint;
        readonly System.Windows.Forms.Timer timeout = new System.Windows.Forms.Timer();
        internal StatusTray.SavedInput Result { get; private set; }
        internal AlternateCard(Rectangle area, int dpi, string primary)
            : base(area,dpi,TrayTone.Account,"使用备用账号",true,false) {
            AddText("校园账号",0);
            userBox = AddInput("校园账号",false); AddText("密码",10);
            passwordBox = AddInput("密码",true);
            hint = AddText("密码由当前 Windows 账号加密保存在本机。",10);
            var save = AddAction("保存并在本次使用",true,12);
            var cancel = AddAction("用默认账号",false,7);
            save.Click += delegate {
                string id = userBox.Text.Trim();
                bool valid = id.Length >= 6 && id.Length <= 16 && id != primary;
                foreach (char c in id) if (c < '0' || c > '9') valid = false;
                if (!valid || passwordBox.TextLength == 0) {
                    hint.Text = "请输入另一个校园账号和对应的密码。";
                    hint.ForeColor = new TrayTheme(TrayTone.Error).Accent; Fit(); return;
                }
                var secret = new System.Security.SecureString();
                foreach (char c in passwordBox.Text) secret.AppendChar(c);
                secret.MakeReadOnly(); Result = new StatusTray.SavedInput { User = id, Password = secret };
                passwordBox.Clear(); Close();
            };
            cancel.Click += delegate { Close(); }; AcceptButton = save; CancelButton = cancel;
            timeout.Interval = 60000; timeout.Tick += delegate { Close(); };
            Shown += delegate { userBox.Focus(); timeout.Start(); }; Fit();
        }
        protected override void Dispose(bool disposing) {
            if (disposing) { timeout.Dispose(); if (!passwordBox.IsDisposed) passwordBox.Clear(); }
            base.Dispose(disposing);
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

        public sealed class SavedInput {
            public string User;
            public System.Security.SecureString Password;
        }
        public static SavedInput EnterAlternate(string primary) {
            using (new LoginScreen.DpiScope()) {
                var area = Screen.FromPoint(Cursor.Position).WorkingArea;
                using (var form = new AlternateCard(area,TrayArt.Dpi(area),primary)) { form.ShowDialog(); return form.Result; }
            }
        }
        public static string SelectBeforeTimeout(string primary, string candidate, long elapsedMs) {
            return !String.IsNullOrEmpty(candidate) && elapsedMs >= 0 && elapsedMs < 10000 ? candidate : primary;
        }
        public static string ChooseAccount(string primary, string[] alternate) {
            if (String.IsNullOrEmpty(primary) || !Environment.UserInteractive) return primary;
            string selected = primary; Form visible = null; int expired = 0; long shownAt = 0;
            var startup = Stopwatch.StartNew();
            var thread = new Thread(delegate() {
                try {
                    using (new LoginScreen.DpiScope()) {
                        var area = Screen.PrimaryScreen.WorkingArea;
                        using (var form = new AccountCard(area,TrayArt.Dpi(area),primary,alternate)) {
                            visible = form;
                            form.Shown += delegate {
                                if (Interlocked.CompareExchange(ref expired,0,0) != 0) { form.Close(); return; }
                                Interlocked.Exchange(ref shownAt,Stopwatch.GetTimestamp());
                            };
                            form.ShowDialog(); selected = form.Selected;
                        }
                    }
                } catch (Exception e) { Trace.WriteLine(e); }
            });
            thread.IsBackground = true; thread.SetApartmentState(ApartmentState.STA); thread.Start();
            while (!thread.Join(100)) {
                long started = Interlocked.Read(ref shownAt);
                bool late = started == 0 ? startup.ElapsedMilliseconds > 3500 :
                    (Stopwatch.GetTimestamp()-started) / (double)Stopwatch.Frequency > 11.5;
                if (late) {
                    Interlocked.Exchange(ref expired,1);
                    try { if (visible != null && visible.IsHandleCreated) visible.BeginInvoke(new Action(visible.Close)); }
                    catch (InvalidOperationException) {} return primary;
                }
            }
            return selected;
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

        sealed class TrayContext : ApplicationContext {
            readonly string path, prompt;
            readonly NotifyIcon icon = new NotifyIcon();
            readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
            Icon image;
            TrayCard panel;
            string phase = "check", detail = "正在检查校园网连接。";
            string snapshot;
            bool pinned;
            DateTime hideAt;
            internal TrayContext(string file) {
                path = file; prompt = Path.Combine(Path.GetDirectoryName(path),"account-prompt-open.txt");
                UpdateIcon(); icon.Visible = true;
                icon.MouseClick += delegate {
                    if (pinned && panel != null && panel.Visible) { HidePanel(); return; }
                    pinned = true;
                    Open(Screen.FromPoint(Cursor.Position).WorkingArea,true);
                };
                timer.Interval = 450; timer.Tick += delegate { Poll(); }; timer.Start();
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
                    if (File.Exists(prompt) && (DateTime.UtcNow-File.GetLastWriteTimeUtc(prompt)).TotalSeconds < 14) {
                        if (panel != null && panel.Visible) panel.Hide(); return;
                    }
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
                    timer.Dispose(); icon.Visible = false; icon.Dispose(); if (image != null) image.Dispose();
                    if (panel != null) panel.Dispose();
                }
                base.Dispose(disposing);
            }
        }
    }
}
