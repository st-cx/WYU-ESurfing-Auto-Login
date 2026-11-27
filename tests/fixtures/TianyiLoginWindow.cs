using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Offscreen, nonactivating native test window. All text supplied to it is synthetic.
public sealed class TianyiLoginWindow : IDisposable {
    delegate IntPtr WindowProc(IntPtr window,uint msg,IntPtr w,IntPtr l);
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct WindowClass {
        public uint style; public WindowProc proc; public int classExtra,windowExtra;
        public IntPtr module,icon,cursor,background; public string menu,name;
    }
    [StructLayout(LayoutKind.Sequential)] struct Msg {
        public IntPtr window; public uint message; public IntPtr w,l; public uint time;
        public int x,y; public uint privateData;
    }
    [DllImport("user32",CharSet=CharSet.Unicode,SetLastError=true)] static extern ushort RegisterClass(ref WindowClass c);
    [DllImport("user32",CharSet=CharSet.Unicode)] static extern bool UnregisterClass(string cls,IntPtr module);
    [DllImport("user32",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateWindowEx(int ext,string cls,string title,uint style,int x,int y,int width,int height,IntPtr parent,IntPtr menu,IntPtr module,IntPtr param);
    [DllImport("kernel32",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32",CharSet=CharSet.Unicode)] static extern IntPtr DefWindowProc(IntPtr h,uint msg,IntPtr w,IntPtr l);
    [DllImport("user32")] static extern int GetMessage(out Msg message,IntPtr window,uint first,uint last);
    [DllImport("user32",CharSet=CharSet.Unicode)] static extern IntPtr DispatchMessage(ref Msg message);
    [DllImport("user32")] static extern bool PostMessage(IntPtr window,uint message,IntPtr w,IntPtr l);
    [DllImport("user32")] static extern void PostQuitMessage(int code);
    [DllImport("user32")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    const string ClassName="wkeWebWindow";
    readonly string glyphPath,expectedUser,expectedPassword;
    readonly StringBuilder username,password;
    readonly ManualResetEvent ready=new ManualResetEvent(false);
    readonly Thread thread;
    Bitmap glyph; Font font;
    WindowProc procedure;
    Exception error;
    IntPtr handle;
    StringBuilder focused;
    bool onButton;
    int clicks,writtenPasswords;
    volatile bool accepted;
    public bool Accepted {get{return accepted;}}
    public int Clicks {get{return Interlocked.CompareExchange(ref clicks,0,0);}}
    public int PasswordCharacters {get{return Interlocked.CompareExchange(ref writtenPasswords,0,0);}}

    public TianyiLoginWindow(string template,string oldUser,string oldPassword,string expectedUser,string expectedPassword) {
        glyphPath=template;this.expectedUser=expectedUser;this.expectedPassword=expectedPassword;
        username=new StringBuilder(oldUser);password=new StringBuilder(oldPassword);
        thread=new Thread(Run);thread.IsBackground=true;thread.Start();
        if(!ready.WaitOne(5000))throw new TimeoutException("The test window did not start.");
        if(error!=null)throw new InvalidOperationException("The test window could not start.",error);
    }
    void Run() {
        IntPtr module=GetModuleHandle(null);bool registered=false;
        try {
            SetThreadDpiAwarenessContext((IntPtr)(-4));
            using(var original=new Bitmap(glyphPath)){
                glyph=new Bitmap(original.Width,original.Height);
                for(int y=0;y<glyph.Height;y++)for(int x=0;x<glyph.Width;x++)
                    glyph.SetPixel(x,y,original.GetPixel(x,y).R>127?Color.Green:Color.White);
            }
            font=new Font("Segoe UI",23,FontStyle.Regular,GraphicsUnit.Pixel);
            procedure=Proc;
            WindowClass c=new WindowClass{proc=procedure,module=module,name=ClassName};
            if(RegisterClass(ref c)==0)throw new Win32Exception();
            registered=true;
            // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW: never takes focus or enters the taskbar.
            handle=CreateWindowEx(0x08000080,ClassName,"",0x90000000,-25000,-25000,533,914,IntPtr.Zero,IntPtr.Zero,module,IntPtr.Zero);
            if(handle==IntPtr.Zero)throw new Win32Exception();
            ready.Set();
            Msg m;
            while(GetMessage(out m,IntPtr.Zero,0,0)>0)DispatchMessage(ref m);
        } catch(Exception ex) {error=ex;ready.Set();}
        finally {
            if(registered)UnregisterClass(ClassName,module);
            if(font!=null)font.Dispose();
            if(glyph!=null)glyph.Dispose();
        }
    }
    void Paint(IntPtr dc) {
        using(var g=Graphics.FromHdc(dc)) {
            g.Clear(Color.White);g.TextRenderingHint=TextRenderingHint.AntiAliasGridFit;
            g.DrawImageUnscaled(glyph,240,520);
            for(int i=0;i<username.Length;i++) g.DrawString(username[i].ToString(),font,Brushes.Black,106+19*i,303,StringFormat.GenericTypographic);
            for(int i=0;i<password.Length;i++) g.FillEllipse(Brushes.Black,106+12*i,377,8,8);
        }
    }
    IntPtr Proc(IntPtr h,uint msg,IntPtr w,IntPtr l) {
        if(msg==0x317 || msg==0x318){Paint(w);return (IntPtr)1;}
        if(msg==0x201 || msg==0x202){
            int point=(int)l.ToInt64(),x=point&65535,y=(point>>16)&65535;
            bool button=Math.Abs(x-267)<42 && Math.Abs(y-533)<17;
            if(msg==0x201){
                onButton=button;focused=null;
                if(Math.Abs(y-323)<21)focused=username;
                if(Math.Abs(y-383)<17)focused=password;
            }else if(onButton && button){
                Interlocked.Increment(ref clicks);
                accepted=username.ToString()==expectedUser && password.ToString()==expectedPassword;
                onButton=false;
            }
            return IntPtr.Zero;
        }
        if(msg==0x102 && focused!=null){
            char c=(char)w.ToInt32();
            if(c=='\b'){if(focused.Length>0)focused.Length--;}
            else if(!Char.IsControl(c)){
                focused.Append(c);if(focused==password)Interlocked.Increment(ref writtenPasswords);
            }
            return IntPtr.Zero;
        }
        if(msg==2){PostQuitMessage(0);return IntPtr.Zero;}
        return DefWindowProc(h,msg,w,l);
    }
    public void Dispose() {
        if(handle!=IntPtr.Zero)PostMessage(handle,0x10,IntPtr.Zero,IntPtr.Zero);
        if(!thread.Join(3000))throw new TimeoutException("The test window did not close.");
        ready.Dispose();
    }
}
