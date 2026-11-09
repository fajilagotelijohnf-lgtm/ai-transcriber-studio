using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using AITranscriberInstaller;
public partial class InstallerTests {
 static void TestWindows() {
  Check(WindowsIntegration.Quote("a b")=="\"a b\"","Windows spaced argument quoted");
  Check(WindowsIntegration.Quote("C:\\folder with spaces\\")=="\"C:\\folder with spaces\\\\\"","Windows trailing backslash quoted");
  var psi=WindowsIntegration.AppStartInfo("C:\\folder with spaces\\日本語");
  Check(psi.Arguments.Contains("-STA")&&psi.Arguments.Contains("-NoProfile")&&psi.Arguments.Contains("-File"),"launcher uses Windows PowerShell STA");
  Check(psi.EnvironmentVariables["PATH"].StartsWith("C:\\folder with spaces\\日本語;"),"bundled FFmpeg first in child PATH");
  string pathFixture=Fixture();string bundled=Path.Combine(pathFixture,"bundled");string conflict=Path.Combine(pathFixture,"conflicting");Directory.CreateDirectory(bundled);Directory.CreateDirectory(conflict);
  foreach(var item in new[]{new[]{bundled,"BUNDLED"},new[]{conflict,"CONFLICT"}}) {
   using(var provider=new Microsoft.CSharp.CSharpCodeProvider()) {var parameters=new System.CodeDom.Compiler.CompilerParameters{GenerateExecutable=true,OutputAssembly=Path.Combine(item[0],"ffmpeg.exe")};parameters.ReferencedAssemblies.Add("System.dll");var compiled=provider.CompileAssemblyFromSource(parameters,"class Entry { static void Main() { System.Console.Write(\""+item[1]+"\"); } }");if(compiled.Errors.HasErrors)throw new Exception("Cannot compile PATH test fixtures");}
  }
  string originalPath=Environment.GetEnvironmentVariable("PATH");System.Diagnostics.ProcessStartInfo childInfo;
  try{Environment.SetEnvironmentVariable("PATH",conflict+";"+originalPath);childInfo=WindowsIntegration.AppStartInfo(bundled);}finally{Environment.SetEnvironmentVariable("PATH",originalPath);}
  childInfo.Arguments="-NoProfile -NonInteractive -Command ffmpeg.exe";childInfo.RedirectStandardOutput=true;childInfo.RedirectStandardError=true;
  using(var child=System.Diagnostics.Process.Start(childInfo)){var text=child.StandardOutput.ReadToEndAsync();if(!child.WaitForExit(20000)){child.Kill();throw new Exception("PATH test timed out");}Check(child.ExitCode==0&&text.GetAwaiter().GetResult().Trim()=="BUNDLED","actual PowerShell child launches bundled FFmpeg over conflicting executable");}
  Check(Environment.GetEnvironmentVariable("PATH")==originalPath,"parent PATH unchanged after child launch");
  string root=Fixture();string dir=Path.Combine(root,"app"); var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http))) Check(System.Threading.Tasks.Task.Run(()=>new Installation(tr,p=>{}).InstallAsync(new InstallRequest{Directory=dir,ModelIds=new[]{"small"}},c,null,CancellationToken.None)).GetAwaiter().GetResult().Success,"removal fixture installed");
  var stale=InstallationRecord.Read(dir);
  using(var tr=new Transfers(new HttpClient(http)))System.Threading.Tasks.Task.Run(()=>new Installation(tr,p=>{}).AddModelsAsync(dir,new[]{"medium"},c,null,CancellationToken.None)).GetAwaiter().GetResult();
  WindowsIntegration.Register(stale,false,fresh=>{fresh.Shortcuts=new[]{"fixture-only"};fresh.Save();});
  Check(InstallationRecord.Read(dir).OwnedFiles.Contains("ggml-medium.bin"),"registration refreshes stale metadata under the modify lease");
  using(var held=Installation.ModifyLease(dir))Throws(()=>WindowsIntegration.Register(stale,false,fresh=>{}),"registration refuses concurrent mutation");
  Check(NativeRuntime.IsDependencyFailure(new RuntimeStartupException(unchecked((int)0xC0000139),"old VC runtime")),"old-runtime entry-point failure triggers prerequisite handling");
  Check(!NativeRuntime.IsDependencyFailure(new RuntimeStartupException(unchecked((int)0xC000001D),"CPU instruction unsupported")),"CPU failure is distinguished from missing prerequisite");
  string unrelated=Path.Combine(dir,"my-transcript.txt");File.WriteAllText(unrelated,"keep");var r=InstallationRecord.Read(dir);
  using(var active=Installation.SessionLease(dir,false)) Throws(()=>WindowsIntegration.RemoveOwnedFiles(r),"active transcriber blocks uninstall");
  string shortcut=Path.Combine(root,"launcher 日本語.lnk");WindowsIntegration.WriteShortcut(shortcut,Path.Combine(dir,"AITranscriber.exe"),"--launch",dir);
  Check(WindowsIntegration.ShortcutMatches(shortcut,Path.Combine(dir,"AITranscriber.exe")),"real shortcut target round trip");
  object shellLink=new NativeShellLink();
  try{
   ((System.Runtime.InteropServices.ComTypes.IPersistFile)shellLink).Load(shortcut,0);
   var iconPath=new System.Text.StringBuilder(32768);int iconIndex;
   ((IShellLinkW)shellLink).GetIconLocation(iconPath,iconPath.Capacity,out iconIndex);
   Check(iconPath.ToString()==Path.Combine(dir,"AITranscriber.exe")&&iconIndex==0,"shortcut uses the installed EXE branded icon at index zero");
   Check(DesktopIdentity.ShortcutId(shellLink)==DesktopIdentity.AppId,"shortcut taskbar identity matches the installed app");
   DesktopIdentity.Apply();Check(DesktopIdentity.CurrentId()==DesktopIdentity.AppId,"app process uses its own taskbar identity");
  }finally{System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shellLink);}
  File.Delete(shortcut);
  var unsafeRecord=InstallationRecord.Read(dir);unsafeRecord.OwnedFiles=unsafeRecord.OwnedFiles.Concat(new[]{"..\\outside.txt"}).ToArray();unsafeRecord.Save();
  Throws(()=>WindowsIntegration.RemoveOwnedFiles(unsafeRecord),"unsafe manifest rejected before removal");
  r.Save();var result=WindowsIntegration.RemoveOwnedFiles(r);Check(result.Success,"owned files removed");
  Check(File.Exists(unrelated)&&File.ReadAllText(unrelated)=="keep","unrelated transcript survives removal");
  Check(!File.Exists(Path.Combine(dir,"whisper-cli.exe"))&&!File.Exists(Path.Combine(dir,"Transcriber-UI.ps1")),"app-owned files removed");
 }
}
