using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
namespace AITranscriberInstaller {
 public sealed class SetupForm : Form {
  readonly Catalog catalog; readonly bool manager; readonly Action<InstallationRecord,bool> register; readonly Action<string> launch; readonly Action<string> preflight;
  readonly TextBox folder=new TextBox(),status=new TextBox(); readonly DataGridView models=new DataGridView();
  readonly Button browse=new Button(),start=new Button(),cancel=new Button(),open=new Button();
  readonly CheckBox desktop=new CheckBox(); readonly ProgressBar progress=new ProgressBar(); readonly Label transfer=new Label();
  CancellationTokenSource cancellation; Task refreshTask; bool busy,checking,usable=true; string lastPhase="";
  public string CurrentDirectory { get{return folder.Text.Trim();} }
  public string[] SelectedModels { get{return models.Rows.Cast<DataGridViewRow>().Where(r=>Convert.ToBoolean(r.Cells[0].Value)).Select(r=>(string)r.Tag).ToArray();} }
  public bool CanStart { get{return usable&&!busy&&!checking&&!string.IsNullOrWhiteSpace(CurrentDirectory)&&SelectedModels.Length>0;} }
  public SetupForm(Catalog c,string installedDirectory,Action<InstallationRecord,bool> registration=null,Action<string> launcher=null,Action<string> beforeInstall=null) {
   catalog=c;manager=installedDirectory!=null;register=registration;launch=launcher;preflight=beforeInstall;
   Icon=Icon.ExtractAssociatedIcon(System.Reflection.Assembly.GetExecutingAssembly().Location);
   Text="AI Transcriber Studio | "+(manager?"Manage Models":"Setup"); Font=new Font("Segoe UI",9F); AutoScaleMode=AutoScaleMode.Dpi;
   Size=new Size(1030,790); MinimumSize=new Size(940,700); StartPosition=FormStartPosition.CenterScreen; BackColor=Color.FromArgb(245,247,251);
   var root=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=8,Padding=new Padding(22)};
   root.RowStyles.Add(new RowStyle(SizeType.Absolute,85)); root.RowStyles.Add(new RowStyle(SizeType.Absolute,64));
   root.RowStyles.Add(new RowStyle(SizeType.Absolute,42)); root.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   root.RowStyles.Add(new RowStyle(SizeType.Absolute,42)); root.RowStyles.Add(new RowStyle(SizeType.Absolute,50));
   root.RowStyles.Add(new RowStyle(SizeType.Absolute,90)); root.RowStyles.Add(new RowStyle(SizeType.Absolute,50)); Controls.Add(root);
   var heading=new Panel{Dock=DockStyle.Fill};
   heading.Controls.Add(new Label{Text=manager?"Manage Whisper models":"Set up AI Transcriber Studio",Font=new Font("Segoe UI",21,FontStyle.Bold),ForeColor=Color.FromArgb(27,48,79),AutoSize=true,Location=new Point(0,0)});
   heading.Controls.Add(new Label{Text=manager?"Add models any time. Close this window to refresh the transcriber when idle.":"Choose a folder and models. Setup downloads Whisper and FFmpeg for you.",AutoSize=true,Location=new Point(2,47)});root.Controls.Add(heading,0,0);
   var folderPanel=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=2};folderPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));folderPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,100));
   folderPanel.Controls.Add(new Label{Text="Installation folder",AutoSize=true},0,0);folderPanel.SetColumnSpan(folderPanel.GetControlFromPosition(0,0),2);
   folder.Text=installedDirectory??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Programs","AI Transcriber Studio");folder.Dock=DockStyle.Fill;folder.ReadOnly=manager;
   browse.Text="Browse...";browse.Dock=DockStyle.Fill;browse.Enabled=!manager;folderPanel.Controls.Add(folder,0,1);folderPanel.Controls.Add(browse,1,1);root.Controls.Add(folderPanel,0,1);
   root.Controls.Add(new Label{Text="Select models  •  Multilingual supports English and Filipino. English-only is for English audio.",AutoSize=true,Anchor=AnchorStyles.Left},0,2);
   models.Dock=DockStyle.Fill;models.BackgroundColor=Color.White;models.BorderStyle=BorderStyle.FixedSingle;models.AllowUserToAddRows=false;models.AllowUserToDeleteRows=false;models.AllowUserToResizeRows=false;models.RowHeadersVisible=false;models.MultiSelect=false;models.SelectionMode=DataGridViewSelectionMode.FullRowSelect;models.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;
   models.ColumnHeadersHeight=34;models.RowTemplate.Height=36;models.DefaultCellStyle.SelectionBackColor=Color.FromArgb(230,239,252);models.DefaultCellStyle.SelectionForeColor=Color.Black;
   models.Columns.Add(new DataGridViewCheckBoxColumn{Name="Select",HeaderText="",FillWeight=35});
   AddColumn("Model",85);AddColumn("Language",155);AddColumn("Download",85);AddColumn("Best for",205);AddColumn("Status",100);
   foreach(var m in c.Models) {
    string baseName=m.Id.Replace(".en","");baseName=char.ToUpperInvariant(baseName[0])+baseName.Substring(1);
    int i=models.Rows.Add(!manager&&m.Id==c.DefaultModelId,baseName,m.Id.EndsWith(".en")?"English only":"Multilingual",SizeText(m.DownloadBytes),m.Guidance,"Available");models.Rows[i].Tag=m.Id;
   }
   root.Controls.Add(models,0,3);
   desktop.Text="Create a desktop shortcut";desktop.AutoSize=true;desktop.Checked=true;desktop.Visible=!manager;
   var options=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.LeftToRight};options.Controls.Add(desktop);options.Controls.Add(new Label{Text="Larger models need more memory and take longer on a CPU.",AutoSize=true,Padding=new Padding(10,4,0,0)});root.Controls.Add(options,0,4);
   var progressPanel=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=2};transfer.Text="Ready. Internet is required for downloads.";transfer.Dock=DockStyle.Fill;progress.Dock=DockStyle.Fill;progress.Maximum=1000;progressPanel.Controls.Add(transfer,0,0);progressPanel.Controls.Add(progress,0,1);root.Controls.Add(progressPanel,0,5);
   status.Dock=DockStyle.Fill;status.Multiline=true;status.ReadOnly=true;status.ScrollBars=ScrollBars.Vertical;status.BackColor=Color.White;status.Text=manager?"Installed models will be checked before they are marked ready.":"Your transcriber interface stays the same.\r\nMicrosoft's C++ runtime will be installed if required; Windows may request permission.";root.Controls.Add(status,0,6);
   var buttons=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.RightToLeft,Padding=new Padding(0,9,0,0)};
   foreach(var b in new[]{start,cancel,open}) {b.AutoSize=true;b.MinimumSize=new Size(125,32);buttons.Controls.Add(b);}
   start.Text=manager?"Add models":"Download && install";start.BackColor=Color.FromArgb(36,91,173);start.ForeColor=Color.White;start.FlatStyle=FlatStyle.Flat;
   cancel.Text="Cancel";cancel.Enabled=false;open.Text="Open transcriber";open.Enabled=false;root.Controls.Add(buttons,0,7);
   browse.Click+=async delegate{using(var dlg=new FolderBrowserDialog{Description="Choose the app's installation folder",SelectedPath=CurrentDirectory,ShowNewFolderButton=true}) if(dlg.ShowDialog(this)==DialogResult.OK) {PickDirectory(dlg.SelectedPath);await RefreshModelsAsync();}};
   folder.Validated+=async delegate{if(!busy)await RefreshModelsAsync();};
   folder.TextChanged+=delegate{UpdateControls();};
   models.CurrentCellDirtyStateChanged+=delegate{if(models.IsCurrentCellDirty) models.CommitEdit(DataGridViewDataErrorContexts.Commit);};
   models.CellValueChanged+=delegate{UpdateControls();};
   start.Click+=async delegate{await BeginInstallAsync();};cancel.Click+=delegate{if(cancellation!=null) {cancellation.Cancel();transfer.Text="Cancelling safely. Please wait...";cancel.Enabled=false;}};
   open.Click+=delegate{try{if(launch!=null)launch(CurrentDirectory);}catch(Exception e){Append(e.Message);}};
   Shown+=async delegate{await RefreshModelsAsync();};
   FormClosing+=delegate(object sender,FormClosingEventArgs e){if(busy){e.Cancel=true;if(MessageBox.Show(this,"Cancel the current operation? Existing models will be kept.","Downloads in progress",MessageBoxButtons.YesNo,MessageBoxIcon.Question)==DialogResult.Yes&&cancellation!=null)cancellation.Cancel();}};
   UpdateControls();
  }
  static string SizeText(long b) {return b>=1073741824?((double)b/1073741824).ToString("0.00")+" GiB":((double)b/1048576).ToString("0")+" MiB";}
  void AddColumn(string text,float weight){models.Columns.Add(new DataGridViewTextBoxColumn{HeaderText=text,ReadOnly=true,FillWeight=weight,SortMode=DataGridViewColumnSortMode.NotSortable});}
  void Append(string text){status.AppendText(Environment.NewLine+text);}
  public void PickDirectory(string path){folder.Text=path;UpdateControls();}
  public void ChooseModel(string id,bool selected){var row=models.Rows.Cast<DataGridViewRow>().First(r=>(string)r.Tag==id);if(row.Cells[0].ReadOnly&&selected)return;row.Cells[0].Value=selected;UpdateControls();}
  internal void SetBusy(bool value){busy=value;UpdateControls();}
  void UpdateControls(){start.Enabled=CanStart;folder.Enabled=!busy&&!checking&&!manager;browse.Enabled=!busy&&!checking&&!manager;models.Enabled=usable&&!busy&&!checking;desktop.Enabled=!busy;cancel.Enabled=busy&&(cancellation==null||!cancellation.IsCancellationRequested);}
  internal Task RefreshModelsAsync(){if(refreshTask!=null&&!refreshTask.IsCompleted)return refreshTask;refreshTask=RefreshCoreAsync();return refreshTask;}
  async Task RefreshCoreAsync(){
   if(IsDisposed||Disposing)return;
   checking=true;UpdateControls();
   try {
    string directory=CurrentDirectory;
    if(manager) InstallationRecord.Read(directory);
    var states=await Task.Run(()=>Installation.GetModelStates(directory,catalog));
    if(IsDisposed||Disposing)return;
    foreach(var state in states){var row=models.Rows.Cast<DataGridViewRow>().First(r=>(string)r.Tag==state.Id);bool ready=state.Status=="Installed";row.Cells[5].Value=ready?"Installed":state.Status=="Corrupt"?"Repair available":"Available";row.Cells[0].ReadOnly=ready&&manager;if(ready&&manager)row.Cells[0].Value=false;row.DefaultCellStyle.ForeColor=ready?Color.FromArgb(50,112,76):Color.Black;}
   }catch(Exception e){if(!IsDisposed&&!Disposing){Append(e.Message);if(manager){usable=false;start.Visible=false;models.Enabled=false;}}}
   finally{checking=false;if(!IsDisposed&&!Disposing)UpdateControls();}
  }
  async Task BeginInstallAsync(){
   if(!CanStart)return;var ids=SelectedModels;string dir=CurrentDirectory;bool shortcuts=desktop.Checked;
   cancellation=new CancellationTokenSource();SetBusy(true);open.Enabled=false;
   try {
    if(preflight!=null&&!manager)preflight(dir);
    var report=new Progress<TransferProgress>(p=>{
     if(!busy||IsDisposed||Disposing)return;
     string key=p.ArtifactId+" "+p.Phase;if(lastPhase!=key){Append(key);lastPhase=key;}
     if(p.TotalBytes.HasValue&&p.TotalBytes.Value>0){progress.Style=ProgressBarStyle.Continuous;progress.Value=(int)Math.Min(1000,p.BytesReceived*1000/p.TotalBytes.Value);transfer.Text=p.ArtifactId+": "+SizeText(p.BytesReceived)+" / "+SizeText(p.TotalBytes.Value);}
     else {progress.Style=ProgressBarStyle.Marquee;transfer.Text=p.ArtifactId+": "+p.Phase;}
    });
    var result=await Task.Run(async ()=>{using(var tr=new Transfers()){var core=new Installation(tr);return manager?await core.AddModelsAsync(dir,ids,catalog,report,cancellation.Token):await core.InstallAsync(new InstallRequest{Directory=dir,ModelIds=ids,DesktopShortcut=shortcuts},catalog,report,cancellation.Token);}});
    progress.Style=ProgressBarStyle.Continuous;progress.Value=result.Success?1000:0;transfer.Text=result.Message;Append(result.Message);if(result.LogPath!=null)Append("Log: "+result.LogPath);
    if(result.Success){if(!manager&&register!=null)register(InstallationRecord.Read(dir),shortcuts);open.Enabled=launch!=null;start.Text=manager?"Add models":"Install / repair";await RefreshModelsAsync();}
    else {start.Text="Retry";}
   }catch(Exception e){progress.Style=ProgressBarStyle.Continuous;transfer.Text="Operation could not finish.";Append(e.Message);start.Text="Retry";}
   finally{SetBusy(false);cancellation.Dispose();cancellation=null;cancel.Enabled=false;}
  }
 }
}
