using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using AITranscriberInstaller;
public partial class InstallerTests {
 sealed class BlockedRead : Unseekable {
  public readonly TaskCompletionSource<int> Pending=new TaskCompletionSource<int>();
  public readonly ManualResetEventSlim Started=new ManualResetEventSlim();
  public BlockedRead():base(new byte[0]){}
  public override Task<int> ReadAsync(byte[] b,int o,int n,CancellationToken token){Started.Set();return Pending.Task;}
  protected override void Dispose(bool disposing){Pending.TrySetException(new ObjectDisposedException("blocked response"));base.Dispose(disposing);}
 }
 sealed class BlockedHttp : HttpMessageHandler {
  public readonly BlockedRead Body=new BlockedRead();
  protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r,CancellationToken token){return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StreamContent(Body)});}
 }
 static void TestAudit() {
  string root=Fixture(),part=Path.Combine(root,"blocked.part");var blocked=new BlockedHttp();var cancel=new CancellationTokenSource();
  string deep=Path.Combine(root,new string('d',Math.Max(8,170-root.Length)));
  Throws(()=>Installation.ValidateDestination(deep,1),"overlong installation folder is rejected before staging");
  using(var tr=new Transfers(new HttpClient(blocked))) {
   var task=tr.FetchAsync(TestArtifact(new byte[]{1}),part,null,cancel.Token);
   if(!blocked.Body.Started.Wait(2000))throw new Exception("response read never started");
   cancel.Cancel();bool responsive=SpinWait.SpinUntil(()=>task.IsCompleted,1500);
   blocked.Body.Dispose();try{task.GetAwaiter().GetResult();}catch{}
   Check(responsive&&!File.Exists(part),"cancel interrupts a response stream that ignores cancellation tokens");
  }
  var fake=new FakeHttp{Data=new byte[8*1024*1024]};int reports=0;long last=0;
  using(var tr=new Transfers(new HttpClient(fake)))tr.FetchAsync(TestArtifact(fake.Data),Path.Combine(root,"large.part"),new ReportAction(p=>{if(p.Phase=="Downloading"){reports++;last=p.BytesReceived;}}),CancellationToken.None).GetAwaiter().GetResult();
  Check(reports<10&&last==fake.Data.Length,"download UI notifications throttled with final byte count retained");
  Console.WriteLine("MEASURE 8 MiB fixture: "+reports+" download notifications for 64 buffers; final bytes "+last);
  string dir=Path.Combine(root,"partial");Directory.CreateDirectory(dir);
  var record=new InstallationRecord{InstallId=Guid.NewGuid().ToString(),InstallDirectory=dir};record.Own("installation.json",null);record.Save();
  string unowned=Path.Combine(dir,"AITranscriber.exe");File.WriteAllText(unowned,"unrelated launcher");
  string journal=Path.Combine(dir,".ats-transaction.json");File.WriteAllText(journal,"interrupted transaction");
  Throws(()=>WindowsIntegration.RemoveOwnedFiles(record),"uninstall refuses pending recovery and preserves its backup metadata");
  Throws(()=>WindowsIntegration.LaunchApp(dir),"launch refuses pending recovery");File.Delete(journal);
  WindowsIntegration.RemoveOwnedFiles(record);
  Check(File.Exists(unowned)&&File.ReadAllText(unowned)=="unrelated launcher","removal preserves unowned launcher after a partial install");
  var wait=typeof(NativeRuntime).GetMethod("WaitForPrerequisiteAsync",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static);
  Check(wait!=null,"prerequisite process wait is bounded and cancellable");
  Func<Func<bool>,CancellationToken,TimeSpan,Task> invoke=(exited,token,timeout)=>(Task)wait.Invoke(null,new object[]{exited,token,timeout});
  invoke(()=>true,CancellationToken.None,TimeSpan.FromSeconds(1)).GetAwaiter().GetResult();
  Throws(()=>invoke(()=>false,CancellationToken.None,TimeSpan.FromMilliseconds(60)).GetAwaiter().GetResult(),"stalled prerequisite wait times out");
  using(var cts=new CancellationTokenSource()){cts.CancelAfter(60);Throws(()=>invoke(()=>false,cts.Token,TimeSpan.FromSeconds(2)).GetAwaiter().GetResult(),"prerequisite wait responds to cancellation");}
 }
}
