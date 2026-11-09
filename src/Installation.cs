using System;
using System.IO;
namespace AITranscriberInstaller {
 public partial class Installation {
  public static string NormalizeDirectory(string input) {
   if(string.IsNullOrWhiteSpace(input) || !Path.IsPathRooted(input)) throw new IOException("Choose a full installation folder path.");
   string path=Path.GetFullPath(input).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
   if(path.Length<4 || path.Equals(Path.GetPathRoot(path).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)) throw new IOException("Choose an app folder, not a drive root.");
   if(File.Exists(path)) throw new IOException("The chosen folder path is a file: "+path);
   RejectReparse(path); return path;
  }
  public static void RejectReparse(string path) {
   string next=Path.GetFullPath(path);
   while(!string.IsNullOrEmpty(next)) {
    if((File.Exists(next)||Directory.Exists(next)) && (File.GetAttributes(next)&FileAttributes.ReparsePoint)!=0) throw new IOException("Linked folders/files are not supported for installation or removal: "+next);
    next=Path.GetDirectoryName(next);
   }
  }
  public static string SafePath(string root,string relative) {
   if(string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative) || relative.Contains(":") || Array.Exists(relative.Split('\\','/'),p=>p==".."||p==".")) throw new IOException("Unsafe owned-file path: "+relative);
   string prefix=Path.GetFullPath(root).TrimEnd('\\','/')+Path.DirectorySeparatorChar;
   string path=Path.GetFullPath(Path.Combine(prefix,relative));
   if(!path.StartsWith(prefix,StringComparison.OrdinalIgnoreCase)) throw new IOException("Path escapes the installation folder.");
   RejectReparse(path); return path;
  }
  public static void ValidateDestination(string path,long requiredBytes) {
   path=NormalizeDirectory(path);
   if(path.Length>160)throw new IOException("Choose a shorter installation folder (at most 160 characters). Setup needs additional path space for verified downloads and recovery backups.");
   var drive=new DriveInfo(Path.GetPathRoot(path));
   if(!drive.IsReady) throw new IOException("Destination drive is unavailable: "+path);
   if(requiredBytes<0 || drive.AvailableFreeSpace<requiredBytes) throw new IOException("Not enough free space on the destination drive: "+path);
   Directory.CreateDirectory(path);
   string probe=SafePath(path,".ats-write-"+Guid.NewGuid().ToString("N")+".tmp");
   try { using(File.Open(probe,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {} }
   catch(UnauthorizedAccessException e) { throw new IOException("Cannot write to "+path+". Choose a writable folder, or run setup with the required permissions.",e); }
   finally { if(File.Exists(probe)) File.Delete(probe); }
  }
 }
}
