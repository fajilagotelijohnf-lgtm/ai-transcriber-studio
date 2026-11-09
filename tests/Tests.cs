using System;
using System.IO;
using System.Linq;
using AITranscriberInstaller;
public partial class InstallerTests {
 static int passed;
 public static void Check(bool condition,string name) { if(!condition) throw new Exception("FAIL "+name); passed++; Console.WriteLine("PASS "+name); }
 [STAThread] public static int Main(string[] args) {
  try {
   if(args.Contains("--smoke-small") || args.Contains("--smoke-medium")) return Smoke(args.Contains("--smoke-medium"));
   var c=Catalog.Embedded();
   Check(c.Models.Length==9,"nine model choices");
   Check(c.DefaultModelId=="small","default Small multilingual");
   using(var script=Payload.Open("Transcriber")) Check(Payload.HashStream(script).Equals(c.ScriptSha256,StringComparison.OrdinalIgnoreCase),"embedded original script SHA256");
   Check(c.Models.All(m=>m.Url.Contains("5359861c739e955e79d9a303bcbc70fb988958b1")),"model revision pinned");
   if(args.Contains("all") || args.Contains("transfers") || args.Contains("paths")) TestTransfersAndPaths();
   if(args.Contains("all") || args.Contains("installation")) TestInstallation();
   if(args.Contains("all") || args.Contains("ui-state")) TestUi();
   if(args.Contains("all") || args.Contains("windows-integration") || args.Contains("removal")) TestWindows();
   if(args.Contains("all") || args.Contains("audit")) TestAudit();
   if(args.Contains("all") || args.Contains("permissions")) TestPermissions();
   Console.WriteLine("RESULT "+passed+" passed"); return 0;
  } catch(Exception e) { Console.Error.WriteLine(e); return 1; }
 }
}
