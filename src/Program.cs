using System;
using System.IO;
using System.Linq;
using System.Diagnostics;
using System.Reflection;
using System.Windows.Forms;
[assembly:AssemblyTitle("AI Transcriber Studio Setup")]
[assembly:AssemblyProduct("AI Transcriber Studio")]
[assembly:AssemblyVersion("1.2.1.0")]
[assembly:AssemblyFileVersion("1.2.1.0")]
namespace AITranscriberInstaller {
 internal static class Program {
  [STAThread] public static int Main(string[] args) {
   DesktopIdentity.Apply();Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
   try {
    if(!Environment.Is64BitOperatingSystem || Environment.OSVersion.Version.Major<10 || (Environment.GetEnvironmentVariable("PROCESSOR_ARCHITEW6432")??Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")??"").IndexOf("ARM",StringComparison.OrdinalIgnoreCase)>=0)throw new IOException("This setup supports Windows 10/11 on Intel or AMD 64-bit computers.");
    var c=Catalog.Embedded();string mode=args.Length==0?(Path.GetFileName(Assembly.GetExecutingAssembly().Location).Equals("AITranscriber.exe",StringComparison.OrdinalIgnoreCase)?"--launch":"--setup"):args[0];
    string directory=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location),id=null;int parent=0;
    for(int i=1;i<args.Length;i+=2){if(i+1>=args.Length)throw new IOException("Missing command argument.");switch(args[i]){case "--install-dir":directory=Installation.NormalizeDirectory(args[i+1]);break;case "--install-id":id=args[i+1];break;case "--parent-pid":parent=int.Parse(args[i+1]);break;default:throw new IOException("Unknown option: "+args[i]);}}
    switch(mode){
     case "--setup":Application.Run(new SetupForm(c,null,WindowsIntegration.Register,WindowsIntegration.OpenInstalledApp,WindowsIntegration.CheckRegistration));break;
     case "--models":InstallationRecord.Read(directory);Application.Run(new SetupForm(c,directory,null,WindowsIntegration.OpenInstalledApp));break;
     case "--launch":using(var p=WindowsIntegration.LaunchApp(directory))p.WaitForExit();break;
     case "--uninstall":WindowsIntegration.BeginUninstall(directory);break;
     case "--uninstall-worker":if(id==null||parent<=0)throw new IOException("Invalid uninstall worker arguments.");WindowsIntegration.UninstallWorker(directory,id,parent);break;
     default:throw new IOException("Unknown command: "+mode);
    }
    return 0;
   }
   catch(Exception e) { MessageBox.Show(e.Message,"AI Transcriber Studio",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
  }
 }
}

