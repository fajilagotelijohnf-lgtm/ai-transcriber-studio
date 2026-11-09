using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Security.Cryptography;
namespace AITranscriberInstaller {
 public class TransferProgress {
  public string ArtifactId; public long BytesReceived; public long? TotalBytes; public string Phase;
 }
 public sealed class Transfers : IDisposable {
  readonly HttpClient client; readonly bool owns;
  public Transfers(HttpClient http=null) {
   ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
   owns=http==null; client=http??new HttpClient(new HttpClientHandler{AllowAutoRedirect=true});
   if(owns) { client.Timeout=Timeout.InfiniteTimeSpan; client.DefaultRequestHeaders.UserAgent.ParseAdd("AITranscriberStudio-Setup/1.0"); }
  }
  public static bool VerifyFile(string path,Artifact item) {
   return VerifyFile(path,item,CancellationToken.None);
  }
  public static bool VerifyFile(string path,Artifact item,CancellationToken token) {
   token.ThrowIfCancellationRequested();
   try {
    if(!File.Exists(path)||new FileInfo(path).Length!=item.DownloadBytes)return false;
    using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,1048576,FileOptions.SequentialScan))
    using(var hash=SHA256.Create()) {
     var buffer=new byte[1048576];int count;
     while((count=file.Read(buffer,0,buffer.Length))>0){token.ThrowIfCancellationRequested();hash.TransformBlock(buffer,0,count,buffer,0);}
     token.ThrowIfCancellationRequested();hash.TransformFinalBlock(buffer,0,0);
     return BitConverter.ToString(hash.Hash).Replace("-","").Equals(item.Hash,StringComparison.OrdinalIgnoreCase);
    }
   }
   catch(IOException) { return false; }
   catch(UnauthorizedAccessException) { return false; }
  }
  public async Task<string> FetchAsync(Artifact item,string stagingFile,IProgress<TransferProgress> progress,CancellationToken token) {
   if(!stagingFile.EndsWith(".part",StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Downloads must use a staging .part file.");
   if(new Uri(item.Url).Scheme!="https") throw new InvalidOperationException("HTTPS downloads are required.");
   token.ThrowIfCancellationRequested();
   if(VerifyFile(stagingFile,item,token)) return stagingFile;
   Directory.CreateDirectory(Path.GetDirectoryName(stagingFile));
   try {
    using(var timeout=CancellationTokenSource.CreateLinkedTokenSource(token)) {
     timeout.CancelAfter(TimeSpan.FromSeconds(90));
     using(var response=await client.GetAsync(item.Url,HttpCompletionOption.ResponseHeadersRead,timeout.Token).ConfigureAwait(false)) {
      response.EnsureSuccessStatusCode();
      if(response.RequestMessage!=null && response.RequestMessage.RequestUri.Scheme!="https") throw new IOException("An insecure download redirect was refused.");
      long? serverLength=response.Content.Headers.ContentLength;
      if(serverLength.HasValue && serverLength.Value!=item.DownloadBytes) throw new IOException("Download size differs from the pinned version. Please retry or obtain an updated setup.");
      using(var input=await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
      using(timeout.Token.Register(()=>{try{input.Dispose();}catch{}}))
      using(var output=new FileStream(stagingFile,FileMode.Create,FileAccess.Write,FileShare.None,131072,true)) {
       byte[] buffer=new byte[131072]; long total=0,lastReport=0;var clock=Stopwatch.StartNew();
       for(;;) {
        timeout.CancelAfter(TimeSpan.FromSeconds(90));
        int n;
        try{n=await input.ReadAsync(buffer,0,buffer.Length,timeout.Token).ConfigureAwait(false);}
        catch(Exception){if(timeout.IsCancellationRequested)throw new OperationCanceledException(timeout.Token);throw;}
        if(n==0) break;
        total+=n; if(total>item.DownloadBytes) throw new IOException("Download exceeds its expected size.");
        await output.WriteAsync(buffer,0,n,timeout.Token).ConfigureAwait(false);
        if(progress!=null&&(lastReport==0||clock.ElapsedMilliseconds>=100||total==item.DownloadBytes)) {
         progress.Report(new TransferProgress{ArtifactId=item.Id,BytesReceived=total,TotalBytes=serverLength,Phase="Downloading"});lastReport=total;clock.Restart();
        }
       }
      }
     }
    }
    token.ThrowIfCancellationRequested();
    if(progress!=null) progress.Report(new TransferProgress{ArtifactId=item.Id,Phase="Verifying SHA-256"});
    bool valid=await Task.Run(()=>VerifyFile(stagingFile,item,token),token).ConfigureAwait(false);
    token.ThrowIfCancellationRequested();
    if(!valid) throw new IOException("SHA-256 verification failed for "+item.Id+". Retry the download.");
    return stagingFile;
   } catch(OperationCanceledException) {
    DeletePart(stagingFile); if(!token.IsCancellationRequested) throw new IOException("The download timed out. Check your connection and retry."); throw;
   } catch { DeletePart(stagingFile); throw; }
  }
  static void DeletePart(string path) { try { File.Delete(path); } catch(IOException) {} catch(UnauthorizedAccessException) {} }
  public void Dispose() { if(owns) client.Dispose(); }
 }
}
