using System;
using System.IO;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
namespace AITranscriberInstaller {
 public class ProcessOutput { public int ExitCode; public string Text; }
 public class RuntimeStartupException : IOException {
  public readonly int ExitCode; public RuntimeStartupException(int code,string message):base(message){ExitCode=code;}
 }
 public static class NativeRuntime {
  [DllImport("kernel32.dll")] static extern uint SetErrorMode(uint mode);
  public static ProcessOutput Run(string exe,string args,int timeout=30000) {
   var psi=new ProcessStartInfo(exe,args){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=Path.GetDirectoryName(exe),RedirectStandardOutput=true,RedirectStandardError=true};
   uint prior=SetErrorMode(0x0001|0x0002|0x8000);
   try {
    using(var p=Process.Start(psi)) {
     var output=p.StandardOutput.ReadToEndAsync(); var error=p.StandardError.ReadToEndAsync();
     if(!p.WaitForExit(timeout)) { try {p.Kill();} catch {} throw new IOException("Runtime check timed out: "+Path.GetFileName(exe)); }
     return new ProcessOutput{ExitCode=p.ExitCode,Text=output.GetAwaiter().GetResult()+error.GetAwaiter().GetResult()};
    }
   } finally {SetErrorMode(prior);}
  }
  public static void Check(string directory) {
   var w=Run(Path.Combine(directory,"whisper-cli.exe"),"--help");
   if(w.ExitCode!=0 || !w.Text.Contains("-ojf") || !w.Text.Contains("-pp")) throw new RuntimeStartupException(w.ExitCode,"Whisper could not start or lacks required output options (exit "+w.ExitCode+"). "+w.Text);
   var f=Run(Path.Combine(directory,"ffmpeg.exe"),"-version");
   if(f.ExitCode!=0 || !f.Text.Contains("ffmpeg version")) throw new RuntimeStartupException(f.ExitCode,"FFmpeg could not start (exit "+f.ExitCode+"). "+f.Text);
  }
  internal static bool IsDependencyFailure(Exception error) {
   var startup=error as RuntimeStartupException;
   if(startup!=null){uint code=unchecked((uint)startup.ExitCode);return code==0xC0000135||code==0xC0000139||code==0xC000007B;}
   var win32=error as Win32Exception;
   return win32!=null&&(win32.NativeErrorCode==126||win32.NativeErrorCode==127||win32.NativeErrorCode==193||win32.NativeErrorCode==14001);
  }
  internal static async Task WaitForPrerequisiteAsync(Func<bool> hasExited,CancellationToken token,TimeSpan maximum) {
   var clock=Stopwatch.StartNew();
   while(!hasExited()) {
    token.ThrowIfCancellationRequested();
    if(clock.Elapsed>=maximum)throw new IOException("Microsoft runtime setup is still running. Finish or close its Windows installer, then retry setup.");
    await Task.Delay(100,token).ConfigureAwait(false);
   }
  }
  public static async Task EnsureAsync(string stage,Catalog c,Transfers downloads,IProgress<TransferProgress> progress,CancellationToken token) {
   try { Check(stage); return; } catch(Exception e) { if(!IsDependencyFailure(e))throw; }
   string part=await downloads.FetchAsync(c.VcRuntime,Installation.SafePath(stage,"vc.part"),progress,token).ConfigureAwait(false);
   string exe=Installation.SafePath(stage,"vc_redist.x64.exe"); File.Move(part,exe);
   string command="$s=Get-AuthenticodeSignature -LiteralPath $env:ATS_PREREQUISITE; if($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'O=Microsoft Corporation'){exit 0}else{exit 1}";
   string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell\\v1.0\\powershell.exe");
   var check=new ProcessStartInfo(ps,"-NoProfile -NonInteractive -EncodedCommand "+Convert.ToBase64String(Encoding.Unicode.GetBytes(command))){UseShellExecute=false,CreateNoWindow=true}; check.EnvironmentVariables["ATS_PREREQUISITE"]=exe;
   using(var p=Process.Start(check)) { if(!p.WaitForExit(60000)) {p.Kill();throw new IOException("Microsoft signature verification timed out.");} if(p.ExitCode!=0) throw new IOException("Microsoft runtime publisher verification failed."); }
   token.ThrowIfCancellationRequested();
   if(progress!=null) progress.Report(new TransferProgress{ArtifactId=c.VcRuntime.Id,Phase="Installing Microsoft runtime. Approve Windows permission prompt if shown."});
   using(var p=Process.Start(new ProcessStartInfo(exe,"/install /passive /norestart"){UseShellExecute=true,Verb="runas"})) {
    try{await WaitForPrerequisiteAsync(()=>p.HasExited,token,TimeSpan.FromMinutes(10)).ConfigureAwait(false);}
    catch(OperationCanceledException){throw new IOException("Setup cancelled. If Microsoft runtime setup is still open, finish or close it before retrying.");}
    if(p.ExitCode!=0 && p.ExitCode!=3010 && p.ExitCode!=1638) throw new IOException("Microsoft runtime installation failed or was cancelled (exit "+p.ExitCode+").");
    if(p.ExitCode==3010) throw new IOException("Microsoft runtime installed. Restart Windows, then run setup again to finish.");
   }
   Check(stage);
  }
 }
}
