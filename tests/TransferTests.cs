using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using AITranscriberInstaller;
public partial class InstallerTests {
 public static string Fixture() { string p=Path.Combine(Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"..","test-results")),"fixture-"+Guid.NewGuid().ToString("N")); Directory.CreateDirectory(p); return p; }
 public static void Throws(Action a,string name) { bool threw=false; try { a(); } catch { threw=true; } Check(threw,name); }
 public class FakeHttp : HttpMessageHandler {
  public byte[] Data=new byte[]{1,2,3,4}; public int Calls; public bool Fail; public bool UnknownLength;public bool Disconnect;
  protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r,CancellationToken t) {
   t.ThrowIfCancellationRequested(); Calls++;
   var response=new HttpResponseMessage(Fail?HttpStatusCode.ServiceUnavailable:HttpStatusCode.OK);
   response.Content=Disconnect?(HttpContent)new StreamContent(new Disconnecting(Data)):UnknownLength?(HttpContent)new StreamContent(new Unseekable(Data)):new ByteArrayContent(Data);
   return Task.FromResult(response);
  }
 }
 public class Unseekable : Stream {
  readonly MemoryStream data;public Unseekable(byte[] bytes){data=new MemoryStream(bytes);}public override bool CanRead{get{return true;}}public override bool CanSeek{get{return false;}}public override bool CanWrite{get{return false;}}public override long Length{get{throw new NotSupportedException();}}public override long Position{get{throw new NotSupportedException();}set{throw new NotSupportedException();}}public override int Read(byte[] b,int o,int n){return data.Read(b,o,n);}public override void Flush(){}public override long Seek(long o,SeekOrigin s){throw new NotSupportedException();}public override void SetLength(long n){throw new NotSupportedException();}public override void Write(byte[] b,int o,int n){throw new NotSupportedException();}protected override void Dispose(bool disposing){if(disposing)data.Dispose();base.Dispose(disposing);}
 }
 public sealed class Disconnecting : Unseekable {int reads;public Disconnecting(byte[] b):base(b){}public override int Read(byte[] b,int o,int n){if(reads++>0)throw new IOException("Simulated connection reset after bytes were delivered");return base.Read(b,o,n);}}
 public sealed class ReportAction : IProgress<TransferProgress> {readonly Action<TransferProgress> action;public ReportAction(Action<TransferProgress> a){action=a;}public void Report(TransferProgress p){action(p);}}
 public static Artifact TestArtifact(byte[] data) { string hash; using(var m=new MemoryStream(data)) hash=Payload.HashStream(m); return new Artifact{Id="fixture",Url="https://fixture.invalid/payload",HashAlgorithm="SHA256",Hash=hash,DownloadBytes=data.Length,ExpandedBytes=data.Length}; }
 static void TestTransfersAndPaths() {
  var root=Fixture(); var fake=new FakeHttp(); var a=TestArtifact(fake.Data); string p=Path.Combine(root,"model.part");
  using(var transfers=new Transfers(new HttpClient(fake))) {
   transfers.FetchAsync(a,p,null,CancellationToken.None).GetAwaiter().GetResult();
   Check(Transfers.VerifyFile(p,a),"verified download");
   int calls=fake.Calls; transfers.FetchAsync(a,p,null,CancellationToken.None).GetAwaiter().GetResult(); Check(fake.Calls==calls,"valid cache reused");
   File.Delete(p); fake.Fail=true; Throws(()=>transfers.FetchAsync(a,p,null,CancellationToken.None).GetAwaiter().GetResult(),"HTTP failure surfaced"); Check(!File.Exists(p),"failure removes partial");
   bool sawUnknown=false;fake.Fail=false; fake.UnknownLength=true; transfers.FetchAsync(a,p,new ReportAction(pr=>{if(pr.Phase=="Downloading"&&!pr.TotalBytes.HasValue)sawUnknown=true;}),CancellationToken.None).GetAwaiter().GetResult(); Check(Transfers.VerifyFile(p,a)&&sawUnknown,"retry and genuinely unknown Content-Length");
   File.Delete(p); fake.Data=new byte[]{8,9}; Throws(()=>transfers.FetchAsync(a,p,null,CancellationToken.None).GetAwaiter().GetResult(),"truncated or corrupt transfer rejected"); Check(!File.Exists(p),"corrupt partial not published");
   fake.Data=new byte[]{4,3,2,1}; Throws(()=>transfers.FetchAsync(a,p,null,CancellationToken.None).GetAwaiter().GetResult(),"same-size wrong digest rejected");
   var cts=new CancellationTokenSource(); cts.Cancel(); Throws(()=>transfers.FetchAsync(a,p,null,cts.Token).GetAwaiter().GetResult(),"cancel respected");
   string final=Path.Combine(root,"ggml-small.bin"); File.WriteAllText(final,"working"); Throws(()=>transfers.FetchAsync(a,final,null,CancellationToken.None).GetAwaiter().GetResult(),"refuse download to final model filename"); Check(File.ReadAllText(final)=="working","existing final model preserved");
   fake.UnknownLength=false;fake.Data=new byte[800000];var big=TestArtifact(fake.Data);var midCancel=new CancellationTokenSource();bool began=false;
   Throws(()=>transfers.FetchAsync(big,p,new ReportAction(pr=>{if(pr.BytesReceived>0){began=true;midCancel.Cancel();}}),midCancel.Token).GetAwaiter().GetResult(),"mid-stream cancellation surfaced");
   Check(began&&!File.Exists(p)&&File.ReadAllText(final)=="working","in-flight cancel removes partial and preserves final model");
   fake.Disconnect=true;bool received=false;Throws(()=>transfers.FetchAsync(big,p,new ReportAction(pr=>{if(pr.BytesReceived>0)received=true;}),CancellationToken.None).GetAwaiter().GetResult(),"connection reset after bytes written surfaced");
   Check(received&&!File.Exists(p)&&File.ReadAllText(final)=="working","disconnection cleans partial and preserves existing model");
   fake.Disconnect=false;transfers.FetchAsync(big,p,null,CancellationToken.None).GetAwaiter().GetResult();Check(Transfers.VerifyFile(p,big),"retry after mid-stream disconnect succeeds");
  }
  string unicode=Path.Combine(root,"folder with spaces","日本語");
  Check(Installation.NormalizeDirectory(unicode+Path.DirectorySeparatorChar)==unicode,"Unicode path and trailing slash normalized");
  Installation.ValidateDestination(unicode,1); Check(Directory.Exists(unicode),"writable chosen folder accepted");
  Throws(()=>Installation.NormalizeDirectory(Path.GetPathRoot(root)),"filesystem root rejected");
  Throws(()=>Installation.ValidateDestination(unicode,long.MaxValue),"insufficient space rejected");
  Throws(()=>Installation.SafePath(root,"..\\escape"),"parent traversal rejected");
  Throws(()=>Installation.SafePath(root,Path.GetPathRoot(root)),"rooted owned path rejected");
 }
}
