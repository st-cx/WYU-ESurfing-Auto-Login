using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("校园网自动登录更新")]
[assembly: AssemblyProduct("WYU ESurfing Auto Login")]
[assembly: AssemblyVersion("1.6.3.0")]
[assembly: AssemblyFileVersion("1.6.3.0")]

internal static class UpdateLauncher {
    const string Title="校园网自动登录 v1.6.3";

    [STAThread] static int Main(string[] args) {
        bool preview=args.Length==1 && args[0]=="--check";
        try {
            var id=WindowsIdentity.GetCurrent();
            if(args.Length!=0 && !preview && (args.Length!=2 || args[0]!="--install" || args[1]!=id.User.Value))
                throw new InvalidOperationException("请使用安装校园网工具的 Windows 账号打开更新程序。");
            if(!preview && !new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator)) {
                var start=new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,"--install "+id.User.Value);
                start.UseShellExecute=true; start.Verb="runas";
                using(var child=Process.Start(start)) {child.WaitForExit(); return child.ExitCode;}
            }
            return RunPackage(preview);
        } catch(Win32Exception ex) {
            if(ex.NativeErrorCode==1223) return 2; // The user dismissed UAC.
            if(!preview) ShowFailure(ex.Message); return 1;
        } catch(Exception ex) {
            if(!preview) ShowFailure(ex.Message); return 1;
        }
    }
    static void ShowFailure(string message) {
        string dir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CampusNetWatchdog","logs");
        string log=Path.Combine(dir,"update.log");
        try {
            if(Directory.Exists(dir)) {
                File.AppendAllText(log,DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")+" [更新程序] "+message+Environment.NewLine,Encoding.UTF8);
                if(message.IndexOf(log,StringComparison.OrdinalIgnoreCase)<0) message+=Environment.NewLine+"日志："+log;
            }
        } catch(IOException) {} catch(UnauthorizedAccessException) {}
        MessageBox.Show(message,Title,MessageBoxButtons.OK,MessageBoxIcon.Error);
    }
    static int RunPackage(bool preview) {
        string temp=Path.Combine(Path.GetTempPath(),"CampusNetUpdate-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        string prefix=Path.GetFullPath(temp)+Path.DirectorySeparatorChar;
        try {
            using(var resource=Assembly.GetExecutingAssembly().GetManifestResourceStream("CampusNet.Payload"))
            using(var archive=new ZipArchive(resource,ZipArchiveMode.Read)) {
                foreach(var entry in archive.Entries) {
                    string path=Path.GetFullPath(Path.Combine(temp,entry.FullName));
                    if(!path.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)) throw new IOException("更新包路径无效。");
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    using(var source=entry.Open()) using(var dest=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None))
                        source.CopyTo(dest);
                }
            }
            string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            string script=Path.Combine(temp,"upgrade.ps1");
            var start=new ProcessStartInfo(ps,"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""+script+"\" -WriteResult"+(preview?" -Preview":""));
            start.UseShellExecute=false; start.WorkingDirectory=temp;
            start.CreateNoWindow=true; start.WindowStyle=ProcessWindowStyle.Hidden;
            start.RedirectStandardError=true; start.RedirectStandardOutput=true;
            start.StandardErrorEncoding=Encoding.UTF8; start.StandardOutputEncoding=Encoding.UTF8;
            using(var child=Process.Start(start)) {
                var error=child.StandardError.ReadToEndAsync();
                var output=child.StandardOutput.ReadToEndAsync();
                child.WaitForExit();
                string diagnostic=(error.Result+Environment.NewLine+output.Result).Trim();
                string resultPath=Path.Combine(temp,"update-result.txt");
                string[] lines=File.Exists(resultPath)?File.ReadAllLines(resultPath,Encoding.UTF8):new string[0];
                string message=lines.Length>1?String.Join(Environment.NewLine,lines,1,lines.Length-1):"";
                bool ok=child.ExitCode==0 && lines.Length>1 && (lines[0]=="OK" || lines[0]=="WARN");
                if(!ok) {
                    if(message.Length==0) message="更新程序没有返回完成记录，退出码 "+child.ExitCode+"。"+Environment.NewLine+diagnostic;
                    throw new InvalidOperationException(message);
                }
                if(!preview) MessageBox.Show(message,Title,MessageBoxButtons.OK,
                    lines[0]=="WARN"?MessageBoxIcon.Warning:MessageBoxIcon.Information);
                return 0;
            }
        } finally {
            try { CleanPackage(temp); }
            catch(IOException) {} catch(UnauthorizedAccessException) {}
        }
    }
    static void CleanPackage(string temp) {
        // Only clean up this freshly allocated resource directory.
        string exact=Path.GetFullPath(temp);
        if(String.Equals(Path.GetDirectoryName(exact).TrimEnd('\\'),Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase) &&
            Path.GetFileName(exact).StartsWith("CampusNetUpdate-",StringComparison.Ordinal) &&
            (File.GetAttributes(exact)&FileAttributes.ReparsePoint)==0) {
            foreach(string dir in new[]{ "ui","tools" }) {
                string path=Path.Combine(exact,dir);
                if(Directory.Exists(path) && (File.GetAttributes(path)&FileAttributes.ReparsePoint)==0) {
                    foreach(string f in Directory.GetFiles(path)) File.Delete(f);
                    Directory.Delete(path,false);
                }
            }
            foreach(string f in Directory.GetFiles(exact)) File.Delete(f);
            Directory.Delete(exact,false);
        }
    }
}
