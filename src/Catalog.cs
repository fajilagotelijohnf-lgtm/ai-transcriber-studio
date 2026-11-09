using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace AITranscriberInstaller {
 [DataContract] public class Artifact {
  [DataMember] public string Id;
  [DataMember] public string Url;
  [DataMember] public string HashAlgorithm;
  [DataMember] public string Hash;
  [DataMember] public long DownloadBytes;
  [DataMember] public long ExpandedBytes;
 }
 [DataContract] public class Model : Artifact {
  [DataMember] public string DisplayName;
  [DataMember] public string FileName;
  [DataMember] public string Guidance;
 }
 [DataContract] public class Catalog {
  [DataMember] public string Version;
  [DataMember] public string DefaultModelId;
  [DataMember] public string ScriptSha256;
  [DataMember] public string OriginalScriptSha256;
  [DataMember] public Artifact Whisper;
  [DataMember] public Artifact Ffmpeg;
  [DataMember] public Artifact VcRuntime;
  [DataMember] public Model[] Models;
  public static Catalog Load(Stream json) {
   var c = (Catalog)new DataContractJsonSerializer(typeof(Catalog)).ReadObject(json);
   c.Validate(); return c;
  }
  public static Catalog Embedded() {
   Catalog c; using(var s=Payload.Open("Catalog")) c=Load(s);
   using(var s=Payload.Open("Transcriber")) if(!Payload.HashStream(s).Equals(c.ScriptSha256,StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Embedded transcriber integrity check failed.");
   return c;
  }
  public void Validate() {
   if(Models == null || Models.Length != 9 || Models.Select(m=>m.Id).Distinct().Count()!=9 ||
      Models.Select(m=>m.FileName).Distinct(StringComparer.OrdinalIgnoreCase).Count()!=9 ||
      !Models.Any(m=>m.Id==DefaultModelId) || DefaultModelId!="small") throw new InvalidDataException("Invalid model catalog.");
   foreach(var a in Models.Cast<Artifact>().Concat(new[]{Whisper,Ffmpeg,VcRuntime})) {
    Uri uri;
    if(a==null || !Uri.TryCreate(a.Url,UriKind.Absolute,out uri) || uri.Scheme!="https" ||
       a.HashAlgorithm!="SHA256" || !Regex.IsMatch(a.Hash??"", "^[a-fA-F0-9]{64}$") || a.DownloadBytes<=0)
      throw new InvalidDataException("Invalid pinned artifact.");
   }
   foreach(var m in Models) if(m.FileName!="ggml-"+m.Id+".bin" || m.FileName.IndexOfAny(Path.GetInvalidFileNameChars())>=0)
    throw new InvalidDataException("Invalid model filename.");
   if(!Regex.IsMatch(ScriptSha256??"","^[a-fA-F0-9]{64}$") || OriginalScriptSha256!="0F9919B1FAD54F41032B39349A206E0D18A6EBB11FA1E5EC1A0F77ED91E35AF0")
    throw new InvalidDataException("Unexpected transcriber version.");
  }
 }
 public static class Payload {
  public static Stream Open(string name) { var s=Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload."+name); if(s==null) throw new InvalidDataException("Missing embedded "+name); return s; }
  public static byte[] Bytes(string name) { using(var s=Open(name)) using(var m=new MemoryStream()) { s.CopyTo(m); return m.ToArray(); } }
  public static string HashFile(string file) { using(var s=File.OpenRead(file)) return HashStream(s); }
  public static string HashStream(Stream s) { using(var h=SHA256.Create()) return BitConverter.ToString(h.ComputeHash(s)).Replace("-", "").ToLowerInvariant(); }
 }
}
