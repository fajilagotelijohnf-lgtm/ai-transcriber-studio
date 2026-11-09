param([string]$ExePath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not $ExePath){$ExePath=Join-Path $root 'build\AI-Transcriber-Setup.exe'}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PackageIconReader {
 delegate bool Names(IntPtr module,IntPtr type,IntPtr name,IntPtr param);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]static extern bool EnumResourceNames(IntPtr module,IntPtr type,Names callback,IntPtr param);
 [DllImport("kernel32.dll")]static extern bool FreeLibrary(IntPtr module);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]static extern IntPtr FindResource(IntPtr module,IntPtr name,IntPtr type);
 [DllImport("kernel32.dll")]static extern IntPtr LoadResource(IntPtr module,IntPtr resource);
 [DllImport("kernel32.dll")]static extern IntPtr LockResource(IntPtr resource);
 [DllImport("kernel32.dll")]static extern uint SizeofResource(IntPtr module,IntPtr resource);
 public static byte[] Group(string path){
  var module=LoadLibraryEx(path,IntPtr.Zero,2);if(module==IntPtr.Zero)throw new Exception("Cannot inspect EXE resources");
  try{IntPtr found=IntPtr.Zero;Names callback=(m,t,n,p)=>{found=n;return false;};EnumResourceNames(module,new IntPtr(14),callback,IntPtr.Zero);
   if(found==IntPtr.Zero)throw new Exception("EXE has no embedded Windows icon group");
   var resource=FindResource(module,found,new IntPtr(14));var data=new byte[SizeofResource(module,resource)];Marshal.Copy(LockResource(LoadResource(module,resource)),data,0,data.Length);return data;
  }finally{FreeLibrary(module);}
 }
}
'@
$bytes=[PackageIconReader]::Group($ExePath)
$count=[BitConverter]::ToUInt16($bytes,4)
$sizes=@(for($i=0;$i -lt $count;$i++){ $w=[int]$bytes[6+14*$i];if($w -eq 0){256}else{$w} })
foreach($size in @(16,20,24,32,48,64,128,256)){if($sizes -notcontains $size){throw "Missing $size px icon frame"}}
'PASS EXE includes eight Windows icon sizes, 16 through 256 px'
function IconHash([Drawing.Icon]$Icon){$bitmap=$Icon.ToBitmap();$memory=New-Object IO.MemoryStream;$sha=[Security.Cryptography.SHA256]::Create();try{$bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);[BitConverter]::ToString($sha.ComputeHash($memory.ToArray()))}finally{$bitmap.Dispose();$memory.Dispose();$sha.Dispose()}}
$expected=[Drawing.Icon]::ExtractAssociatedIcon($ExePath)
try{
 if((IconHash $expected) -eq (IconHash ([Drawing.SystemIcons]::Application))){throw 'EXE still uses the generic application icon'}
 [void][Reflection.Assembly]::LoadFrom($ExePath)
 $form=New-Object AITranscriberInstaller.SetupForm([AITranscriberInstaller.Catalog]::Embedded()),$null
 try{if((IconHash $form.Icon) -ne (IconHash $expected)){throw 'Setup window icon differs from EXE branding'}}finally{$form.Dispose()}
 'PASS setup window uses the branded EXE icon'
}finally{$expected.Dispose()}
