using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using AITranscriberInstaller;
public partial class InstallerTests {
 public sealed class RoutingHttp : HttpMessageHandler {
  public Dictionary<string,byte[]> Files=new Dictionary<string,byte[]>(); public int Calls;
  protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r,CancellationToken token) {
   token.ThrowIfCancellationRequested(); Calls++; byte[] bytes;
   var response=new HttpResponseMessage(Files.TryGetValue(r.RequestUri.AbsoluteUri,out bytes)?HttpStatusCode.OK:HttpStatusCode.NotFound);
   response.Content=new ByteArrayContent(bytes??new byte[0]); return Task.FromResult(response);
  }
 }
 static byte[] Zip(params string[] names) {
  using(var m=new MemoryStream()) { using(var z=new ZipArchive(m,ZipArchiveMode.Create,true)) foreach(var n in names) using(var w=new StreamWriter(z.CreateEntry(n).Open())) w.Write("fixture "+n); return m.ToArray(); }
 }
 static Artifact Route(RoutingHttp http,string id,byte[] bytes) {
  var a=TestArtifact(bytes); a.Id=id; a.Url="https://fixture.invalid/"+id; http.Files[a.Url]=bytes; return a;
 }
 static Catalog FixtureCatalog(RoutingHttp http) {
  var c=Catalog.Embedded(); c.Whisper=Route(http,"whisper",Zip("Release/whisper-cli.exe","Release/whisper.dll","Release/ggml.dll","Release/ggml-base.dll"));
  c.Ffmpeg=Route(http,"ffmpeg",Zip("build/bin/ffmpeg.exe","build/LICENSE","build/README.txt"));
  foreach(var m in c.Models) {var a=Route(http,m.Id,System.Text.Encoding.UTF8.GetBytes("fixture model "+m.Id)); m.Url=a.Url; m.DownloadBytes=a.DownloadBytes; m.ExpandedBytes=a.ExpandedBytes; m.Hash=a.Hash;}
  return c;
 }
 static void TestInstallation() {
  string root=Fixture(); string dir=Path.Combine(root,"chosen folder 日本語"); var http=new RoutingHttp(); var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http))) {
   var engine=new Installation(tr,p=>{});
   var result=engine.InstallAsync(new InstallRequest{Directory=dir,ModelIds=new[]{"small"}},c,null,CancellationToken.None).GetAwaiter().GetResult();
   Check(result.Success,"fresh install Small only");
   Check(File.Exists(Path.Combine(dir,"ggml-small.bin"))&&!File.Exists(Path.Combine(dir,"ggml-medium.bin")),"only selected model installed");
   Check(Payload.HashFile(Path.Combine(dir,"Transcriber-UI.ps1")).Equals(c.ScriptSha256,StringComparison.OrdinalIgnoreCase),"installed source byte-for-byte unchanged");
   var added=engine.AddModelsAsync(dir,new[]{"medium"},c,null,CancellationToken.None).GetAwaiter().GetResult();
   Check(added.Success&&File.Exists(Path.Combine(dir,"ggml-medium.bin")),"add Medium through same manager core");
   Check(Transfers.VerifyFile(Path.Combine(dir,"ggml-small.bin"),c.Models[4]),"Small preserved after Medium");
   int calls=http.Calls; engine.AddModelsAsync(dir,new[]{"small","medium"},c,null,CancellationToken.None).GetAwaiter().GetResult(); Check(calls==http.Calls,"installed valid models do not redownload");
   var states=Installation.GetModelStates(dir,c); Check(Array.Find(states,s=>s.Id=="medium").Status=="Installed","model states verify actual hashes");
   File.WriteAllText(Path.Combine(dir,"ggml-medium.bin"),"corrupt"); Check(Array.Find(Installation.GetModelStates(dir,c),s=>s.Id=="medium").Status=="Corrupt","corrupt installed model identified");
   Check(engine.AddModelsAsync(dir,new[]{"medium"},c,null,CancellationToken.None).GetAwaiter().GetResult().Success,"corrupt model repaired");
   using(var locked=File.Open(Path.Combine(dir,".ats-modify.lock"),FileMode.Open,FileAccess.ReadWrite,FileShare.None)) {
    Check(!engine.AddModelsAsync(dir,new[]{"base"},c,null,CancellationToken.None).GetAwaiter().GetResult().Success,"overlapping modifications refused");
   }
   var cancelled=new CancellationTokenSource(); cancelled.Cancel(); Check(!engine.AddModelsAsync(dir,new[]{"base"},c,null,cancelled.Token).GetAwaiter().GetResult().Success,"cancelled addition reported");
   Check(!File.Exists(Path.Combine(dir,"ggml-base.bin")),"cancelled model not published");
   File.WriteAllText(Path.Combine(dir,"personal-transcript.txt"),"preserve");
   Check(engine.InstallAsync(new InstallRequest{Directory=dir,ModelIds=new[]{"small"}},c,null,CancellationToken.None).GetAwaiter().GetResult().Success,"rerun setup preserves valid installation");
   Check(File.ReadAllText(Path.Combine(dir,"personal-transcript.txt"))=="preserve","unrelated app-folder file preserved");
   Check(!engine.AddModelsAsync(dir,new[]{"unknown"},c,null,CancellationToken.None).GetAwaiter().GetResult().Success,"unknown model refused");
   string other=Path.Combine(root,"contains unrelated DLL");Directory.CreateDirectory(other);string unrelatedDll=Path.Combine(other,"ggml-base.dll");File.WriteAllText(unrelatedDll,"unrelated personal DLL");
   var collision=engine.InstallAsync(new InstallRequest{Directory=other,ModelIds=new[]{"small"}},c,null,CancellationToken.None).GetAwaiter().GetResult();
   Check(!collision.Success&&File.ReadAllText(unrelatedDll)=="unrelated personal DLL","unowned runtime DLL is never overwritten");
   string identical=Path.Combine(root,"contains matching unowned DLL");Directory.CreateDirectory(identical);string matching=Path.Combine(identical,"ggml-base.dll");
   using(var z=new ZipArchive(new MemoryStream(http.Files[c.Whisper.Url])))using(var input=z.GetEntry("Release/ggml-base.dll").Open())using(var output=File.Create(matching))input.CopyTo(output);
   var same=engine.InstallAsync(new InstallRequest{Directory=identical,ModelIds=new[]{"small"}},c,null,CancellationToken.None).GetAwaiter().GetResult();
   Check(!same.Success&&!InstallationRecord.Read(identical).OwnedFiles.Contains("ggml-base.dll"),"unowned identical runtime DLL is not silently adopted for later deletion");
  }
  TestPublicationSafety();
 }
}
