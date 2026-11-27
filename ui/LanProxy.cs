using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace CampusRecovery {
    public static class FileCommit {
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern bool MoveFileEx(string source,string destination,int flags);
        public static void Replace(string source,string destination) {
            for(int attempt=0;;attempt++) {
                if(MoveFileEx(source,destination,9)) return; // REPLACE_EXISTING | WRITE_THROUGH, same volume.
                int code=Marshal.GetLastWin32Error();
                if(attempt>=8 || (code!=5 && code!=32 && code!=33)) throw new Win32Exception(code);
                System.Threading.Thread.Sleep(45);
            }
        }
    }
    public sealed class LanSettings {
        public int Flags { get; set; }
        public string Server { get; set; }
        public string Bypass { get; set; }
        public string Pac { get; set; }
    }
    public static class LanProxy {
        [StructLayout(LayoutKind.Sequential)] struct Options {
            public int Size; public IntPtr Connection; public int Count, Error; public IntPtr Items;
        }
        [DllImport("wininet.dll",EntryPoint="InternetQueryOptionW",SetLastError=true)]
        static extern bool Query(IntPtr h,int option,ref Options list,ref int size);
        [DllImport("wininet.dll",EntryPoint="InternetSetOptionW",SetLastError=true)]
        static extern bool Set(IntPtr h,int option,ref Options list,int size);
        [DllImport("wininet.dll",EntryPoint="InternetSetOptionW",SetLastError=true)]
        static extern bool Notify(IntPtr h,int option,IntPtr data,int size);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr ptr);
        static readonly int Offset=IntPtr.Size==8?8:4, Stride=IntPtr.Size==8?16:12;

        static LanSettings Transfer(LanSettings input, bool flagsOnly) {
            // INTERNET_PER_CONN_OPTION_LIST with a null connection selects this user's LAN.
            int[] ids=flagsOnly?new[]{1}:new[]{1,2,3,4};
            Options list=new Options {Size=Marshal.SizeOf(typeof(Options)),Count=ids.Length};
            list.Items=Marshal.AllocHGlobal(Stride*ids.Length);
            var allocated=new List<IntPtr>();
            bool queried=false;
            try {
                Marshal.Copy(new byte[Stride*ids.Length],0,list.Items,Stride*ids.Length);
                for(int i=0;i<ids.Length;i++) {
                    IntPtr elem=IntPtr.Add(list.Items,i*Stride);
                    Marshal.WriteInt32(elem,ids[i]);
                    if(input==null) continue;
                    if(i==0) Marshal.WriteInt32(elem,Offset,input.Flags);
                    else {
                        string text=i==1?input.Server:i==2?input.Bypass:input.Pac;
                        IntPtr str=Marshal.StringToHGlobalUni(text??"");
                        allocated.Add(str); Marshal.WriteIntPtr(elem,Offset,str);
                    }
                }
                int size=list.Size;
                if(input!=null) {
                    if(!Set(IntPtr.Zero,75,ref list,size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    Notify(IntPtr.Zero,39,IntPtr.Zero,0); Notify(IntPtr.Zero,37,IntPtr.Zero,0);
                    return input;
                }
                queried=true;
                if(!Query(IntPtr.Zero,75,ref list,ref size)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return new LanSettings {Flags=Marshal.ReadInt32(list.Items,Offset),
                    Server=ReadString(list.Items,1),Bypass=ReadString(list.Items,2),Pac=ReadString(list.Items,3)};
            } finally {
                if(queried) for(int i=1;i<ids.Length;i++) {
                    IntPtr p=Marshal.ReadIntPtr(list.Items,i*Stride+Offset); if(p!=IntPtr.Zero) GlobalFree(p);
                }
                foreach(IntPtr p in allocated) Marshal.FreeHGlobal(p);
                Marshal.FreeHGlobal(list.Items);
            }
        }
        static string ReadString(IntPtr start,int i) {
            return Marshal.PtrToStringUni(Marshal.ReadIntPtr(start,i*Stride+Offset))??"";
        }
        public static LanSettings Read() { return Transfer(null,false); }
        public static void Direct() { Transfer(new LanSettings {Flags=1},true); }
        public static void Restore(LanSettings saved) { Transfer(saved,false); }
    }
}
