using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace AITranscriberInstaller {
 // Only validated app-owned destinations and private staging/backup files may
 // use these helpers. ACLs and every attribute except ReadOnly are untouched.
 internal static class AtomicFiles {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
  internal static void RestoreReadOnly(string path,int? original) {
   if(!original.HasValue||!File.Exists(path))return;
   var current=File.GetAttributes(path);
   var value=(original.Value&(int)FileAttributes.ReadOnly)!=0?current|FileAttributes.ReadOnly:current&~FileAttributes.ReadOnly;
   if(value!=current)File.SetAttributes(path,value);
  }
  internal static void ClearReadOnly(string path) {
   var attributes=File.GetAttributes(path);
   if((attributes&FileAttributes.Directory)!=0)throw new IOException("A directory occupies an expected app file: "+path);
   if((attributes&FileAttributes.ReadOnly)!=0)File.SetAttributes(path,attributes&~FileAttributes.ReadOnly);
  }
  static string Describe(string path) {
   if(path==null)return "(none)";
   try{return path+" ["+(File.Exists(path)?File.GetAttributes(path).ToString():"missing")+"]";}catch{return path+" [attributes unavailable]";}
  }
  internal static IOException Failure(string operation,string source,string destination,string backup,Exception cause,string prior=null) {
   var native=cause.GetBaseException();int code=native.HResult&65535;
   string hint=code==32||code==33?"The file is in use. Close the app or other process using it, then retry.":"Windows denied or could not complete this file operation. Check this installation folder's file access and any Windows Security protection event for the named file, then retry.";
   return new IOException(operation+" failed. "+hint+Environment.NewLine+
    "Destination: "+Describe(destination)+Environment.NewLine+"Source: "+Describe(source)+Environment.NewLine+
    "Backup: "+Describe(backup)+Environment.NewLine+"Windows error: 0x"+native.HResult.ToString("X8")+". "+cause.Message+
    (prior==null?"":Environment.NewLine+"Original attributes: "+prior),cause);
  }
  internal static void Replace(string source,string destination,string backup) {
   int? sourceAttributes=null,destinationAttributes=null;Exception failure=null;
   try {
    sourceAttributes=(int)File.GetAttributes(source);destinationAttributes=(int)File.GetAttributes(destination);
    ClearReadOnly(source);ClearReadOnly(destination);
    File.Replace(source,destination,backup,false);
   } catch(Exception e) {if(!(e is IOException)&&!(e is UnauthorizedAccessException))throw;failure=e;}
   finally {
    try{RestoreReadOnly(source,sourceAttributes);}catch(Exception e){if(failure==null)failure=e;}
    try{RestoreReadOnly(destination,destinationAttributes);}catch(Exception e){if(failure==null)failure=e;}
   }
   if(failure!=null)throw Failure("Atomic app-file replacement",source,destination,backup,failure,
    "source="+(sourceAttributes.HasValue?((FileAttributes)sourceAttributes.Value).ToString():"unknown")+", destination="+(destinationAttributes.HasValue?((FileAttributes)destinationAttributes.Value).ToString():"unknown"));
  }
  internal static void CopyDurable(string source,string destination) {
   File.Copy(source,destination,false);int attributes=(int)File.GetAttributes(destination);
   try{ClearReadOnly(destination);using(var file=File.Open(destination,FileMode.Open,FileAccess.Write,FileShare.None))file.Flush(true);}
   finally{RestoreReadOnly(destination,attributes);}
  }
  internal static void DeletePrivate(string path) {if(File.Exists(path)){ClearReadOnly(path);File.Delete(path);}}
  internal static void ProbeReplacement(string path) {
   if(!File.Exists(path))return;
   var attributes=File.GetAttributes(path);
   // Maximum sharing grants no new access: an existing incompatible handle or
   // an actual ACL denial still rejects this OPEN_EXISTING probe.
   using(var handle=CreateFile(path,0xC0010000,7,IntPtr.Zero,3,0,IntPtr.Zero)) {
    if(!handle.IsInvalid)return;
    int error=Marshal.GetLastWin32Error();
    // ReadOnly will be handled transactionally, after its prior state is journaled.
    if(error==5&&(attributes&FileAttributes.ReadOnly)!=0)return;
    throw Failure("Replacement preflight",null,path,null,new IOException(new Win32Exception(error).Message,unchecked((int)(0x80070000u|(uint)error))));
   }
  }
 }
}
