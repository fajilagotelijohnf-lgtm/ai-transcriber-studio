using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text.RegularExpressions;
namespace AITranscriberInstaller {
 [DataContract] internal sealed class PublicationJournal {
  [DataMember] public int SchemaVersion=1;
  [DataMember] public string TransactionId,InstallId,InstallDirectory,BackupDirectory,RecordSha256;
  [DataMember] public bool Committed;
  [DataMember] public PublicationEntry[] Entries=new PublicationEntry[0];
  [DataMember(EmitDefaultValue=false)] public int? OriginalRecordAttributes;
 }
 [DataContract] internal sealed class PublicationEntry {
  [DataMember] public string Path,BackupName,OriginalHash,PublishedHash;
  [DataMember] public bool HadOriginal;
  [DataMember(EmitDefaultValue=false)] public int? OriginalAttributes;
 }
 // Callers hold the modify lease, and an exclusive session lease when repairing
 // runtime files or recovering an interrupted transaction. Backups are never
 // consumed during rollback: a failed recovery remains safely retryable.
 internal sealed class PublicationTransaction : IDisposable {
  const string JournalName=".ats-transaction.json";
  readonly InstallationRecord record; readonly PublicationJournal journal;
  bool finished;
  static bool Hash(string value) {return Regex.IsMatch(value??"","^[a-fA-F0-9]{64}$");}
  static string PathFor(string directory,string relative) {return Installation.SafePath(directory,relative);}
  static string BackupPath(PublicationJournal j,string name) {return PathFor(j.InstallDirectory,j.BackupDirectory+"\\"+name);}
  static bool Allowed(string relative) {
   if(new[]{"AITranscriber.exe","Transcriber-UI.ps1","THIRD-PARTY-NOTICES.md","whisper-cli.exe","whisper.dll","ggml.dll","ggml-base.dll","ffmpeg.exe","licenses\\Whisper-LICENSE.txt"}.Contains(relative,StringComparer.OrdinalIgnoreCase))return true;
   if(Regex.IsMatch(relative,@"^ggml-cpu-[a-z0-9-]+\.dll$",RegexOptions.IgnoreCase))return true;
   if(Catalog.Embedded().Models.Any(m=>m.FileName.Equals(relative,StringComparison.OrdinalIgnoreCase)))return true;
   return relative.StartsWith("licenses\\ffmpeg-notice-",StringComparison.OrdinalIgnoreCase)&&relative.Substring("licenses\\".Length).IndexOfAny(new[]{'\\','/'})<0;
  }
  public static bool HasPending(string directory) {string file=PathFor(directory,JournalName);return File.Exists(file)||Directory.Exists(file);}
  public PublicationTransaction(InstallationRecord current) {
   record=current;if(HasPending(current.InstallDirectory))throw new IOException("An interrupted installation must be recovered before continuing.");
   string id=Guid.NewGuid().ToString("N");journal=new PublicationJournal{TransactionId=id,InstallId=current.InstallId,InstallDirectory=current.InstallDirectory,BackupDirectory=".ats-backup-"+id,OriginalRecordAttributes=(int)File.GetAttributes(PathFor(current.InstallDirectory,"installation.json"))};
   Directory.CreateDirectory(PathFor(current.InstallDirectory,journal.BackupDirectory));
   string backup=BackupPath(journal,"record.json");CopyDurable(PathFor(current.InstallDirectory,"installation.json"),backup);journal.RecordSha256=Payload.HashFile(backup);Persist(journal);
  }
  static void CopyDurable(string source,string dest) {AtomicFiles.CopyDurable(source,dest);}
  static void Persist(PublicationJournal j) {
   string file=PathFor(j.InstallDirectory,JournalName),temp=PathFor(j.InstallDirectory,".ats-journal-"+Guid.NewGuid().ToString("N")+".tmp");
   try{using(var s=new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None)){new DataContractJsonSerializer(typeof(PublicationJournal)).WriteObject(s,j);s.Flush(true);}if(File.Exists(file))AtomicFiles.Replace(temp,file,null);else File.Move(temp,file);}
   finally{if(File.Exists(temp))File.Delete(temp);}
  }
  public void Publish(string source,string relative) {
   string dest=PathFor(record.InstallDirectory,relative);if(!Allowed(relative))throw new IOException("Unrecognized publication path: "+relative);
   if(journal.Entries.Any(e=>e.Path.Equals(relative,StringComparison.OrdinalIgnoreCase)))throw new IOException("Duplicate transaction destination: "+relative);
   string hash=Payload.HashFile(source);bool exists=File.Exists(dest);
   if(Directory.Exists(dest))throw new IOException("A folder occupies the app file path: "+dest);
   if(exists&&!record.OwnedFiles.Contains(relative,StringComparer.OrdinalIgnoreCase))throw new IOException("Refusing to replace an unrelated file: "+dest);
   string originalHash=exists?Payload.HashFile(dest):null;
   if(exists&&originalHash.Equals(hash,StringComparison.OrdinalIgnoreCase)){record.Own(relative,hash);return;}
   var entry=new PublicationEntry{Path=relative,BackupName="file-"+journal.Entries.Length+".bin",HadOriginal=exists,PublishedHash=hash};
   if(exists){entry.OriginalHash=originalHash;entry.OriginalAttributes=(int)File.GetAttributes(dest);}
   journal.Entries=journal.Entries.Concat(new[]{entry}).ToArray();Persist(journal);
   Directory.CreateDirectory(System.IO.Path.GetDirectoryName(dest));
   try {
    if(exists){string backup=BackupPath(journal,entry.BackupName);AtomicFiles.Replace(source,dest,backup);using(var file=File.Open(backup,FileMode.Open,FileAccess.Write,FileShare.None))file.Flush(true);}else File.Move(source,dest);
   }catch(Exception e){if(!(e is IOException)&&!(e is UnauthorizedAccessException))throw;throw AtomicFiles.Failure("Publish "+relative,source,dest,exists?BackupPath(journal,entry.BackupName):null,e);}
   record.Own(relative,hash);
  }
  public void Commit() {journal.Committed=true;Persist(journal);finished=true;TryCleanup(journal);}
  public void Dispose() {
   if(finished)return;
   try{Validate(journal);Rollback(journal);finished=true;}
   catch(Exception e){throw new IOException("Installation recovery could not finish. Close the app and retry setup. Its recovery journal and original-file backups were kept. "+e.Message,e);}
  }
  public static void Recover(string directory) {
   if(!HasPending(directory))return;
   PublicationJournal j;
   try{using(var s=File.OpenRead(PathFor(directory,JournalName))){if(s.Length>1024*1024)throw new IOException("Recovery journal is too large.");j=(PublicationJournal)new DataContractJsonSerializer(typeof(PublicationJournal)).ReadObject(s);}if(j==null||!string.Equals(j.InstallDirectory,directory,StringComparison.OrdinalIgnoreCase))throw new IOException("Recovery journal folder mismatch.");Validate(j);if(j.Committed)TryCleanup(j);else Rollback(j);}
   catch(Exception e){throw new IOException("An interrupted installation could not be recovered. Original-file backups and the recovery journal were kept. "+e.Message,e);}
  }
  static void Validate(PublicationJournal j) {
   Guid id;string dir=Installation.NormalizeDirectory(j.InstallDirectory);
   if(j.SchemaVersion!=1||!Guid.TryParseExact(j.TransactionId,"N",out id)||!Guid.TryParse(j.InstallId,out id)||j.BackupDirectory!=".ats-backup-"+j.TransactionId||!Hash(j.RecordSha256)||j.Entries==null||j.Entries.Length>256)throw new IOException("Invalid recovery journal.");
   string backupRecord=BackupPath(j,"record.json");if(!File.Exists(backupRecord)||!Payload.HashFile(backupRecord).Equals(j.RecordSha256,StringComparison.OrdinalIgnoreCase))throw new IOException("Original installation record backup is missing or changed.");
   var original=InstallationRecord.ReadFile(dir,backupRecord);if(original.InstallId!=j.InstallId)throw new IOException("Recovery installation identity mismatch.");
   ValidateAttributes(j.OriginalRecordAttributes);
   string current=PathFor(dir,"installation.json");if(File.Exists(current)&&InstallationRecord.Read(dir).InstallId!=j.InstallId)throw new IOException("Installation identity changed; recovery refused.");
   var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
   for(int i=0;i<j.Entries.Length;i++) {
    var e=j.Entries[i];if(e==null||!Hash(e.PublishedHash)||e.BackupName!="file-"+i+".bin"||string.IsNullOrEmpty(e.Path)||!Allowed(e.Path)||!paths.Add(e.Path))throw new IOException("Invalid recovery file entry.");
    PathFor(dir,e.Path);
    ValidateAttributes(e.OriginalAttributes);if(!e.HadOriginal&&e.OriginalAttributes.HasValue)throw new IOException("Attributes cannot claim a missing original file.");
    if(e.HadOriginal){
     if(!Hash(e.OriginalHash)||!original.OwnedFiles.Contains(e.Path,StringComparer.OrdinalIgnoreCase))throw new IOException("Recovery cannot claim an unrelated original file.");
     string backup=BackupPath(j,e.BackupName),dest=PathFor(dir,e.Path);
     if(File.Exists(backup)){if(!Payload.HashFile(backup).Equals(e.OriginalHash,StringComparison.OrdinalIgnoreCase))throw new IOException("An original-file backup changed.");}
     else if(j.Committed||!File.Exists(dest)||!Payload.HashFile(dest).Equals(e.OriginalHash,StringComparison.OrdinalIgnoreCase))throw new IOException("An original-file backup is missing.");
    }
    if(!j.Committed)ValidateCurrent(j,e);
   }
  }
  static void ValidateCurrent(PublicationJournal j,PublicationEntry e) {
   string dest=PathFor(j.InstallDirectory,e.Path);if(Directory.Exists(dest))throw new IOException("A folder occupies a recovery destination: "+e.Path);if(!File.Exists(dest))return;
   string hash=Payload.HashFile(dest);if(!hash.Equals(e.PublishedHash,StringComparison.OrdinalIgnoreCase)&&(!e.HadOriginal||!hash.Equals(e.OriginalHash,StringComparison.OrdinalIgnoreCase)))throw new IOException("A file changed after installation was interrupted; recovery preserved it: "+e.Path);
  }
  static void ValidateAttributes(int? attributes){if(attributes.HasValue&&(attributes.Value<0||(attributes.Value&((int)FileAttributes.Directory|(int)FileAttributes.ReparsePoint))!=0))throw new IOException("Invalid original-file attributes in recovery journal.");}
  static void Restore(PublicationJournal j,string backupName,string relative,string originalHash,int? attributes) {
   string dest=PathFor(j.InstallDirectory,relative);if(File.Exists(dest)&&Payload.HashFile(dest).Equals(originalHash,StringComparison.OrdinalIgnoreCase)){AtomicFiles.RestoreReadOnly(dest,attributes);return;}
   string temp=BackupPath(j,"restore-"+Guid.NewGuid().ToString("N")+".tmp");
   try{CopyDurable(BackupPath(j,backupName),temp);Directory.CreateDirectory(System.IO.Path.GetDirectoryName(dest));if(File.Exists(dest))AtomicFiles.Replace(temp,dest,null);else File.Move(temp,dest);AtomicFiles.RestoreReadOnly(dest,attributes);}
   finally{AtomicFiles.DeletePrivate(temp);}
  }
  static void Rollback(PublicationJournal j) {
   foreach(var e in j.Entries.Reverse()){ValidateCurrent(j,e);if(e.HadOriginal)Restore(j,e.BackupName,e.Path,e.OriginalHash,e.OriginalAttributes);else{string path=PathFor(j.InstallDirectory,e.Path);AtomicFiles.DeletePrivate(path);}}
   Restore(j,"record.json","installation.json",j.RecordSha256,j.OriginalRecordAttributes);TryCleanup(j);
  }
  static void TryCleanup(PublicationJournal j) {
   // Remove the journal first: a crash during optional backup cleanup must never
   // leave a journal whose required backups have already been deleted.
   try{AtomicFiles.DeletePrivate(PathFor(j.InstallDirectory,JournalName));foreach(var e in j.Entries)if(e.HadOriginal){AtomicFiles.DeletePrivate(BackupPath(j,e.BackupName));}AtomicFiles.DeletePrivate(BackupPath(j,"record.json"));string folder=PathFor(j.InstallDirectory,j.BackupDirectory);if(!Directory.EnumerateFileSystemEntries(folder).Any())Directory.Delete(folder);}
   catch(IOException){}catch(UnauthorizedAccessException){}
  }
 }
}
