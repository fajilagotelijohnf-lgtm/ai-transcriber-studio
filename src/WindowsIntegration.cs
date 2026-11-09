using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;
namespace AITranscriberInstaller {
 [ComImport,Guid("00021401-0000-0000-C000-000000000046")] internal class NativeShellLink {}
 [ComImport,InterfaceType(ComInterfaceType.InterfaceIsIUnknown),Guid("000214F9-0000-0000-C000-000000000046")] internal interface IShellLinkW {
  void GetPath([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int length,IntPtr data,int flags);
  void GetIDList(out IntPtr id);void SetIDList(IntPtr id);
  void GetDescription([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder text,int length);
  void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
  void GetWorkingDirectory([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int length);
  void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string path);
  void GetArguments([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder args,int length);
  void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
  void GetHotkey(out short key);void SetHotkey(short key);void GetShowCmd(out int show);void SetShowCmd(int show);
  void GetIconLocation([Out,MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,int length,out int index);
  void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path,int index);
  void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path,int reserved);void Resolve(IntPtr hwnd,int flags);
  void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
 }
 public class RemovalResult { public bool Success; public string[] RemovedPaths; public string[] RetainedPaths; public string Message; }
 public static class WindowsIntegration {
  const string UninstallKey="Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\AITranscriberStudio";
  public static string Quote(string value) {
   var b=new StringBuilder("\"");int slashes=0;
   foreach(char ch in value) { if(ch=='\\') {slashes++;continue;} if(ch=='\"') {b.Append('\\',slashes*2+1);b.Append(ch);} else {b.Append('\\',slashes);b.Append(ch);} slashes=0; }
   b.Append('\\',slashes*2);b.Append('"');return b.ToString();
  }
  public static ProcessStartInfo AppStartInfo(string directory) {
   string script=Path.Combine(directory,"Transcriber-UI.ps1");
   string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell\\v1.0\\powershell.exe");
   var info=new ProcessStartInfo(ps,"-NoProfile -STA -ExecutionPolicy Bypass -File "+Quote(script)){UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,WorkingDirectory=directory};
   info.EnvironmentVariables["PATH"]=directory+";"+(info.EnvironmentVariables["PATH"]??"");return info;
  }
  public static Process LaunchApp(string directory) {
   var lease=Installation.SessionLease(directory,false);
   try {
    var record=InstallationRecord.Read(directory);if(!record.Complete||PublicationTransaction.HasPending(directory))throw new IOException("Run setup to finish or recover this installation before launching the transcriber.");
    if(!Payload.HashFile(Installation.SafePath(directory,"Transcriber-UI.ps1")).Equals(Catalog.Embedded().ScriptSha256,StringComparison.OrdinalIgnoreCase))throw new IOException("The transcriber script differs from the packaged version. Run setup to repair it.");
    var p=new Process{StartInfo=AppStartInfo(directory),EnableRaisingEvents=true};p.Exited+=delegate{lease.Dispose();};if(!p.Start())throw new IOException("Could not start the transcriber.");return p;
   }
   catch {lease.Dispose();throw;}
  }
  public static void OpenInstalledApp(string directory) { Process.Start(new ProcessStartInfo(Installation.SafePath(directory,"AITranscriber.exe"),"--launch"){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=directory}); }
  public static string RegisteredDirectory() {using(var k=Registry.CurrentUser.OpenSubKey(UninstallKey))return k==null?null:k.GetValue("InstallLocation") as string;}
  public static void CheckRegistration(string directory) {
   string existing=RegisteredDirectory(); if(existing!=null&&!Installation.NormalizeDirectory(existing).Equals(Installation.NormalizeDirectory(directory),StringComparison.OrdinalIgnoreCase))
    throw new IOException("AI Transcriber Studio is already registered in:\r\n"+existing+"\r\nChoose that folder to repair it, or uninstall it first before choosing a different folder.");
  }
  static string MenuFolder(){return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),"Programs","AI Transcriber Studio");}
  static string[] ShortcutPaths(){return new[]{Path.Combine(MenuFolder(),"AI Transcriber Studio.lnk"),Path.Combine(MenuFolder(),"Manage Models.lnk"),Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),"AI Transcriber Studio.lnk")};}
  public static void WriteShortcut(string path,string target,string arguments,string directory) {
   Installation.RejectReparse(path);Directory.CreateDirectory(Path.GetDirectoryName(path));
   object link=new NativeShellLink();
   try{var shortcut=(IShellLinkW)link;shortcut.SetPath(target);shortcut.SetArguments(arguments);shortcut.SetWorkingDirectory(directory);shortcut.SetIconLocation(target,0);shortcut.SetDescription("AI Transcriber Studio");DesktopIdentity.ConfigureShortcut(link);((System.Runtime.InteropServices.ComTypes.IPersistFile)link).Save(path,true);}
   finally{Marshal.FinalReleaseComObject(link);}
  }
  public static bool ShortcutMatches(string path,string target) {
   if(!File.Exists(path))return false;Installation.RejectReparse(path);
   object link=new NativeShellLink();
   try{((System.Runtime.InteropServices.ComTypes.IPersistFile)link).Load(path,0);var value=new StringBuilder(32768);((IShellLinkW)link).GetPath(value,value.Capacity,IntPtr.Zero,0);return string.Equals(value.ToString(),target,StringComparison.OrdinalIgnoreCase);}
   finally{Marshal.FinalReleaseComObject(link);}
  }
  public static void Register(InstallationRecord record,bool desktopShortcut) {
   Register(record,desktopShortcut,null);
  }
  internal static void Register(InstallationRecord expected,bool desktopShortcut,Action<InstallationRecord> applyRegistration) {
   using(var lease=Installation.ModifyLease(expected.InstallDirectory)) {
    var fresh=InstallationRecord.Read(expected.InstallDirectory);
    if(fresh.InstallId!=expected.InstallId)throw new IOException("Installation identity changed before registration.");
    if(applyRegistration!=null)applyRegistration(fresh);else RegisterCore(fresh,desktopShortcut);
   }
  }
  static void RegisterCore(InstallationRecord record,bool desktopShortcut) {
   CheckRegistration(record.InstallDirectory);string exe=Installation.SafePath(record.InstallDirectory,"AITranscriber.exe");var paths=ShortcutPaths();var created=new List<string>(record.Shortcuts);
   for(int i=0;i<(desktopShortcut?3:2);i++) {
    if(File.Exists(paths[i])&&!ShortcutMatches(paths[i],exe))throw new IOException("A different shortcut already exists: "+paths[i]+". Rename it before retrying setup.");
    WriteShortcut(paths[i],exe,i==1?"--models --install-dir "+Quote(record.InstallDirectory):"--launch",record.InstallDirectory);
    if(!created.Contains(paths[i],StringComparer.OrdinalIgnoreCase))created.Add(paths[i]);record.Shortcuts=created.ToArray();record.Save();
   }
   using(var k=Registry.CurrentUser.CreateSubKey(UninstallKey)) {
    k.SetValue("DisplayName","AI Transcriber Studio");k.SetValue("DisplayVersion",Catalog.Embedded().Version);k.SetValue("Publisher","AI Transcriber Studio");k.SetValue("InstallLocation",record.InstallDirectory);k.SetValue("InstallId",record.InstallId);
    k.SetValue("UninstallString",Quote(exe)+" --uninstall --install-dir "+Quote(record.InstallDirectory));k.SetValue("DisplayIcon",exe+",0");k.SetValue("NoModify",1,RegistryValueKind.DWord);k.SetValue("NoRepair",1,RegistryValueKind.DWord);
    long bytes=record.OwnedFiles.Select(p=>Installation.SafePath(record.InstallDirectory,p)).Where(File.Exists).Sum(p=>new FileInfo(p).Length);k.SetValue("EstimatedSize",(int)Math.Min(int.MaxValue,bytes/1024),RegistryValueKind.DWord);
   }
  }
  static bool KnownOwned(string relative) {
   if(new[]{"installation.json",".ats-modify.lock",".ats-session.lock",".ats-install.log","AITranscriber.exe","Transcriber-UI.ps1","THIRD-PARTY-NOTICES.md","whisper-cli.exe","whisper.dll","ggml.dll","ggml-base.dll"}.Contains(relative,StringComparer.OrdinalIgnoreCase))return true;
   if(System.Text.RegularExpressions.Regex.IsMatch(relative,@"^ggml-cpu-[a-z0-9]+\.dll$",System.Text.RegularExpressions.RegexOptions.IgnoreCase))return true;
   if(relative.Equals("ffmpeg.exe",StringComparison.OrdinalIgnoreCase)||Catalog.Embedded().Models.Any(m=>m.FileName.Equals(relative,StringComparison.OrdinalIgnoreCase)))return true;
   return Path.GetDirectoryName(relative)=="licenses"&&(Path.GetFileName(relative)=="Whisper-LICENSE.txt"||Path.GetFileName(relative).StartsWith("ffmpeg-notice-",StringComparison.OrdinalIgnoreCase));
  }
  public static RemovalResult RemoveOwnedFiles(InstallationRecord supplied) {
   string dir=Installation.NormalizeDirectory(supplied.InstallDirectory);InstallationRecord r;
   var removed=new List<string>();var retained=new List<string>();bool failed=false;
   using(var modify=Installation.ModifyLease(dir)) {
    r=InstallationRecord.Read(dir);if(r.InstallId!=supplied.InstallId)throw new IOException("Installation identity changed; removal refused.");
    if(PublicationTransaction.HasPending(dir))throw new IOException("Run setup to recover the interrupted installation before removing it. Recovery backups were preserved.");
    foreach(string relative in r.OwnedFiles)if(!KnownOwned(relative))throw new IOException("Unrecognized ownership entry; removal refused: "+relative);
    using(var session=Installation.SessionLease(dir,true)) {
    var paths=r.OwnedFiles.Where(p=>!new[]{"installation.json",".ats-modify.lock",".ats-session.lock","AITranscriber.exe"}.Contains(p,StringComparer.OrdinalIgnoreCase)).Concat(r.OwnedFiles.Where(p=>p.Equals("AITranscriber.exe",StringComparison.OrdinalIgnoreCase)));
    foreach(string relative in paths) {
     string file=Installation.SafePath(dir,relative);if(!File.Exists(file))continue;
     var expected=r.FileHashes.FirstOrDefault(f=>f.Path.Equals(relative,StringComparison.OrdinalIgnoreCase));
     if(expected!=null&&!Payload.HashFile(file).Equals(expected.Sha256,StringComparison.OrdinalIgnoreCase)){retained.Add(file+" (modified; preserved)");continue;}
     if(relative=="AITranscriber.exe"&&failed)continue;
     try{File.Delete(file);removed.Add(file);}catch(IOException){retained.Add(file+" (in use)");failed=true;}catch(UnauthorizedAccessException){retained.Add(file+" (access denied)");failed=true;}
    }
    if(!failed){File.Delete(Installation.SafePath(dir,"installation.json"));removed.Add(Path.Combine(dir,"installation.json"));}
    }
   }
   if(!failed) {
    foreach(string p in new[]{".ats-modify.lock",".ats-session.lock"}) {string file=Installation.SafePath(dir,p);if(File.Exists(file))File.Delete(file);}
    string licenses=Installation.SafePath(dir,"licenses");if(Directory.Exists(licenses)&&!Directory.EnumerateFileSystemEntries(licenses).Any())Directory.Delete(licenses);
    if(!Directory.EnumerateFileSystemEntries(dir).Any())Directory.Delete(dir);
   }
   return new RemovalResult{Success=!failed,RemovedPaths=removed.ToArray(),RetainedPaths=retained.ToArray(),Message=failed?"Some app files are in use or inaccessible. Close the app and retry removal.":"App removed. Recordings, transcripts, settings, and unrelated files were preserved."};
  }
  public static void BeginUninstall(string directory) {
   var r=InstallationRecord.Read(directory);
   if(MessageBox.Show("Remove AI Transcriber Studio from:\r\n"+directory+"\r\n\r\nYour recordings, transcripts, settings and unrelated files will be kept.","Remove AI Transcriber Studio",MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes)return;
   using(Installation.ModifyLease(directory))using(Installation.SessionLease(directory,true)){}
   string temp=Path.Combine(Path.GetTempPath(),"AITranscriber-Uninstall-"+Guid.NewGuid().ToString("N"));Installation.RejectReparse(temp);Directory.CreateDirectory(temp);
   string worker=Path.Combine(temp,"Remove.exe");File.Copy(System.Reflection.Assembly.GetExecutingAssembly().Location,worker);
   Process.Start(new ProcessStartInfo(worker,"--uninstall-worker --install-dir "+Quote(directory)+" --install-id "+Quote(r.InstallId)+" --parent-pid "+Process.GetCurrentProcess().Id){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=temp});
  }
  public static void UninstallWorker(string directory,string id,int parentPid) {
   try{using(var parent=Process.GetProcessById(parentPid))if(!parent.WaitForExit(15000))throw new IOException("The uninstall launcher is still open. Try again.");}catch(ArgumentException){}
   var r=InstallationRecord.Read(directory);if(r.InstallId!=id)throw new IOException("Installation identity mismatch.");var result=RemoveOwnedFiles(r);
   if(result.Success) {
    string exe=Path.Combine(directory,"AITranscriber.exe");var allowed=ShortcutPaths();
    foreach(string shortcut in r.Shortcuts)if(allowed.Contains(shortcut,StringComparer.OrdinalIgnoreCase)&&ShortcutMatches(shortcut,exe))File.Delete(shortcut);
    if(Directory.Exists(MenuFolder())&&!Directory.EnumerateFileSystemEntries(MenuFolder()).Any())Directory.Delete(MenuFolder());
    using(var key=Registry.CurrentUser.OpenSubKey(UninstallKey)) {if(key!=null && (string)key.GetValue("InstallId")==id && string.Equals((string)key.GetValue("InstallLocation"),directory,StringComparison.OrdinalIgnoreCase)){key.Close();Registry.CurrentUser.DeleteSubKeyTree(UninstallKey,false);}}
   }
   MessageBox.Show(result.Message+(result.RetainedPaths.Length>0?"\r\n\r\n"+string.Join("\r\n",result.RetainedPaths):""),"AI Transcriber Studio",MessageBoxButtons.OK,result.Success?MessageBoxIcon.Information:MessageBoxIcon.Warning);
  }
 }
}
