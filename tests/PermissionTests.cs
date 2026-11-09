using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Collections.Generic;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using AITranscriberInstaller;
public partial class InstallerTests {
 static void TestPermissions() {
  var failures=new List<Exception>();
  foreach(var test in new Action[]{TestReadOnlyOwnedReplacement,TestReadOnlyStagedReplacement,TestReadOnlyFailedReplacement,TestReadOnlyRollback,TestReadOnlyInstallationRecord,TestReadOnlyBeforeReplacementRecovery,TestLockedPublicationDiagnostic,TestLockedRepairPreflight,TestUnchangedLockedRuntimeRepair})
   try{test();}catch(Exception e){Console.WriteLine(e);failures.Add(e);}
  if(failures.Count!=0)throw new AggregateException("Publication permission regressions failed",failures);
 }
 static InstallationRecord PermissionRecord(string dir,params string[] owned) {
  Directory.CreateDirectory(dir);var record=new InstallationRecord{InstallId=Guid.NewGuid().ToString(),InstallDirectory=dir,Complete=true};record.Own("installation.json",null);
  foreach(string name in owned){string path=Path.Combine(dir,name);File.WriteAllText(path,"original "+name);record.Own(name,Payload.HashFile(path));}
  record.Save();return record;
 }
 static void PermissionReadOnly(string path,bool enabled) {if(File.Exists(path)){var attributes=File.GetAttributes(path);File.SetAttributes(path,enabled?attributes|FileAttributes.ReadOnly:attributes&~FileAttributes.ReadOnly);}}
 static bool PermissionIsReadOnly(string path) {return (File.GetAttributes(path)&FileAttributes.ReadOnly)!=0;}
 static string PermissionSource(string dir,string name,string content) {string path=Path.Combine(dir,name);File.WriteAllText(path,content);return path;}
 static void TestReadOnlyOwnedReplacement() {
  string dir=Path.Combine(Fixture(),"readonly owned app");var record=PermissionRecord(dir,"whisper.dll");string dest=Path.Combine(dir,"whisper.dll"),source=PermissionSource(dir,"replacement.payload","replacement runtime");PermissionReadOnly(dest,true);
  try {
   using(var transaction=new PublicationTransaction(record)){transaction.Publish(source,"whisper.dll");record.Save();transaction.Commit();}
   Check(File.ReadAllText(dest)=="replacement runtime","owned read-only runtime is atomically replaced");
   Check(PermissionIsReadOnly(dest),"successful replacement preserves original destination read-only flag");
   Check(!File.Exists(Path.Combine(dir,".ats-transaction.json"))&&!Directory.GetDirectories(dir,".ats-backup-*").Any(),"read-only replacement cleans its journal and backups");
  } finally {PermissionReadOnly(dest,false);PermissionReadOnly(source,false);}
 }
 static void TestReadOnlyStagedReplacement() {
  string dir=Path.Combine(Fixture(),"readonly staged app");var record=PermissionRecord(dir,"whisper.dll");string dest=Path.Combine(dir,"whisper.dll"),source=PermissionSource(dir,"replacement.payload","read-only staged runtime");PermissionReadOnly(source,true);
  try {
   using(var transaction=new PublicationTransaction(record)){transaction.Publish(source,"whisper.dll");record.Save();transaction.Commit();}
   Check(File.ReadAllText(dest)=="read-only staged runtime"&&!File.Exists(source),"read-only staged runtime can replace an owned runtime");
   Check(!Directory.GetDirectories(dir,".ats-backup-*").Any(),"read-only staged replacement leaves no recovery backup");
  } finally {PermissionReadOnly(dest,false);PermissionReadOnly(source,false);}
 }
 static void TestReadOnlyFailedReplacement() {
  string dir=Path.Combine(Fixture(),"failed readonly staged app");var record=PermissionRecord(dir,"whisper.dll");string dest=Path.Combine(dir,"whisper.dll"),source=PermissionSource(dir,"replacement.payload","locked replacement runtime");PermissionReadOnly(source,true);PermissionReadOnly(dest,true);Exception failure=null;
  try {
   using(var transaction=new PublicationTransaction(record)) {
    using(var held=File.Open(dest,FileMode.Open,FileAccess.Read,FileShare.Read))try{transaction.Publish(source,"whisper.dll");}catch(Exception e){failure=e;}
    Check(failure!=null,"locked destination refuses read-only staged replacement");
    Check(File.Exists(source)&&PermissionIsReadOnly(source),"failed publication restores staged source read-only flag");
    Check(File.ReadAllText(dest)=="original whisper.dll"&&PermissionIsReadOnly(dest),"failed publication preserves destination bytes and read-only flag");
   }
   Check(!File.Exists(Path.Combine(dir,".ats-transaction.json")),"failed read-only publication remains recoverable without a replacement backup");
  } finally {PermissionReadOnly(dest,false);PermissionReadOnly(source,false);}
 }
 static void TestReadOnlyRollback() {
  string dir=Path.Combine(Fixture(),"readonly rollback app");var record=PermissionRecord(dir,"whisper.dll","ggml.dll");string first=Path.Combine(dir,"whisper.dll"),second=Path.Combine(dir,"ggml.dll");PermissionReadOnly(first,true);var before=Snapshot(dir);string firstSource=PermissionSource(dir,"first.payload","new whisper runtime"),secondSource=PermissionSource(dir,"second.payload","new ggml runtime");bool published=false;Exception failure=null;
  try {
   try {
    using(var transaction=new PublicationTransaction(record)) {
     transaction.Publish(firstSource,"whisper.dll");published=File.ReadAllText(first)=="new whisper runtime";
     // The lock is deliberately acquired after the first publication, so rollback
     // is exercised even when installation preflight rejects known locks early.
     using(var held=File.Open(second,FileMode.Open,FileAccess.Read,FileShare.Read))transaction.Publish(secondSource,"ggml.dll");
     transaction.Commit();
    }
   } catch(Exception e){failure=e;}
   Check(published&&failure!=null,"later locked publication fails after replacing a read-only runtime");
   AssertSnapshot(dir,before,"rollback restores original runtime content and installation record");
   Check(PermissionIsReadOnly(first)&&!PermissionIsReadOnly(second),"rollback restores original read-only flags for replaced and failed destinations");
   Check(!File.Exists(Path.Combine(dir,".ats-transaction.json"))&&!Directory.GetDirectories(dir,".ats-backup-*").Any(),"read-only rollback removes completed recovery journal and backups");
  } finally {PermissionReadOnly(first,false);PermissionReadOnly(second,false);}
 }
 static void TestLockedPublicationDiagnostic() {
  foreach(bool lockSource in new[]{false,true}) {
   string dir=Path.Combine(Fixture(),lockSource?"locked source app":"locked destination app");var record=PermissionRecord(dir,"whisper.dll");string dest=Path.Combine(dir,"whisper.dll"),source=PermissionSource(dir,"replacement.payload","diagnostic replacement");Exception failure=null;
   using(var transaction=new PublicationTransaction(record)) {
    using(var held=File.Open(lockSource?source:dest,FileMode.Open,FileAccess.Read,FileShare.Read))try{transaction.Publish(source,"whisper.dll");}catch(Exception e){failure=e;}
    string message=failure==null?"":failure.Message;
    Check(failure!=null&&message.IndexOf(source,StringComparison.OrdinalIgnoreCase)>=0&&message.IndexOf(dest,StringComparison.OrdinalIgnoreCase)>=0,"locked "+(lockSource?"source":"destination")+" diagnostic names both exact publication paths");
    Check(message.IndexOf("0x80070020",StringComparison.OrdinalIgnoreCase)>=0,"locked "+(lockSource?"source":"destination")+" diagnostic retains Windows sharing-violation HRESULT");
   }
  }
 }
 static void TestReadOnlyInstallationRecord() {
  string dir=Path.Combine(Fixture(),"readonly installation record app");var record=PermissionRecord(dir,"whisper.dll");string file=Path.Combine(dir,"installation.json");PermissionReadOnly(file,true);
  try {
   record.RuntimeVersion="updated runtime version";record.Save();
   Check(InstallationRecord.Read(dir).RuntimeVersion=="updated runtime version"&&PermissionIsReadOnly(file),"atomic record save replaces a read-only installation record and preserves its flag");
   string source=PermissionSource(dir,"replacement.payload","updated readonly record runtime");
   using(var transaction=new PublicationTransaction(record)){transaction.Publish(source,"whisper.dll");record.RuntimeVersion="committed runtime version";record.Save();transaction.Commit();}
   Check(InstallationRecord.Read(dir).RuntimeVersion=="committed runtime version"&&PermissionIsReadOnly(file),"read-only installation record can be backed up and committed");
   Check(!Directory.GetDirectories(dir,".ats-backup-*").Any(),"read-only installation record backup is cleaned after commit");
   string before=Payload.HashFile(file);source=PermissionSource(dir,"rollback.payload","uncommitted readonly record runtime");
   using(var transaction=new PublicationTransaction(record)){transaction.Publish(source,"whisper.dll");record.RuntimeVersion="uncommitted runtime version";record.Save();}
   Check(Payload.HashFile(file)==before&&PermissionIsReadOnly(file),"rollback restores exact installation record bytes and its read-only flag");
  } finally {PermissionReadOnly(file,false);}
 }
 [DataContract] sealed class PermissionJournalFixture {
  [DataMember] public int SchemaVersion=1;
  [DataMember] public string TransactionId,InstallId,InstallDirectory,BackupDirectory,RecordSha256;
  [DataMember] public bool Committed=false;
  [DataMember(EmitDefaultValue=false)] public int? OriginalRecordAttributes;
  [DataMember] public PermissionEntryFixture[] Entries;
 }
 [DataContract] sealed class PermissionEntryFixture {
  [DataMember] public string Path,BackupName,OriginalHash,PublishedHash;
  [DataMember] public bool HadOriginal=true;
  [DataMember(EmitDefaultValue=false)] public int? OriginalAttributes;
 }
 static void TestReadOnlyBeforeReplacementRecovery() {
  string dir=Path.Combine(Fixture(),"readonly pre-replacement recovery app");var record=PermissionRecord(dir,"whisper.dll");string dest=Path.Combine(dir,"whisper.dll"),recordFile=Path.Combine(dir,"installation.json");PermissionReadOnly(dest,true);PermissionReadOnly(recordFile,true);
  string id=Guid.NewGuid().ToString("N"),backupName=".ats-backup-"+id,backup=Path.Combine(dir,backupName);Directory.CreateDirectory(backup);File.Copy(recordFile,Path.Combine(backup,"record.json"));string source=PermissionSource(dir,"replacement.payload","runtime not yet published");
  var journal=new PermissionJournalFixture{TransactionId=id,InstallId=record.InstallId,InstallDirectory=dir,BackupDirectory=backupName,RecordSha256=Payload.HashFile(recordFile),OriginalRecordAttributes=(int)File.GetAttributes(recordFile),Entries=new[]{new PermissionEntryFixture{Path="whisper.dll",BackupName="file-0.bin",OriginalHash=Payload.HashFile(dest),PublishedHash=Payload.HashFile(source),OriginalAttributes=(int)File.GetAttributes(dest)}}};
  // Emulate termination after the durable journal and attribute normalization,
  // before File.Replace has moved the original into its backup path.
  PermissionReadOnly(dest,false);PermissionReadOnly(recordFile,false);
  using(var stream=File.Create(Path.Combine(dir,".ats-transaction.json")))new DataContractJsonSerializer(typeof(PermissionJournalFixture)).WriteObject(stream,journal);
  try {
   PublicationTransaction.Recover(dir);
   Check(File.ReadAllText(dest)=="original whisper.dll"&&PermissionIsReadOnly(dest),"pre-replacement crash recovery restores original read-only flag without a file backup");
   Check(PermissionIsReadOnly(recordFile)&&Payload.HashFile(recordFile)==journal.RecordSha256,"pre-replacement crash recovery restores read-only installation record attributes even when bytes match");
   Check(!File.Exists(Path.Combine(dir,".ats-transaction.json"))&&!Directory.Exists(backup),"pre-replacement read-only recovery cleans journal and backups");
  } finally {PermissionReadOnly(dest,false);PermissionReadOnly(recordFile,false);PermissionReadOnly(Path.Combine(backup,"record.json"),false);}
 }
 static void TestLockedRepairPreflight() {
  foreach(string relative in new[]{"whisper.dll","AITranscriber.exe","ggml-small.bin"}) {
   string dir=Path.Combine(Fixture(),"preflight "+Path.GetFileNameWithoutExtension(relative));var http=new RoutingHttp();var catalog=FixtureCatalog(http);
   using(var transfers=new Transfers(new HttpClient(http))) {
    var engine=new Installation(transfers,p=>{});Check(InstallFixture(engine,dir,catalog).Success,"locked "+relative+" preflight fixture installed");string dest=Path.Combine(dir,relative);
    if(relative=="whisper.dll")File.WriteAllText(dest,"corrupt runtime requiring replacement");
    if(relative=="ggml-small.bin")File.WriteAllText(dest,"corrupt model requiring download");
    if(relative=="AITranscriber.exe")engine=new Installation(transfers,p=>{},PermissionSource(dir,"new-launcher.payload","new version launcher requiring replacement"));
    int calls=http.Calls;InstallResult result;
    using(var held=File.Open(dest,FileMode.Open,FileAccess.Read,FileShare.Read))result=InstallFixture(engine,dir,catalog);
    Check(!result.Success&&http.Calls==calls,"known locked owned "+relative+" fails before any HTTP request");
    Check(result.Message.IndexOf(dest,StringComparison.OrdinalIgnoreCase)>=0&&result.Message.IndexOf("0x80070020",StringComparison.OrdinalIgnoreCase)>=0,"preflight failure names locked "+relative+" and Windows HRESULT");
    Check(!File.Exists(Path.Combine(dir,".ats-transaction.json")),"preflight failure creates no publication recovery journal for "+relative);
   }
  }
 }
 static void TestUnchangedLockedRuntimeRepair() {
  foreach(string relative in new[]{"ggml.dll","ggml-cpu-retired.dll"}) {
   string dir=Path.Combine(Fixture(),relative=="ggml.dll"?"locked core":"locked legacy");var http=new RoutingHttp();var catalog=FixtureCatalog(http);
   using(var transfers=new Transfers(new HttpClient(http))) {
    var engine=new Installation(transfers,p=>{});Check(InstallFixture(engine,dir,catalog).Success,"unchanged locked "+relative+" repair fixture installed");string unchanged=Path.Combine(dir,relative);
    if(relative=="ggml-cpu-retired.dll") {
     File.WriteAllText(unchanged,"owned runtime from an older package");var record=InstallationRecord.Read(dir);record.Own(relative,Payload.HashFile(unchanged));record.Save();
    }
    string hash=Payload.HashFile(unchanged),runtime=Path.Combine(dir,"whisper.dll"),runtimeHash=Payload.HashFile(runtime);File.WriteAllText(runtime,"corrupt runtime requiring same-version repair");InstallResult result;
    using(var held=File.Open(unchanged,FileMode.Open,FileAccess.Read,FileShare.Read))result=InstallFixture(engine,dir,catalog);
    Check(result.Success,"same-version repair succeeds while unchanged owned "+relative+" is locked: "+result.Message);
    Check(Payload.HashFile(unchanged)==hash&&Payload.HashFile(runtime)==runtimeHash,"repair preserves unchanged locked "+relative+" and restores corrupt runtime");
   }
  }
 }
}
