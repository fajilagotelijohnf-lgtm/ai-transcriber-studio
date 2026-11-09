using System;
using System.IO;
using System.Threading;
using AITranscriberInstaller;
public partial class InstallerTests {
 sealed class ConsoleProgress : IProgress<TransferProgress> {
  DateTime last=DateTime.MinValue; string phase;
  public void Report(TransferProgress p) { if(phase!=p.ArtifactId+p.Phase || (DateTime.UtcNow-last).TotalSeconds>3) { phase=p.ArtifactId+p.Phase;last=DateTime.UtcNow;Console.WriteLine(p.ArtifactId+" "+p.Phase+" "+(p.BytesReceived/1048576)+" MiB"); } }
 }
 static int Smoke(bool medium) {
  string root=Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"..","test-results"));
  string dir=Path.Combine(root,"actual install 日本語"); var c=Catalog.Embedded();
  var core=new Installation(null,null,Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"AI-Transcriber-Setup.exe"));
  var result=(medium?core.AddModelsAsync(dir,new[]{"medium"},c,new ConsoleProgress(),CancellationToken.None):core.InstallAsync(new InstallRequest{Directory=dir,ModelIds=new[]{"small"}},c,new ConsoleProgress(),CancellationToken.None)).GetAwaiter().GetResult();
  Console.WriteLine(result.Message); if(!result.Success) return 1;
  Console.WriteLine("SMOKE PASS "+(medium?"Medium added":"Small installed")+" "+dir); return 0;
 }
}
