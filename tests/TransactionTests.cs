using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Collections.Generic;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading;
using AITranscriberInstaller;
public partial class InstallerTests {
 [DataContract] sealed class JournalFixture {
  [DataMember] public int SchemaVersion=1;
  [DataMember] public string TransactionId,InstallId,InstallDirectory,BackupDirectory,RecordSha256;
  [DataMember] public bool Committed=false;
  [DataMember] public JournalEntryFixture[] Entries;
 }
 [DataContract] sealed class JournalEntryFixture {
  [DataMember] public string Path,BackupName,OriginalHash,PublishedHash;
  [DataMember] public bool HadOriginal;
 }
 static InstallResult InstallFixture(Installation engine,string dir,Catalog c) {return engine.InstallAsync(new InstallRequest{Directory=dir,ModelIds=new[]{"small"}},c,null,CancellationToken.None).GetAwaiter().GetResult();}
 static Catalog NextRuntime(RoutingHttp http) {
  var c=FixtureCatalog(http);byte[] archive;
  using(var m=new MemoryStream()) {using(var z=new ZipArchive(m,ZipArchiveMode.Create,true))foreach(string name in new[]{"whisper-cli.exe","whisper.dll","ggml.dll","ggml-base.dll"})using(var w=new StreamWriter(z.CreateEntry(name).Open()))w.Write("version B "+name);archive=m.ToArray();}
  c.Whisper=Route(http,"whisper-B",archive);return c;
 }
 static Dictionary<string,string> Snapshot(string dir) {return InstallationRecord.Read(dir).OwnedFiles.Where(p=>File.Exists(Path.Combine(dir,p))).Where(p=>!p.EndsWith(".lock")&&!p.EndsWith(".log")).ToDictionary(p=>p,p=>Payload.HashFile(Path.Combine(dir,p)));}
 static void AssertSnapshot(string dir,Dictionary<string,string> before,string name) {Check(before.All(p=>File.Exists(Path.Combine(dir,p.Key))&&Payload.HashFile(Path.Combine(dir,p.Key))==p.Value),name);}
 static void TestPublicationSafety() {
  var failures=new List<Exception>();
  foreach(var test in new Action[]{TestLatePublicationRollback,TestLateCollisionRollback,TestUnownedModelPreservation,TestBorrowedModelPreservation,TestPartialJournalRecovery,TestRecoveryFailureRetainsBackups,TestUnsafeJournalRefused,TestJournalBeforeReplacementRecovery,TestInvalidInstallationRecordsRejected})try{test();}catch(Exception e){Console.WriteLine(e.Message);failures.Add(e);}
  if(failures.Count!=0)throw new AggregateException("Publication safety regressions failed",failures);
 }
 static void TestLatePublicationRollback() {
  string dir=Path.Combine(Fixture(),"rollback app");var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http))) {
   Check(InstallFixture(new Installation(tr,p=>{}),dir,c).Success,"rollback fixture installed");var before=Snapshot(dir);var next=NextRuntime(http);string launcher=Path.Combine(Fixture(),"launcher-B.payload");File.WriteAllText(launcher,"version B launcher");
   using(var held=File.Open(Path.Combine(dir,"AITranscriber.exe"),FileMode.Open,FileAccess.Read,FileShare.Read))Check(!InstallFixture(new Installation(tr,p=>{},launcher),dir,next).Success,"late locked launcher rejects repair");
   AssertSnapshot(dir,before,"late publication failure restores every prior file and exact metadata");
  }
 }
 static void TestLateCollisionRollback() {
  string dir=Path.Combine(Fixture(),"collision app");var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http))) {
   Check(InstallFixture(new Installation(tr,p=>{}),dir,c).Success,"late collision fixture installed");var r=InstallationRecord.Read(dir);string license="licenses\\Whisper-LICENSE.txt";r.OwnedFiles=r.OwnedFiles.Where(p=>p!=license).ToArray();r.FileHashes=r.FileHashes.Where(f=>f.Path!=license).ToArray();r.Save();var before=Snapshot(dir);string personal=File.ReadAllText(Path.Combine(dir,license));
   Check(!InstallFixture(new Installation(tr,p=>{}),dir,NextRuntime(http)).Success,"late unowned license collision rejects repair");
   AssertSnapshot(dir,before,"late collision restores previously published runtime and metadata");Check(File.ReadAllText(Path.Combine(dir,license))==personal,"late collision preserves unrelated license");
  }
 }
 static void TestUnownedModelPreservation() {
  string dir=Path.Combine(Fixture(),"custom model app");Directory.CreateDirectory(dir);string file=Path.Combine(dir,"ggml-small.bin");File.WriteAllText(file,"personal custom model");var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http)))Check(!InstallFixture(new Installation(tr,p=>{}),dir,c).Success&&File.ReadAllText(file)=="personal custom model","fresh install refuses replacement of unowned custom model");
 }
 static void TestBorrowedModelPreservation() {
  string dir=Path.Combine(Fixture(),"borrowed model app");Directory.CreateDirectory(dir);var http=new RoutingHttp();var c=FixtureCatalog(http);var model=c.Models.Single(m=>m.Id=="small");File.WriteAllBytes(Path.Combine(dir,model.FileName),http.Files[model.Url]);
  using(var tr=new Transfers(new HttpClient(http)))Check(InstallFixture(new Installation(tr,p=>{}),dir,c).Success,"pre-existing pinned model can be reused");
  var r=InstallationRecord.Read(dir);Check(!r.OwnedFiles.Contains(model.FileName)&&!r.FileHashes.Any(f=>f.Path==model.FileName)&&r.InstalledModels.Contains("small"),"reused pre-existing model is verified without deletion ownership");
  Check(WindowsIntegration.RemoveOwnedFiles(r).Success&&Transfers.VerifyFile(Path.Combine(dir,model.FileName),model),"borrowed model survives uninstall");
 }
 static JournalFixture SimulateInterruptedPublication(string dir) {
  var r=InstallationRecord.Read(dir);string id=Guid.NewGuid().ToString("N");string backup=".ats-backup-"+id;Directory.CreateDirectory(Path.Combine(dir,backup));string record=Path.Combine(dir,"installation.json");File.Copy(record,Path.Combine(dir,backup,"record.json"));string file=Path.Combine(dir,"whisper.dll");File.Copy(file,Path.Combine(dir,backup,"file-0.bin"));string original=Payload.HashFile(file);File.WriteAllText(file,"interrupted version B DLL");
  var j=new JournalFixture{TransactionId=id,InstallId=r.InstallId,InstallDirectory=dir,BackupDirectory=backup,RecordSha256=Payload.HashFile(record),Entries=new[]{new JournalEntryFixture{Path="whisper.dll",BackupName="file-0.bin",HadOriginal=true,OriginalHash=original,PublishedHash=Payload.HashFile(file)}}};SaveJournal(dir,j);r.Complete=false;r.Save();return j;
 }
 static void SaveJournal(string dir,JournalFixture journal) {using(var s=File.Create(Path.Combine(dir,".ats-transaction.json")))new DataContractJsonSerializer(typeof(JournalFixture)).WriteObject(s,journal);}
 static void TestPartialJournalRecovery() {
  string dir=Path.Combine(Fixture(),"recover app");var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http))) {
   var engine=new Installation(tr,p=>{});Check(InstallFixture(engine,dir,c).Success,"recovery fixture installed");string original=Payload.HashFile(Path.Combine(dir,"whisper.dll"));var j=SimulateInterruptedPublication(dir);
   Check(engine.AddModelsAsync(dir,new[]{"small"},c,null,CancellationToken.None).GetAwaiter().GetResult().Success,"retry recovers interrupted publication");
   Check(Payload.HashFile(Path.Combine(dir,"whisper.dll"))==original&&InstallationRecord.Read(dir).Complete,"retry restores original runtime and manifest before working");Check(!File.Exists(Path.Combine(dir,".ats-transaction.json"))&&!Directory.Exists(Path.Combine(dir,j.BackupDirectory)),"successful recovery removes journal and backups");
  }
 }
 static void TestRecoveryFailureRetainsBackups() {
  string dir=Path.Combine(Fixture(),"locked recovery app");var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http))) {
   var engine=new Installation(tr,p=>{});Check(InstallFixture(engine,dir,c).Success,"locked recovery fixture installed");var j=SimulateInterruptedPublication(dir);
   using(var held=File.Open(Path.Combine(dir,"whisper.dll"),FileMode.Open,FileAccess.Read,FileShare.Read))Check(!engine.AddModelsAsync(dir,new[]{"small"},c,null,CancellationToken.None).GetAwaiter().GetResult().Success,"locked recovery refuses further changes");
   Check(File.Exists(Path.Combine(dir,".ats-transaction.json"))&&File.Exists(Path.Combine(dir,j.BackupDirectory,"file-0.bin")),"failed recovery preserves validated journal and backups");
   Check(engine.AddModelsAsync(dir,new[]{"small"},c,null,CancellationToken.None).GetAwaiter().GetResult().Success,"recovery retries after locked file is released");
  }
 }
 static void TestUnsafeJournalRefused() {
  string dir=Path.Combine(Fixture(),"unsafe recovery app");var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http))) {
   var engine=new Installation(tr,p=>{});Check(InstallFixture(engine,dir,c).Success,"unsafe recovery fixture installed");var j=SimulateInterruptedPublication(dir);j.Entries[0].Path="..\\outside.txt";SaveJournal(dir,j);string current=Payload.HashFile(Path.Combine(dir,"whisper.dll"));
   Check(!engine.AddModelsAsync(dir,new[]{"small"},c,null,CancellationToken.None).GetAwaiter().GetResult().Success,"unsafe journal path is refused");Check(Payload.HashFile(Path.Combine(dir,"whisper.dll"))==current&&File.Exists(Path.Combine(dir,j.BackupDirectory,"file-0.bin")),"journal validation precedes any recovery mutation");
  }
 }
 static void TestJournalBeforeReplacementRecovery() {
  string dir=Path.Combine(Fixture(),"journal before replace app");var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http))) {
   var engine=new Installation(tr,p=>{});Check(InstallFixture(engine,dir,c).Success,"pre-replacement recovery fixture installed");var j=SimulateInterruptedPublication(dir);string backup=Path.Combine(dir,j.BackupDirectory,"file-0.bin");File.Copy(backup,Path.Combine(dir,"whisper.dll"),true);File.Delete(backup);
   Check(engine.AddModelsAsync(dir,new[]{"small"},c,null,CancellationToken.None).GetAwaiter().GetResult().Success,"journal persisted before atomic replacement recovers without a not-yet-created backup");
   Check(InstallationRecord.Read(dir).Complete&&!File.Exists(Path.Combine(dir,".ats-transaction.json")),"pre-replacement recovery restores metadata and cleans journal");
  }
 }
 static void TestInvalidInstallationRecordsRejected() {
  string dir=Path.Combine(Fixture(),"invalid record app");var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new HttpClient(http)))Check(InstallFixture(new Installation(tr,p=>{}),dir,c).Success,"invalid record fixture installed");
  byte[] original=File.ReadAllBytes(Path.Combine(dir,"installation.json"));
  var cases=new Action<InstallationRecord>[]{r=>r.OwnedFiles=r.OwnedFiles.Concat(new[]{r.OwnedFiles[0].ToUpperInvariant()}).ToArray(),r=>r.FileHashes=r.FileHashes.Concat(new[]{r.FileHashes[0]}).ToArray(),r=>r.FileHashes[0].Sha256="invalid digest",r=>r.FileHashes[0]=null,r=>r.InstalledModels=null};
  var failures=new List<Exception>();
  foreach(var mutate in cases){File.WriteAllBytes(Path.Combine(dir,"installation.json"),original);var r=InstallationRecord.Read(dir);mutate(r);r.Save();bool refused=false;try{InstallationRecord.Read(dir);}catch(IOException){refused=true;}catch(Exception e){failures.Add(e);}if(!refused)failures.Add(new Exception("Malformed ownership/digest record accepted or not reported as IOException."));}
  File.WriteAllBytes(Path.Combine(dir,"installation.json"),original);Check(failures.Count==0,"record reader rejects duplicate ownership/digests, malformed hashes, null digests and missing model metadata");
 }
}
