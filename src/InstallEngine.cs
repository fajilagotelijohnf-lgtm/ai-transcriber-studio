using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Threading;
using System.Threading.Tasks;
namespace AITranscriberInstaller {
 public class InstallRequest { public string Directory; public string[] ModelIds; public bool DesktopShortcut; }
 public class InstallResult { public bool Success; public string Message; public string LogPath; }
 public class ModelState { public string Id; public string Status; public string Path; }
 [DataContract] public class FileDigest {
  [DataMember] public string Path;
  [DataMember] public string Sha256;
 }
 [DataContract] public class InstallationRecord {
  [DataMember] public int SchemaVersion=1;
  [DataMember] public string InstallId;
  [DataMember] public string InstallDirectory;
  [DataMember] public string[] OwnedFiles=new string[0];
  [DataMember] public string[] Shortcuts=new string[0];
  [DataMember] public string[] InstalledModels=new string[0];
  [DataMember] public FileDigest[] FileHashes=new FileDigest[0];
  [DataMember] public string RuntimeVersion;
  [DataMember] public bool Complete;
  public static InstallationRecord Read(string directory) {
   directory=Installation.NormalizeDirectory(directory);
   string file=Installation.SafePath(directory,"installation.json");
   return ReadFile(directory,file);
  }
  internal static InstallationRecord ReadFile(string directory,string file) {
   using(var s=File.OpenRead(file)) {
    var r=(InstallationRecord)new DataContractJsonSerializer(typeof(InstallationRecord)).ReadObject(s);
    Guid id;
    if(r==null || r.SchemaVersion!=1 || !Guid.TryParse(r.InstallId,out id) || !string.Equals(r.InstallDirectory,directory,StringComparison.OrdinalIgnoreCase) || r.OwnedFiles==null || r.FileHashes==null || r.Shortcuts==null || r.InstalledModels==null)
     throw new IOException("This folder does not contain a valid AI Transcriber installation record.");
    var owned=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var digests=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    foreach(string p in r.OwnedFiles)if(!owned.Add(Installation.SafePath(directory,p)))throw new IOException("Duplicate installation ownership entry.");
    foreach(var f in r.FileHashes)if(f==null||string.IsNullOrEmpty(f.Path)||!System.Text.RegularExpressions.Regex.IsMatch(f.Sha256??"",@"\A[a-fA-F0-9]{64}\z")||!owned.Contains(Installation.SafePath(directory,f.Path))||!digests.Add(Installation.SafePath(directory,f.Path)))throw new IOException("Invalid or duplicate installation file digest.");
    return r;
   }
  }
  public void Save() {
   string file=Installation.SafePath(InstallDirectory,"installation.json");
   string temp=Installation.SafePath(InstallDirectory,".ats-record-"+Guid.NewGuid().ToString("N")+".tmp");
   try {
    using(var s=File.Create(temp)){new DataContractJsonSerializer(typeof(InstallationRecord)).WriteObject(s,this);s.Flush(true);}
    if(File.Exists(file)) AtomicFiles.Replace(temp,file,null); else File.Move(temp,file);
   } finally { if(File.Exists(temp)) File.Delete(temp); }
  }
  public void Own(string relative,string hash) {
   if(!OwnedFiles.Contains(relative,StringComparer.OrdinalIgnoreCase)) OwnedFiles=OwnedFiles.Concat(new[]{relative}).ToArray();
   if(hash!=null) FileHashes=FileHashes.Where(f=>!f.Path.Equals(relative,StringComparison.OrdinalIgnoreCase)).Concat(new[]{new FileDigest{Path=relative,Sha256=hash}}).ToArray();
  }
 }
 public partial class Installation {
  readonly Transfers transfers; readonly Action<string> probe; readonly string executable;
  public Installation(Transfers downloads=null,Action<string> runtimeProbe=null,string executablePath=null) { transfers=downloads??new Transfers(); probe=runtimeProbe; executable=executablePath??Assembly.GetExecutingAssembly().Location; }
  public static FileStream ModifyLease(string directory) {
   try { return File.Open(SafePath(directory,".ats-modify.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None); }
   catch(IOException e) { throw new IOException("Another installer or model operation is using this folder. Wait for it to finish, then retry.",e); }
  }
  public static FileStream SessionLease(string directory,bool exclusive) {
   string path=SafePath(directory,".ats-session.lock");
   if(!File.Exists(path)) using(File.Open(path,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.ReadWrite)) {}
   try { return File.Open(path,FileMode.Open,exclusive?FileAccess.ReadWrite:FileAccess.Read,exclusive?FileShare.None:FileShare.Read); }
   catch(IOException e) { throw new IOException("The transcriber is open. Close it before repairing or removing this installation.",e); }
  }
  public Task<InstallResult> InstallAsync(InstallRequest request,Catalog catalog,IProgress<TransferProgress> progress,CancellationToken token) {
   return WorkAsync(request.Directory,request.ModelIds,catalog,progress,token,true);
  }
  public Task<InstallResult> AddModelsAsync(string directory,string[] modelIds,Catalog catalog,IProgress<TransferProgress> progress,CancellationToken token) {
   return WorkAsync(directory,modelIds,catalog,progress,token,false);
  }
  static void Report(IProgress<TransferProgress> p,string text) { if(p!=null) p.Report(new TransferProgress{ArtifactId="Setup",Phase=text}); }
  async Task<InstallResult> WorkAsync(string directory,string[] modelIds,Catalog c,IProgress<TransferProgress> progress,CancellationToken token,bool setup) {
   string stage=null,log=null; InstallationRecord record=null;
   try {
    token.ThrowIfCancellationRequested(); c.Validate(); directory=NormalizeDirectory(directory);
    if(modelIds==null || modelIds.Length==0 || modelIds.Any(id=>!c.Models.Any(m=>m.Id==id))) throw new IOException("Select at least one valid model.");
    var selected=c.Models.Where(m=>modelIds.Contains(m.Id)).ToArray();
    long needed=100L*1024*1024;
    foreach(var m in selected) if(!Transfers.VerifyFile(SafePath(directory,m.FileName),m,token)) needed=checked(needed+m.DownloadBytes);
    if(setup) needed=checked(needed+c.Whisper.DownloadBytes+c.Whisper.ExpandedBytes+c.Ffmpeg.DownloadBytes+c.Ffmpeg.ExpandedBytes+c.VcRuntime.DownloadBytes);
    ValidateDestination(directory,needed);
    using(var lease=ModifyLease(directory))
    using(var session=setup||PublicationTransaction.HasPending(directory)?SessionLease(directory,true):null) {
     PublicationTransaction.Recover(directory);
     string recordFile=SafePath(directory,"installation.json");
     if(File.Exists(recordFile)) record=InstallationRecord.Read(directory);
     else {
      if(!setup) throw new IOException("Install the app in this folder first.");
      foreach(var p in new[]{"AITranscriber.exe","Transcriber-UI.ps1","whisper-cli.exe","ffmpeg.exe",".ats-install.log"})
       if(File.Exists(SafePath(directory,p))) throw new IOException("The destination contains an unrecognized app file: "+p+". Choose a separate app folder.");
      record=new InstallationRecord{InstallId=Guid.NewGuid().ToString(),InstallDirectory=directory};
      foreach(string p in new[]{"installation.json",".ats-modify.lock",".ats-session.lock",".ats-install.log"}) record.Own(p,null);
      record.Save();
     }
     log=SafePath(directory,".ats-install.log"); Log(log,"Starting "+(setup?"setup":"model installation"));
     Log(log,"Version "+c.Version+"; destination: "+directory+"; setup executable: "+executable);
     bool runtimeValid=setup&&RuntimeVerified(directory,record,c);
     Report(progress,"Checking replacement access before downloads");
     Preflight(directory,record,c,selected,setup,runtimeValid,executable,log,token);
     string stageName=".ats-stage-"+Guid.NewGuid().ToString("N"); stage=SafePath(directory,stageName); System.IO.Directory.CreateDirectory(stage);
     using(var transaction=new PublicationTransaction(record)) {
     var stagedModels=new Dictionary<Model,string>();
     foreach(var m in selected) {
      token.ThrowIfCancellationRequested(); string final=SafePath(directory,m.FileName);
      if(Transfers.VerifyFile(final,m,token)) { if(record.OwnedFiles.Contains(m.FileName,StringComparer.OrdinalIgnoreCase))record.Own(m.FileName,m.Hash);continue; }
      if(File.Exists(final)&&!record.OwnedFiles.Contains(m.FileName,StringComparer.OrdinalIgnoreCase))throw new IOException("Refusing to replace a pre-existing model that this installation does not own: "+final+". Choose another app folder or move that model first.");
      Log(log,"Downloading "+m.Id);
      string path=SafePath(stage,m.Id+".part");
      stagedModels[m]=await transfers.FetchAsync(m,path,progress,token).ConfigureAwait(false);
     }
     if(setup) {
      string runtimeVersion=c.Whisper.Id+"/"+c.Ffmpeg.Id+"/utf8-manifest-v1";
      if(!runtimeValid) {
       string whisper=await transfers.FetchAsync(c.Whisper,SafePath(stage,"whisper.part"),progress,token).ConfigureAwait(false);
       string ffmpeg=await transfers.FetchAsync(c.Ffmpeg,SafePath(stage,"ffmpeg.part"),progress,token).ConfigureAwait(false);
       Report(progress,"Extracting verified runtime packages");
       ExtractRuntime(whisper,stage,false,token); ExtractRuntime(ffmpeg,stage,true,token);
       if(probe==null)RuntimeManifest.EnsureUtf8(SafePath(stage,"whisper-cli.exe"));
       if(probe!=null) probe(stage); else await NativeRuntime.EnsureAsync(stage,c,transfers,progress,token).ConfigureAwait(false);
       token.ThrowIfCancellationRequested();
       var runtimeFiles=System.IO.Directory.GetFiles(stage).Where(p=>!p.EndsWith(".part",StringComparison.OrdinalIgnoreCase)&&!p.EndsWith(".exe",StringComparison.OrdinalIgnoreCase)||Path.GetFileName(p)=="whisper-cli.exe"||Path.GetFileName(p)=="ffmpeg.exe").ToArray();
       foreach(string file in runtimeFiles) {
        string name=Path.GetFileName(file);string relative=name.StartsWith("ffmpeg-notice-")?"licenses\\"+name:name;
        PreflightCandidate(directory,record,relative,Payload.HashFile(file),log);
       }
       foreach(string file in runtimeFiles) {
        string name=Path.GetFileName(file); string relative=name.StartsWith("ffmpeg-notice-")?"licenses\\"+name:name;
        Log(log,"Publishing "+relative);Publish(file,relative,record,transaction);
       }
       record.RuntimeVersion=runtimeVersion;
      } else { if(probe!=null) probe(directory); else NativeRuntime.Check(directory); }
      Log(log,"Publishing Transcriber-UI.ps1");WritePayload("Transcriber","Transcriber-UI.ps1",record,stage,transaction);
      if(!Payload.HashFile(SafePath(directory,"Transcriber-UI.ps1")).Equals(c.ScriptSha256,StringComparison.OrdinalIgnoreCase)) throw new IOException("Original transcriber verification failed.");
      string stagedExe=SafePath(stage,"launcher.payload"); File.Copy(executable,stagedExe,true);Log(log,"Publishing AITranscriber.exe");Publish(stagedExe,"AITranscriber.exe",record,transaction);
      Log(log,"Publishing notices/licenses");WritePayload("Notices","THIRD-PARTY-NOTICES.md",record,stage,transaction); WritePayload("WhisperLicense","licenses\\Whisper-LICENSE.txt",record,stage,transaction);
     }
     foreach(var item in stagedModels) { token.ThrowIfCancellationRequested();Log(log,"Publishing "+item.Key.FileName);Publish(item.Value,item.Key.FileName,record,transaction); }
     record.InstalledModels=c.Models.Where(m=>Transfers.VerifyFile(SafePath(directory,m.FileName),m,token)).Select(m=>m.Id).ToArray();
     record.Complete=File.Exists(SafePath(directory,"AITranscriber.exe")) && File.Exists(SafePath(directory,"whisper-cli.exe")); record.Save();
     foreach(var m in selected) if(!record.InstalledModels.Contains(m.Id)) throw new IOException("Installed model verification failed: "+m.Id);
     token.ThrowIfCancellationRequested();Log(log,"Success");transaction.Commit();return new InstallResult{Success=true,Message=setup?"Installation complete.":"Models installed. Close this window to refresh the transcriber when idle.",LogPath=log};
     }
    }
   } catch(Exception e) {
    string message=e is OperationCanceledException?"Cancelled. Your existing models were preserved.":e.Message;
    if(log!=null) try { Log(log,message+Environment.NewLine+e); } catch {}
    return new InstallResult{Success=false,Message=message,LogPath=log};
   } finally {
    if(stage!=null && System.IO.Directory.Exists(stage)) {
     try { RejectReparse(stage); foreach(string file in System.IO.Directory.GetFiles(stage)) { RejectReparse(file); AtomicFiles.DeletePrivate(file); } if(!System.IO.Directory.EnumerateFileSystemEntries(stage).Any()) System.IO.Directory.Delete(stage); }
     catch(IOException) {} catch(UnauthorizedAccessException) {}
    }
   }
  }
  static void Log(string path,string text) { File.AppendAllText(path,DateTime.Now.ToString("s")+" "+text+Environment.NewLine); }
  static bool RuntimeVerified(string directory,InstallationRecord record,Catalog c) {
   if(record.RuntimeVersion!=c.Whisper.Id+"/"+c.Ffmpeg.Id+"/utf8-manifest-v1"||!record.FileHashes.Any(f=>f.Path=="whisper-cli.exe")||!record.FileHashes.Any(f=>f.Path=="ffmpeg.exe"))return false;
   foreach(var f in record.FileHashes.Where(f=>f.Path.EndsWith(".dll",StringComparison.OrdinalIgnoreCase)||f.Path=="whisper-cli.exe"||f.Path=="ffmpeg.exe"))if(Different(SafePath(directory,f.Path),f.Sha256))return false;
   return true;
  }
  static bool Different(string file,string hash) {try{return !File.Exists(file)||!Payload.HashFile(file).Equals(hash,StringComparison.OrdinalIgnoreCase);}catch(IOException){return true;}catch(UnauthorizedAccessException){return true;}}
  static bool RuntimeName(string name) {return new[]{"whisper-cli.exe","ffmpeg.exe","whisper.dll","ggml.dll","ggml-base.dll"}.Contains(name,StringComparer.OrdinalIgnoreCase)||(name.StartsWith("ggml-cpu-",StringComparison.OrdinalIgnoreCase)&&name.EndsWith(".dll",StringComparison.OrdinalIgnoreCase));}
  static void PreflightCandidate(string directory,InstallationRecord record,string relative,string expectedHash,string log) {
   string file=SafePath(directory,relative);
   if(System.IO.Directory.Exists(file))throw new IOException("A folder occupies the app file path: "+file);
   if(!File.Exists(file))return;
   if(!record.OwnedFiles.Contains(relative,StringComparer.OrdinalIgnoreCase))throw new IOException("Refusing to replace an unrelated file: "+file);
   if(expectedHash!=null&&!Different(file,expectedHash))return;
   Log(log,"Checking replacement access: "+file+" ["+File.GetAttributes(file)+"]");AtomicFiles.ProbeReplacement(file);
  }
  static void Preflight(string directory,InstallationRecord record,Catalog c,Model[] selected,bool setup,bool runtimeValid,string executable,string log,CancellationToken token) {
   token.ThrowIfCancellationRequested();
   AtomicFiles.ProbeReplacement(SafePath(directory,"installation.json"));
   foreach(var model in selected)if(!Transfers.VerifyFile(SafePath(directory,model.FileName),model,token))PreflightCandidate(directory,record,model.FileName,null,log);
   if(!setup)return;
   PreflightCandidate(directory,record,"Transcriber-UI.ps1",c.ScriptSha256,log);
   PreflightCandidate(directory,record,"AITranscriber.exe",Payload.HashFile(executable),log);
   using(var stream=Payload.Open("Notices"))PreflightCandidate(directory,record,"THIRD-PARTY-NOTICES.md",Payload.HashStream(stream),log);
   using(var stream=Payload.Open("WhisperLicense"))PreflightCandidate(directory,record,"licenses\\Whisper-LICENSE.txt",Payload.HashStream(stream),log);
   if(!runtimeValid&&record.RuntimeVersion==c.Whisper.Id+"/"+c.Ffmpeg.Id+"/utf8-manifest-v1") {
    // Known corrupt files from this exact pinned runtime can be checked early.
    // Other versions and historical files are uncertain until extraction; check
    // only actual, hash-different archive outputs before publishing those files.
    foreach(var f in record.FileHashes.Where(f=>RuntimeName(f.Path)))if(Different(SafePath(directory,f.Path),f.Sha256))PreflightCandidate(directory,record,f.Path,f.Sha256,log);
   }
  }
  static void WritePayload(string resource,string relative,InstallationRecord record,string stage,PublicationTransaction transaction) {
   string temp=SafePath(stage,"payload-"+Guid.NewGuid().ToString("N")); File.WriteAllBytes(temp,Payload.Bytes(resource)); Publish(temp,relative,record,transaction);
  }
  static void Publish(string source,string relative,InstallationRecord record,PublicationTransaction transaction) {transaction.Publish(source,relative);}
  static void ExtractRuntime(string archive,string stage,bool ffmpeg,CancellationToken token) {
   var extracted=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
   using(var zip=ZipFile.OpenRead(archive)) foreach(var entry in zip.Entries) {
    token.ThrowIfCancellationRequested(); SafePath(stage,entry.FullName.Replace('/',Path.DirectorySeparatorChar));
    string name=entry.Name,output=null;
    if(!ffmpeg && (name=="whisper-cli.exe"||name=="whisper.dll"||name=="ggml.dll"||name=="ggml-base.dll"||(name.StartsWith("ggml-cpu-")&&name.EndsWith(".dll")))) output=name;
    if(ffmpeg && name=="ffmpeg.exe") output=name;
    if(ffmpeg && (name.StartsWith("LICENSE",StringComparison.OrdinalIgnoreCase)||name.StartsWith("README",StringComparison.OrdinalIgnoreCase))) output="ffmpeg-notice-"+name;
    if(output==null) continue;
    if(!extracted.Add(output)) throw new IOException("Duplicate runtime archive entry.");
    string path=SafePath(stage,output); using(var input=entry.Open()) using(var target=File.Create(path)) input.CopyTo(target);
   }
   if(!File.Exists(SafePath(stage,ffmpeg?"ffmpeg.exe":"whisper-cli.exe"))) throw new IOException("The runtime archive does not contain the required executable.");
  }
  public static ModelState[] GetModelStates(string directory,Catalog c) {
   directory=NormalizeDirectory(directory);
   return c.Models.Select(m=>{ string p=SafePath(directory,m.FileName); return new ModelState{Id=m.Id,Path=p,Status=!File.Exists(p)?"Missing":Transfers.VerifyFile(p,m)?"Installed":"Corrupt"}; }).ToArray();
  }
 }
}
