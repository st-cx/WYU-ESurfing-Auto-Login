using System;
using System.Drawing;
using System.Collections.Generic;
using System.Drawing.Text;
using System.Text;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Threading;

namespace CampusRecovery {
    public static class LoginScreen {
        [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref Point p);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int mode);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flag);
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point p);
        [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr dc, IntPtr flags, uint mode, uint ms, out UIntPtr result);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out Point p);
        [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);


        delegate bool EnumProc(IntPtr window, IntPtr state);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc fn, IntPtr state);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc fn, IntPtr state);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder buf,int count);
        [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent,IntPtr child);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);

        public static string LastRead { get; private set; }
        static bool PageClass(IntPtr h) {
            var name=new StringBuilder(100); GetClassName(h,name,name.Capacity);
            return name.ToString().Equals("wkeWebWindow",StringComparison.OrdinalIgnoreCase);
        }
        public static IntPtr[] Windows(int[] processIds) {
            var allowed=new List<int>(processIds);
            var found=new List<IntPtr>();
            EnumProc visit=delegate(IntPtr h,IntPtr unused) {
                int owner; GetWindowThreadProcessId(h,out owner);
                Rect r;
                if(allowed.Contains(owner) && PageClass(h) && GetClientRect(h,out r) &&
                    ((r.Right>=230 && r.Bottom>=280) || IsIconic(h))) found.Add(h);
                return true;
            };
            EnumWindows(delegate(IntPtr root,IntPtr state) {
                int pid; GetWindowThreadProcessId(root,out pid);
                if(allowed.Contains(pid)) {visit(root,state); EnumChildWindows(root,visit,state);}
                return true;
            },IntPtr.Zero);
            found.Sort(delegate(IntPtr a,IntPtr b){return IsWindowVisible(b).CompareTo(IsWindowVisible(a));});
            return found.ToArray();
        }
        public static void Reveal(IntPtr h) {
            IntPtr root=GetAncestor(h,2);
            if(root==IntPtr.Zero || !IsWindowEnabled(root)) return;
            ShowWindowAsync(root,IsIconic(root)?9:4);
            SetWindowPos(root,IntPtr.Zero,0,0,0,0,0x43);
            SetForegroundWindow(root);
        }
        public static void Minimize(IntPtr h) {
            if(!Usable(h)) return;
            IntPtr root=GetAncestor(h,2);
            int pageOwner,rootOwner;
            GetWindowThreadProcessId(h,out pageOwner);
            GetWindowThreadProcessId(root,out rootOwner);
            if(pageOwner!=0 && pageOwner==rootOwner) ShowWindowAsync(root,7);
        }

        internal sealed class DpiScope : IDisposable {
            readonly IntPtr previous;
            public DpiScope(){previous=SetThreadDpiAwarenessContext((IntPtr)(-4));}
            public void Dispose(){if(previous!=IntPtr.Zero)SetThreadDpiAwarenessContext(previous);}
        }
        static bool Usable(IntPtr h) {
            if (h == IntPtr.Zero || !IsWindowEnabled(h) || !PageClass(h)) return false;
            IntPtr root=GetAncestor(h,2);
            return root!=IntPtr.Zero && IsWindowEnabled(root);
        }
        static bool Green(Color p) { return p.G > 65 && p.G - Math.Max(p.R, p.B) > 38; }
        static Rectangle SearchArea(Size s, double x, double y) {
            int w = (int)Math.Round(152 * s.Width / 533.0), h = (int)Math.Round(50 * s.Height / 914.0);
            return Rectangle.Intersect(new Rectangle(Point.Empty, s), new Rectangle(
                (int)(s.Width*x)-w/2,(int)(s.Height*y)-h/2,w,h));
        }
        // Only match the two rendered glyphs. The spinner and disconnect button share their background.
        static Point MatchNarrow(Bitmap frame, Bitmap glyph, double x, double y) {
            Rectangle area = SearchArea(frame.Size, x, y);
            if (area.Width < 30 || area.Height < 12) return Point.Empty;
            using (Bitmap crop = new Bitmap(152,50)) {
                using (Graphics g = Graphics.FromImage(crop)) {
                    g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                    g.DrawImage(frame,new Rectangle(0,0,152,50),area,GraphicsUnit.Pixel);
                }
                int left=152,right=-1,top=50,bottom=-1;
                for(int j=0;j<50;j++) for(int i=0;i<152;i++) if(Green(crop.GetPixel(i,j))) {
                    left=Math.Min(left,i);right=Math.Max(right,i);top=Math.Min(top,j);bottom=Math.Max(bottom,j);
                }
                int w=right-left+1,h=bottom-top+1;
                if(w < 40 || w > 71 || h < 15 || h > 31) return Point.Empty;
                int expected=0,observed=0,overlap=0;
                for(int j=0;j<glyph.Height;j++) for(int i=0;i<glyph.Width;i++) {
                    bool a=glyph.GetPixel(i,j).R>127;
                    bool b=Green(crop.GetPixel(left+(int)((i+.5)*w/glyph.Width), top+(int)((j+.5)*h/glyph.Height)));
                    if(a) expected++; if(b) observed++; if(a && b) overlap++;
                }
                if(2.0*overlap/(expected+observed)<.76) return Point.Empty;
                return new Point(area.X+(left+right+1)*area.Width/304, area.Y+(top+bottom+1)*area.Height/100);
            }
        }

        static List<Rectangle> Runs(Bitmap b,Rectangle area,Func<Color,bool> ink,int maxGap) {
            var spans=new List<Rectangle>(); int l=-1,last=-1,top=0,bottom=0;
            for(int x=area.Left;x<=area.Right+maxGap;x++) {
                int t=area.Bottom,d=-1;
                if(x<area.Right) for(int y=area.Top;y<area.Bottom;y++) if(ink(b.GetPixel(x,y))){t=Math.Min(t,y);d=y;}
                if(d>=0) {if(l<0){l=x; top=t;bottom=d;} top=Math.Min(top,t);bottom=Math.Max(bottom,d);last=x;}
                else if(l>=0 && x-last>maxGap) {spans.Add(Rectangle.FromLTRB(l,top,last+1,bottom+1));l=-1;}
            }
            return spans;
        }
        static Bitmap Normalized(Bitmap frame) {
            var result=new Bitmap(533,914);
            using(var g=Graphics.FromImage(result)) {
                g.InterpolationMode=InterpolationMode.HighQualityBilinear;
                g.DrawImage(frame,new Rectangle(0,0,533,914),0,0,frame.Width,frame.Height,GraphicsUnit.Pixel);
            }
            return result;
        }
        static double ScoreGlyph(Bitmap norm,Rectangle r,Bitmap glyph) {
            int a=0,b=0,both=0;
            for(int y=0;y<glyph.Height;y++) for(int x=0;x<glyph.Width;x++) {
                bool expect=glyph.GetPixel(x,y).R>127;
                bool actual=Green(norm.GetPixel(r.Left+(2*x+1)*r.Width/(2*glyph.Width),r.Top+(2*y+1)*r.Height/(2*glyph.Height)));
                if(expect)a++; if(actual)b++; if(expect && actual)both++;
            }
            return 2.0*both/Math.Max(1,a+b);
        }
        public static Point Match(Bitmap frame, Bitmap glyph, double x, double y) {
            Point quick=MatchNarrow(frame,glyph,x,y); if(!quick.IsEmpty)return quick;
            using(var norm=Normalized(frame)) {
                const int l=100,r=433; int top=-1,prev=-1;
                for(int row=270;row<=730;row++) {
                    int ink=0;
                    if(row<728) for(int col=l;col<r;col+=2) if(Green(norm.GetPixel(col,row)))ink++;
                    if(ink>=2 && ink<=55) {if(top<0)top=row;prev=row;}
                    else if(top>=0 && row-prev>=3) {
                        int hh=prev-top+1;
                        if(hh>=12 && hh<=37) foreach(var box in Runs(norm,new Rectangle(l,top,r-l,hh),Green,12)) {
                            if(box.Width<31 || box.Width>85 || box.Height<12 || box.Width/(double)box.Height<1.65 || box.Width/(double)box.Height>3.4)continue;
                            if(ScoreGlyph(norm,box,glyph)>=.77)
                                return new Point((box.X+box.Width/2)*frame.Width/533,(box.Y+box.Height/2)*frame.Height/914);
                        }
                        top=-1;
                    }
                }
            }
            return Point.Empty;
        }
        static bool OwnedPoint(IntPtr h, Point origin,int x,int y) {
            IntPtr at=WindowFromPoint(new Point(origin.X+x,origin.Y+y));
            return at==h || (at!=IntPtr.Zero && IsChild(h,at));
        }
        static int printBusy;
        // A misbehaving client can block PrintWindow. Bound the wait and keep at most one native call outstanding.
        static Bitmap FullPrint(IntPtr h,Size size) {
            if(Interlocked.CompareExchange(ref printBusy,1,0)!=0)return null;
            var gate=new object(); bool done=false,expired=false; Bitmap output=null;
            ThreadPool.QueueUserWorkItem(delegate {
                Bitmap img=null; IntPtr old=IntPtr.Zero;
                try {
                    old=SetThreadDpiAwarenessContext((IntPtr)(-4));
                    img=new Bitmap(size.Width,size.Height,System.Drawing.Imaging.PixelFormat.Format32bppRgb);
                    using(var g=Graphics.FromImage(img)) {
                        IntPtr dc=g.GetHdc(); bool ok;
                        try {ok=PrintWindow(h,dc,3);} finally {g.ReleaseHdc(dc);}
                        if(!ok){img.Dispose();img=null;}
                    }
                } catch(Exception) {if(img!=null)img.Dispose();img=null;}
                finally {
                    if(old!=IntPtr.Zero)SetThreadDpiAwarenessContext(old);
                    lock(gate) {if(expired){if(img!=null)img.Dispose();}else output=img;done=true;Monitor.PulseAll(gate);}
                    Interlocked.Exchange(ref printBusy,0);
                }
            });
            lock(gate) {if(!done)Monitor.Wait(gate,550);if(!done){expired=true;return null;}return output;}
        }
        static Bitmap PrintClient(IntPtr h, Size size) {
            var img=new Bitmap(size.Width,size.Height,System.Drawing.Imaging.PixelFormat.Format32bppRgb);
            try {
                using(var g=Graphics.FromImage(img)) {
                    UIntPtr unused;
                    IntPtr dc=g.GetHdc();
                    try {SendMessageTimeout(h,0x318,dc,(IntPtr)30,2,250,out unused);}
                    finally {g.ReleaseHdc(dc);}
                }
                return img;
            } catch {img.Dispose();throw;}
        }
        static bool HasPaintedContent(Bitmap image) {
            if(image==null) return false;
            int first=image.GetPixel(0,0).ToArgb();
            for(int y=0;y<image.Height;y+=8)
                for(int x=0;x<image.Width;x+=8)
                    if(image.GetPixel(x,y).ToArgb()!=first) return true;
            return false;
        }
        // Only the client's own painting is suitable for local diagnostic files.
        public static Bitmap DiagnosticFrame(IntPtr h) {
            using(var dpi=new DpiScope()) {
                Rect r;
                if(!Usable(h) || !GetClientRect(h,out r) || r.Right<230 || r.Bottom<280 || r.Right>4096 || r.Bottom>4096) return null;
                var size=new Size(r.Right,r.Bottom);
                Bitmap frame=FullPrint(h,size);
                if(HasPaintedContent(frame)) return frame;
                if(frame!=null) frame.Dispose();
                frame=PrintClient(h,size);
                if(HasPaintedContent(frame)) return frame;
                frame.Dispose();
                return null;
            }
        }
        static Bitmap Capture(IntPtr h, Bitmap glyph,double x,double y,out Point p) {
            p=Point.Empty; LastRead="window";
            if(!Usable(h))return null;
            IntPtr root=GetAncestor(h,2);
            if(IsIconic(root) || !IsWindowVisible(root)){ShowWindowAsync(root,IsIconic(root)?9:4);LastRead="hidden";return null;}
            Rect r; if(!GetClientRect(h,out r) || r.Right<230 || r.Bottom<280 || r.Right>4096 || r.Bottom>4096)return null;
            var size=new Size(r.Right,r.Bottom);

            Point origin=Point.Empty; bool visible=false;
            if(ClientToScreen(h,ref origin)) {
                visible=OwnedPoint(h,origin,r.Right/2,r.Bottom*58/100);
                if(visible) {
                    var desktop=new Bitmap(r.Right,r.Bottom); bool keep=false;
                    try {
                        using(var g=Graphics.FromImage(desktop)){g.CopyFromScreen(origin,Point.Empty,size);}
                        p=Match(desktop,glyph,x,y);
                        if(!p.IsEmpty && OwnedPoint(h,origin,p.X,p.Y) && OwnedPoint(h,origin,p.X-10,p.Y) && OwnedPoint(h,origin,p.X+10,p.Y)){
                            keep=true;LastRead="screen";return desktop;
                        }
                    } catch(System.ComponentModel.Win32Exception){} finally{if(!keep)desktop.Dispose();}
                }
            }
            Bitmap img=FullPrint(h,size);
            if(img!=null){p=Match(img,glyph,x,y);if(!p.IsEmpty){LastRead="render";return img;}img.Dispose();}
            img=PrintClient(h,size);
            p=Match(img,glyph,x,y);if(!p.IsEmpty){LastRead="client";return img;}
            LastRead=visible?"no-glyph":"covered";
            img.Dispose();p=Point.Empty;return null;
        }
        public static Point Read(IntPtr h, Bitmap glyph,double x,double y) {
            using(var dpi=new DpiScope()) {Point p;using(var frame=Capture(h,glyph,x,y,out p)){return p;}}
        }

        static readonly Dictionary<char,List<int[]>> Patterns=new Dictionary<char,List<int[]>>();
        static bool Dark(Color c) {return Math.Max(c.R,Math.Max(c.G,c.B))<170;}
        static void AddPattern(char digit,int[] mask) {
            List<int[]> ids; if(!Patterns.TryGetValue(digit,out ids)){ids=new List<int[]>();Patterns.Add(digit,ids);} ids.Add(mask);
        }
        static int[] DigitMask(Bitmap b,Rectangle r,Func<Color,bool> ink) {
            var rows=new int[16];
            for(int y=0;y<16;y++)for(int x=0;x<10;x++)
                if(ink(b.GetPixel(r.X+(2*x+1)*r.Width/20,r.Y+(2*y+1)*r.Height/32)))rows[y]|=1<<x;
            return rows;
        }
        static LoginScreen() {
            AddPattern('0', new int[]{112,252,462,390,903,771,771,771,771,771,771,903,390,454,252,120});
            AddPattern('0', new int[]{120,252,462,390,387,899,899,771,771,899,899,387,391,454,254,124});
            AddPattern('1', new int[]{768,992,1020,927,896,896,896,896,896,896,896,896,896,896,896,896});
            AddPattern('2', new int[]{56,254,454,384,384,384,384,192,96,24,28,14,6,3,511,1023});
            AddPattern('3', new int[]{124,255,448,384,384,384,192,112,224,384,896,896,384,384,247,127});
            AddPattern('4', new int[]{64,192,224,240,240,216,220,204,198,195,1023,1023,192,192,192,192});
            AddPattern('4', new int[]{128,192,224,224,176,176,152,140,132,130,1023,1023,128,128,128,128});
            AddPattern('5', new int[]{510,510,6,6,6,6,6,126,448,896,768,768,896,384,503,127});
            AddPattern('7', new int[]{1023,1023,384,384,192,192,96,96,32,48,16,16,24,24,24,24});
            AddPattern('9', new int[]{112,252,462,390,775,775,775,902,1020,824,768,384,384,448,238,62});
            foreach(string family in new[]{"Segoe UI","Microsoft YaHei UI","Arial","Tahoma"}) {
                using(var font=new Font(family,23,FontStyle.Regular,GraphicsUnit.Pixel))
                foreach(char c in "0123456789")using(var img=new Bitmap(48,45)) {
                    using(var g=Graphics.FromImage(img)){g.Clear(Color.White);g.TextRenderingHint=TextRenderingHint.AntiAliasGridFit;g.DrawString(c.ToString(),font,Brushes.Black,1,1,StringFormat.GenericTypographic);}
                    var span=Runs(img,new Rectangle(0,0,48,45),Dark,1);
                    if(span.Count==1)AddPattern(c,DigitMask(img,span[0],Dark));
                }
            }
        }
        static int Bits(int n) {int v=0;while(n!=0){n&=n-1;v++;}return v;}
        static double Dice(int[] a,int[] b) {
            int both=0,total=0;for(int i=0;i<a.Length;i++){both+=Bits(a[i]&b[i]);total+=Bits(a[i])+Bits(b[i]);}return 2.0*both/Math.Max(1,total);
        }
        public static bool MatchesNumber(Bitmap norm,Point button,string user) {
            return !String.IsNullOrEmpty(user) && HasAccountNumber(norm,button,user);
        }
        static bool HasAccountNumber(Bitmap norm,Point button,string user) {
            if(user!=null)foreach(char c in user)if(c<'0'||c>'9')return false;
            var region=Rectangle.Intersect(new Rectangle(0,0,norm.Width,norm.Height),new Rectangle(button.X-176,button.Y-234,327,46));
            if(region.Width<120||region.Height<24)return false;
            foreach(int level in new[]{170,142,156,125}) {
                int threshold=level;Func<Color,bool> ink=c=>Math.Max(c.R,Math.Max(c.G,c.B))<threshold;
                var spans=Runs(norm,region,ink,0).FindAll(v=>v.Width>=3 && v.Width<=23 && v.Height>=12 && v.Height<=36);
                bool lengthOk=String.IsNullOrEmpty(user)?spans.Count>=6 && spans.Count<=16:spans.Count==user.Length;
                if(lengthOk && MatchDigits(norm,user,spans,ink))return true;
            }
            return false;
        }
        static bool MatchDigits(Bitmap norm,string user,List<Rectangle> spans,Func<Color,bool> ink) {
            for(int i=0;i<spans.Count;i++) {
                int[] bits=DigitMask(norm,spans[i],ink); double expected=0,other=0;
                bool remembered=String.IsNullOrEmpty(user);
                foreach(var entry in Patterns)foreach(var mask in entry.Value){double s=Dice(bits,mask);if(remembered || entry.Key==user[i])expected=Math.Max(expected,s);else other=Math.Max(other,s);}
                if(remembered){if(expected<.77)return false;continue;}
                if(other>expected-.012 || (expected<.77 && (expected<.69 || expected-other<.12)))return false;
            }
            return true;
        }
        static int MaskCount(Bitmap norm,Point b) {
            var region=Rectangle.Intersect(new Rectangle(0,0,norm.Width,norm.Height),new Rectangle(b.X-176,b.Y-167,285,33));
            if(region.Width<=100)return 0;
            int count=0,centerY=0,previousX=0;
            foreach(Rectangle mark in Runs(norm,region,Dark,0)) {
                if(mark.Width<3 || mark.Height<3)continue; // A caret or an input border.
                if(mark.Width>14 || mark.Height>14 || mark.Width*2<mark.Height || mark.Height*2<mark.Width)return 0;
                int cx=mark.X+mark.Width/2,cy=mark.Y+mark.Height/2;
                if((count==0 && mark.X-region.X>65) || (count>0 && (Math.Abs(cy-centerY)>3 || cx-previousX>24)))return 0;
                if(!Dark(norm.GetPixel(cx,cy)) && !Dark(norm.GetPixel(cx-1,cy)))return 0;
                count++;centerY=cy;previousX=cx;
            }
            return count;
        }
        public static bool FormReady(Bitmap norm,Point button,string user) {
            return HasAccountNumber(norm,button,user) && MaskCount(norm,button)>0;
        }
        static bool FieldOwner(IntPtr h,Bitmap frame,Point p,int offset) {
            Point o=Point.Empty;
            if(!ClientToScreen(h,ref o))return false;
            for(int row=-14;row<=14;row+=7)for(int col=-172;col<=152;col+=12) {
                if(!OwnedPoint(h,o,p.X+col*frame.Width/533,p.Y+(offset+row)*frame.Height/914))return false;
            }
            return true;
        }
        static IntPtr changingWindow;
        public static bool CheckAccount(IntPtr h,Bitmap glyph,double x,double y,string user,bool requirePassword) {
            if(requirePassword && h==changingWindow)return false;
            using(var dpi=new DpiScope())return !AccountPoint(h,glyph,x,y,user,requirePassword?-1:0).IsEmpty;
        }
        static Point AccountPoint(IntPtr h,Bitmap glyph,double x,double y,string user,int passwordCount) {
            Point p;using(var frame=Capture(h,glyph,x,y,out p)) {
                if(frame==null || (LastRead=="screen" && (!FieldOwner(h,frame,p,-210) || (passwordCount!=0 && !FieldOwner(h,frame,p,-150)))))return Point.Empty;
                using(var norm=Normalized(frame)) {
                    Point b=new Point(p.X*533/frame.Width,p.Y*914/frame.Height);
                    if(passwordCount<0)return FormReady(norm,b,user)?p:Point.Empty;
                    if(!HasAccountNumber(norm,b,user))return Point.Empty;
                    return passwordCount==0 || MaskCount(norm,b)==passwordCount?p:Point.Empty;
                }
            }
        }
        static bool Key(IntPtr h,uint msg,int key,IntPtr param) {
            UIntPtr result;return SendMessageTimeout(h,msg,(IntPtr)key,param,2,250,out result)!=IntPtr.Zero;
        }
        static bool ReplaceText(IntPtr h,Bitmap glyph,string value,int offset) {
            if(String.IsNullOrEmpty(value) || value.Length>160) return false;
            foreach(char c in value)if(Char.IsControl(c))return false;
            Point p;using(var frame=Capture(h,glyph,.5,.58,out p)) {
                if(frame==null || (LastRead=="screen" && !FieldOwner(h,frame,p,offset)))return false;
                // Mouse messages and text go only to the verified Tianyi window, never to the desktop focus or clipboard.
                int px=p.X-60*frame.Width/533,py=p.Y+offset*frame.Height/914;
                Rect dst;IntPtr ctx=SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(h));
                try {if(!GetClientRect(h,out dst))return false;} finally{if(ctx!=IntPtr.Zero)SetThreadDpiAwarenessContext(ctx);}
                var packed=(IntPtr)(((py*dst.Bottom/frame.Height)<<16)|(px*dst.Right/frame.Width&65535));
                if(!Key(h,0x201,1,packed) || !Key(h,0x202,0,packed))return false;
            }
            if(!Key(h,0x100,0x23,(IntPtr)1) || !Key(h,0x101,0x23,(IntPtr)1))return false;
            for(int n=0;n<160;n++)if(!Key(h,0x100,8,(IntPtr)1)||!Key(h,0x102,8,(IntPtr)1)||!Key(h,0x101,8,(IntPtr)1))return false;
            foreach(char c in value)if(!Key(h,0x102,c,(IntPtr)1))return false;
            return true;
        }
        public static bool FillAccount(IntPtr h,Bitmap glyph,string user,string password) {
            using(var dpi=new DpiScope()) {
                if(TryFill(h,glyph,user,password))return true;
                Reveal(h);Thread.Sleep(280);return TryFill(h,glyph,user,password);
            }
        }
        static bool TryFill(IntPtr h,Bitmap glyph,string user,string password) {
            if(String.IsNullOrEmpty(password))return false;
            changingWindow=h;
            if(!ReplaceText(h,glyph,user,-210))return false;
            Thread.Sleep(200);
            if(AccountPoint(h,glyph,.5,.58,user,0).IsEmpty)return false;
            // Confirm that this is a masked field before directing the actual saved credential to it.
            if(!ReplaceText(h,glyph,"xx",-150))return false;
            Thread.Sleep(160);
            if(AccountPoint(h,glyph,.5,.58,user,2).IsEmpty)return false;
            if(!ReplaceText(h,glyph,password,-150))return false;
            Thread.Sleep(180);
            if(AccountPoint(h,glyph,.5,.58,user,password.Length<=24?password.Length:-1).IsEmpty)return false;
            changingWindow=IntPtr.Zero; return true;
        }

        public static bool ClickVerified(IntPtr h, Bitmap glyph, double x, double y, bool physical) {
            return ClickVerified(h,glyph,x,y,physical,String.Empty);
        }
        public static bool ClickVerified(IntPtr h, Bitmap glyph, double x, double y, bool physical,string user) {
            using(var dpi=new DpiScope())return ClickOnClient(h,glyph,x,y,physical,user);
        }
        static bool ClickOnClient(IntPtr h, Bitmap glyph, double x, double y, bool physical,string user) {
            if(h==changingWindow)return false;
            Point p=AccountPoint(h,glyph,x,y,user,-1);
            if(p.IsEmpty || !Usable(h)) return false;
            if(physical) {
                Point origin=Point.Empty, old;
                if(!ClientToScreen(h,ref origin) || !OwnedPoint(h,origin,p.X,p.Y) || !GetCursorPos(out old)) return false;
                Point target=new Point(origin.X+p.X,origin.Y+p.Y);
                if(!SetCursorPos(target.X,target.Y)) return false;
                try {
                    if(!OwnedPoint(h,origin,p.X,p.Y)) return false;
                    mouse_event(2,0,0,0,UIntPtr.Zero); mouse_event(4,0,0,0,UIntPtr.Zero); return true;
                } finally { Point now; if(GetCursorPos(out now) && now==target) SetCursorPos(old.X,old.Y); }
            }
            Rect physicalRect,logical;
            if(!GetClientRect(h,out physicalRect) || physicalRect.Right<=0 || physicalRect.Bottom<=0) return false;
            IntPtr oldCtx=SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(h));
            try { if(!GetClientRect(h,out logical)) return false; }
            finally { if(oldCtx!=IntPtr.Zero) SetThreadDpiAwarenessContext(oldCtx); }
            int lx=p.X*logical.Right/physicalRect.Right, ly=p.Y*logical.Bottom/physicalRect.Bottom;
            IntPtr packed=(IntPtr)((ly<<16)|(lx&65535));
            if(!PostMessage(h,0x200,IntPtr.Zero,packed) || !PostMessage(h,0x201,(IntPtr)1,packed)) return false;
            Thread.Sleep(70);
            return PostMessage(h,0x202,IntPtr.Zero,packed);
        }
    }
}
