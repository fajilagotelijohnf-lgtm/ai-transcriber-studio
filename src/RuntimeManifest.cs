using System;
using System.IO;
using System.Text;
using System.Xml;
using System.Runtime.InteropServices;
using System.Collections.Generic;
namespace AITranscriberInstaller {
 // The upstream Windows CLI uses narrow argv/fopen. Its per-process UTF-8
 // manifest keeps model and output paths intact without changing the PS1.
 internal static class RuntimeManifest {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern IntPtr LoadLibraryEx(string file,IntPtr reserved,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)]static extern bool FreeLibrary(IntPtr module);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern IntPtr FindResource(IntPtr module,IntPtr name,IntPtr type);
  [DllImport("kernel32.dll",SetLastError=true)]static extern uint SizeofResource(IntPtr module,IntPtr resource);
  [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr LoadResource(IntPtr module,IntPtr resource);
  [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr LockResource(IntPtr resource);
  delegate bool EnumLanguage(IntPtr module,IntPtr type,IntPtr name,ushort language,IntPtr parameter);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool EnumResourceLanguages(IntPtr module,IntPtr type,IntPtr name,EnumLanguage callback,IntPtr parameter);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern IntPtr BeginUpdateResource(string file,bool deleteExisting);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool UpdateResource(IntPtr update,IntPtr type,IntPtr name,ushort language,byte[] data,uint length);
  [DllImport("kernel32.dll",SetLastError=true)]static extern bool EndUpdateResource(IntPtr update,bool discard);
  const string Asm="urn:schemas-microsoft-com:asm.v3";
  const string Ws="http://schemas.microsoft.com/SMI/2019/WindowsSettings";
  static string Read(string path,List<ushort> languages) {
   IntPtr module=LoadLibraryEx(path,IntPtr.Zero,0x22);if(module==IntPtr.Zero)throw new IOException("Cannot read the Whisper executable manifest.");
   try{IntPtr r=FindResource(module,(IntPtr)1,(IntPtr)24);if(r==IntPtr.Zero)return null;uint size=SizeofResource(module,r);var bytes=new byte[size];Marshal.Copy(LockResource(LoadResource(module,r)),bytes,0,(int)size);EnumLanguage callback=delegate(IntPtr m,IntPtr t,IntPtr n,ushort lang,IntPtr p){languages.Add(lang);return true;};EnumResourceLanguages(module,(IntPtr)24,(IntPtr)1,callback,IntPtr.Zero);return Encoding.UTF8.GetString(bytes).TrimEnd('\0');}
   finally{FreeLibrary(module);}
  }
  public static void EnsureUtf8(string path) {
   var languages=new List<ushort>();string existing=Read(path,languages);var doc=new XmlDocument{PreserveWhitespace=true};
   doc.LoadXml(existing??"<assembly xmlns='urn:schemas-microsoft-com:asm.v1' manifestVersion='1.0' />");
   var app=doc.GetElementsByTagName("application",Asm);XmlElement application=app.Count==0?doc.CreateElement("application",Asm):(XmlElement)app[0];if(app.Count==0)doc.DocumentElement.AppendChild(application);
   var settings=application.GetElementsByTagName("windowsSettings",Asm);XmlElement windows=settings.Count==0?doc.CreateElement("windowsSettings",Asm):(XmlElement)settings[0];if(settings.Count==0)application.AppendChild(windows);
   var old=windows.GetElementsByTagName("activeCodePage",Ws);XmlElement code=old.Count==0?doc.CreateElement("activeCodePage",Ws):(XmlElement)old[0];if(old.Count==0)windows.AppendChild(code);code.InnerText="UTF-8";
   byte[] bytes;using(var memory=new MemoryStream()){using(var writer=XmlWriter.Create(memory,new XmlWriterSettings{Encoding=new UTF8Encoding(false)}))doc.Save(writer);bytes=memory.ToArray();}
   IntPtr update=BeginUpdateResource(path,false);if(update==IntPtr.Zero)throw new IOException("Cannot update the Whisper UTF-8 manifest.");bool committed=false;
   try{if(languages.Count==0)languages.Add(0);foreach(ushort language in languages)if(!UpdateResource(update,(IntPtr)24,(IntPtr)1,language,bytes,(uint)bytes.Length))throw new IOException("Failed to write the Whisper UTF-8 manifest.");if(!EndUpdateResource(update,false))throw new IOException("Failed to save the Whisper UTF-8 manifest.");committed=true;}
   finally{if(!committed)EndUpdateResource(update,true);}
   if(!(Read(path,new List<ushort>())??"").Contains("UTF-8"))throw new IOException("Whisper manifest verification failed.");
  }
 }
}
