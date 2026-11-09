using System;
using System.IO;
using System.Linq;
using System.Drawing;
using System.Windows.Forms;
using AITranscriberInstaller;
public partial class InstallerTests {
 static void Pump(System.Threading.Tasks.Task task){var until=DateTime.UtcNow.AddSeconds(15);while(!task.IsCompleted&&DateTime.UtcNow<until){Application.DoEvents();System.Threading.Thread.Sleep(5);}if(!task.IsCompleted)throw new Exception("UI test timed out");task.GetAwaiter().GetResult();}
 static void TestUi() {
  Application.EnableVisualStyles();
  using(var f=new SetupForm(Catalog.Embedded(),null)) {
   Check(f.SelectedModels.SequenceEqual(new[]{"small"}),"setup defaults to Small multilingual");
   f.ChooseModel("small",false); Check(!f.CanStart,"no models prevents install");
   f.ChooseModel("medium",true); Check(f.CanStart,"chosen model enables install");
   string folder=Path.Combine(Fixture(),"selected folder 日本語"); f.PickDirectory(folder); f.SetBusy(true); Check(!f.CanStart,"download disables duplicate install"); f.SetBusy(false); Check(f.CurrentDirectory==folder&&f.SelectedModels.Contains("medium"),"retry retains folder and selection");
   string results=Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"..","test-results"));
   f.StartPosition=FormStartPosition.Manual;f.Location=new Point(-30000,-30000);f.ShowInTaskbar=false;f.Show();f.PerformLayout();Application.DoEvents();
   Pump(f.RefreshModelsAsync());Check(f.Controls[0].Visible,"setup content visible before rendering");
   using(var b=new Bitmap(f.Width,f.Height)) {f.DrawToBitmap(b,new Rectangle(Point.Empty,f.Size));b.Save(Path.Combine(results,"setup-100.png"));}
   f.Scale(new SizeF(1.5f,1.5f)); using(var b=new Bitmap(f.Width,f.Height)) {f.DrawToBitmap(b,new Rectangle(Point.Empty,f.Size));b.Save(Path.Combine(results,"setup-150.png"));}
  }
  string installed=Path.Combine(Fixture(),"existing app");var http=new RoutingHttp();var c=FixtureCatalog(http);
  using(var tr=new Transfers(new System.Net.Http.HttpClient(http)))System.Threading.Tasks.Task.Run(()=>new Installation(tr,p=>{}).InstallAsync(new InstallRequest{Directory=installed,ModelIds=new[]{"small"}},c,null,System.Threading.CancellationToken.None)).GetAwaiter().GetResult();
  using(var f=new SetupForm(c,null)) {
   f.PickDirectory(installed);Pump(f.RefreshModelsAsync());
   Check(f.SelectedModels.Contains("small")&&f.CanStart,"setup can repair with existing valid Small without downloading another model");
  }
  using(var f=new SetupForm(c,installed)) {
   Pump(f.RefreshModelsAsync());f.ChooseModel("small",true);
   Check(!f.SelectedModels.Contains("small"),"manager prevents selecting already-installed model");
  }
 }
}
