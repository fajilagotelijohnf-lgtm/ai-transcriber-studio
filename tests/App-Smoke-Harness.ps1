param([Parameter(Mandatory=$true)][string]$InstallDir,[Parameter(Mandatory=$true)][string]$ResultDir)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SmokeProcessTree {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct Entry {
        public uint Size, Usage, ProcessId;
        public UIntPtr Heap;
        public uint Module, Threads, ParentId;
        public int Priority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string Name;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", EntryPoint="Process32FirstW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool First(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32.dll", EntryPoint="Process32NextW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool Next(IntPtr snapshot, ref Entry entry);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static int[] Children(int parent) {
        var snapshot=CreateToolhelp32Snapshot(2,0);
        if(snapshot==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            var entry=new Entry();entry.Size=(uint)Marshal.SizeOf(typeof(Entry));
            var result=new List<int>();
            if(!First(snapshot,ref entry)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            do { if(entry.ParentId==(uint)parent) result.Add((int)entry.ProcessId); } while(Next(snapshot,ref entry));
            return result.ToArray();
        } finally { CloseHandle(snapshot); }
    }
}
'@
$resultFile=Join-Path $ResultDir 'app-ui-result.json'
$script:smokeResult=@{Success=$false;Models=@();Message='UI timer did not run'}
$script:smokeHandled=$false
$script:smokeOwnedManagers=New-Object System.Collections.ArrayList

function Wait-SmokeCondition {
    param([scriptblock]$Condition,[string]$Message,[int]$TimeoutMs=15000)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($clock.ElapsedMilliseconds -ge $TimeoutMs) { throw $Message }
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
}
function Pump-SmokeEvents {
    param([int]$Milliseconds=1200)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $Milliseconds) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
}
function Get-SmokeSelection {
    @($cmbLiveModel,$cmbFinalModel,$cmbModel) | ForEach-Object { (Get-SelectedModel $_).File }
}
function Get-SmokeManagerChildren {
    $expected=[IO.Path]::GetFullPath((Join-Path $InstallDir 'AITranscriber.exe'))
    # Toolhelp works without the optional CIM/WMI permissions of the test machine.
    $children=@(foreach ($childId in [SmokeProcessTree]::Children($PID)) {
        $candidate=$null
        try {
            $candidate=[Diagnostics.Process]::GetProcessById($childId)
            if ($candidate.MainModule.FileName -eq $expected) { [pscustomobject]@{ProcessId=$candidate.Id;ExecutablePath=$candidate.MainModule.FileName} }
        } catch [ArgumentException] { } # An unrelated child can exit during enumeration.
        finally { if ($null -ne $candidate) { $candidate.Dispose() } }
    })
    # Track even an erroneous duplicate so a failed assertion leaves no test window.
    foreach ($child in $children) {
        if (-not @($script:smokeOwnedManagers | Where-Object { $_.Id -eq $child.ProcessId }).Count) {
            [void]$script:smokeOwnedManagers.Add([Diagnostics.Process]::GetProcessById($child.ProcessId))
        }
    }
    return $children
}
function Open-SmokeManager {
    $btnManageModels.PerformClick()
    Wait-SmokeCondition { $null -ne $script:modelManagerProcess } 'The main UI did not start its model manager'
    $owned=[Diagnostics.Process]::GetProcessById($script:modelManagerProcess.Id)
    $null=$owned.Handle # Retain a native handle so exit status remains queryable after exit.
    [void]$script:smokeOwnedManagers.Add($owned)
    Wait-SmokeCondition { $owned.Refresh(); -not $owned.HasExited -and $owned.MainWindowHandle -ne [IntPtr]::Zero } 'The owned model manager did not open a window'
    if ($owned.MainWindowTitle -notmatch 'Manage Models') { throw ('Unexpected manager window: '+$owned.MainWindowTitle) }
    $children=@(Get-SmokeManagerChildren)
    if ($children.Count -ne 1 -or $children[0].ProcessId -ne $owned.Id) { throw 'Expected exactly one model-manager child owned by this harness' }
    if ($btnManageModels.Enabled) { throw 'Manage Models button was not disabled while its window was open' }
    return $owned
}
function Close-SmokeManager {
    param([Diagnostics.Process]$Owned)
    if ($Owned.HasExited) { throw 'The owned manager exited unexpectedly before the close test' }
    if (-not $Owned.CloseMainWindow()) { throw 'Could not close the owned test manager window' }
    Wait-SmokeCondition { $Owned.HasExited } 'The owned test manager did not exit after close'
    [void]$Owned.WaitForExit(1000)
    if ($Owned.ExitCode -ne 0) { throw ('The owned manager failed with exit code '+$Owned.ExitCode) }
}
function Assert-SmokeTranscript {
    param([string]$BaseName)
    if ($script:fileBusy -or $pillFile.Caption -ne 'COMPLETE') { throw ('File transcription did not complete. Status: '+$txtStatus.Text) }
    $transcript=Join-Path $ResultDir ($BaseName+'_Transcript.txt')
    $jsonPath=Join-Path $ResultDir ($BaseName+'.json')
    if (-not (Test-Path -LiteralPath $transcript -PathType Leaf)) { throw ('No fresh transcript. Status: '+$txtStatus.Text) }
    $text=Get-Content -LiteralPath $transcript -Raw -Encoding UTF8 -ErrorAction Stop
    if ($text -notmatch 'country' -or $text -notmatch '\[END OF TRANSCRIPT\]') { throw 'The expected complete JFK speech was not present in the transcript' }
    $json=Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (@($json.transcription).Count -eq 0) { throw 'Missing fresh transcription JSON segments' }
    if (@($script:childProcs).Count -ne 0) { throw 'Finished file jobs retained child process runners' }
    return [pscustomobject]@{Transcript=$transcript;Json=$jsonPath;Segments=@($json.transcription).Count}
}

[System.Windows.Forms.Application]::add_Idle({
    if ($script:smokeHandled) { return }
    $script:smokeHandled=$true
    try {
        $modelNames=@($cmbModel.Items | ForEach-Object { [string]$_ })
        if ($modelNames.Count -lt 2 -or -not ($modelNames -match '^Small') -or -not ($modelNames -match '^Medium')) { throw 'Small and Medium were not both discovered in the model dropdown' }
        if ($null -eq $btnManageModels -or $btnManageModels.Text -ne 'Download / Manage Models') { throw 'The main UI is missing its Download / Manage Models button' }
        $exeIcon=[Drawing.Icon]::ExtractAssociatedIcon((Join-Path $InstallDir 'AITranscriber.exe'))
        $iconHashes=@(foreach($icon in @($exeIcon,$form.Icon)){
            $bmp=$icon.ToBitmap();$memory=New-Object IO.MemoryStream;$sha=[Security.Cryptography.SHA256]::Create()
            try{$bmp.Save($memory,[Drawing.Imaging.ImageFormat]::Png);[BitConverter]::ToString($sha.ComputeHash($memory.ToArray()))}
            finally{$bmp.Dispose();$memory.Dispose();$sha.Dispose()}
        })
        $exeIcon.Dispose()
        if($iconHashes[0] -ne $iconHashes[1]){throw 'Main window does not use the installed EXE icon'}
        if ([AudioEngine.CoreAudio]::IsRecording -or [AudioEngine.CoreAudio]::IsMonitoring) { throw 'Smoke isolation unexpectedly activated audio capture or monitoring' }
        $cmbLiveModel.SelectedIndex=$cmbLiveModel.Items.Count-1
        $cmbFinalModel.SelectedIndex=0
        $cmbModel.SelectedIndex=$cmbModel.Items.Count-1
        $selectedBefore=@(Get-SmokeSelection) -join '|'
        $manager=Open-SmokeManager
        $managerId=$manager.Id
        $btnManageModels.PerformClick()
        # Dispatch an already queued duplicate Click while the button is disabled.
        $onClick=[Windows.Forms.Control].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
        [void]$onClick.Invoke($btnManageModels,@([EventArgs]::Empty))
        Pump-SmokeEvents -Milliseconds 600
        $children=@(Get-SmokeManagerChildren)
        if ($children.Count -ne 1 -or $children[0].ProcessId -ne $managerId -or $script:modelManagerProcess.Id -ne $managerId) { throw 'A duplicate manager click spawned another child process' }
        Close-SmokeManager $manager
        Wait-SmokeCondition { $null -eq $script:modelManagerProcess -and $btnManageModels.Enabled -and -not $script:modelRefreshPending } 'Manager close did not re-enable the button and refresh models'
        if ((@(Get-SmokeSelection) -join '|') -ne $selectedBefore) { throw 'Manager refresh changed a selected model' }
        if ($txtStatus.Text -notmatch 'Model list refreshed') { throw 'The model refresh timer did not report a refresh' }

        $manager=Open-SmokeManager
        $script:fileBusy=$true
        $statusBefore=$txtStatus.Text
        Close-SmokeManager $manager
        Wait-SmokeCondition { $null -eq $script:modelManagerProcess -and $btnManageModels.Enabled -and $script:modelRefreshPending } 'Manager close while busy did not defer refresh'
        Pump-SmokeEvents
        if (-not $script:modelRefreshPending -or $txtStatus.Text -ne $statusBefore) { throw 'Model refresh ran while file transcription was marked busy' }
        if ((@(Get-SmokeSelection) -join '|') -ne $selectedBefore) { throw 'Deferred refresh changed a selected model while busy' }
        $script:fileBusy=$false
        Wait-SmokeCondition { -not $script:modelRefreshPending -and $txtStatus.Text -ne $statusBefore } 'Deferred refresh did not run after the UI became idle'
        if ((@(Get-SmokeSelection) -join '|') -ne $selectedBefore) { throw 'Deferred model refresh did not preserve selections' }
        $btnTabFile.PerformClick()
        $cmbModel.SelectedIndex=0
        $txtInput.Text=Join-Path $ResultDir 'jfk.wav'
        $txtOutput.Text=$ResultDir
        foreach ($name in @('jfk.json','jfk_Transcript.txt','jfk_2.json','jfk_2_Transcript.txt')) {
            if (Test-Path -LiteralPath (Join-Path $ResultDir $name)) { throw ('Smoke result was not fresh: '+$name) }
        }
        $sourceHash=(Get-FileHash -LiteralPath $txtInput.Text -Algorithm SHA256 -ErrorAction Stop).Hash
        $btnStart.PerformClick()
        $first=Assert-SmokeTranscript 'jfk'
        $firstTextHash=(Get-FileHash -LiteralPath $first.Transcript -Algorithm SHA256 -ErrorAction Stop).Hash
        $firstJsonHash=(Get-FileHash -LiteralPath $first.Json -Algorithm SHA256 -ErrorAction Stop).Hash
        $btnStart.PerformClick()
        $second=Assert-SmokeTranscript 'jfk_2'
        if ((Get-FileHash -LiteralPath $first.Transcript -Algorithm SHA256 -ErrorAction Stop).Hash -ne $firstTextHash -or (Get-FileHash -LiteralPath $first.Json -Algorithm SHA256 -ErrorAction Stop).Hash -ne $firstJsonHash) { throw 'Repeated transcription overwrote its original outputs' }
        if ((Get-FileHash -LiteralPath $txtInput.Text -Algorithm SHA256 -ErrorAction Stop).Hash -ne $sourceHash) { throw 'Transcription changed the input audio' }
        if (@(Get-ChildItem -LiteralPath $ResultDir -Filter '*.ats-job.lock' -ErrorAction Stop).Count -ne 0) { throw 'Completed file jobs left output reservations behind' }
        $screenshot=Join-Path $ResultDir 'transcriber-main-ui.png'
        $bitmap=New-Object System.Drawing.Bitmap($form.Width,$form.Height)
        try { $form.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($screenshot) } finally { $bitmap.Dispose() }
        $script:smokeResult=@{Success=$true;Models=$modelNames;Message='Main UI manager, duplicate guard, selection preservation, busy refresh deferral and two fresh JFK transcriptions passed';ManagerIntegration=$true;DeferredRefresh=$true;OriginalOutputsPreserved=$true;Transcript=$first.Transcript;SecondTranscript=$second.Transcript;Segments=$first.Segments;SecondSegments=$second.Segments;Screenshot=$screenshot}
    } catch { $script:smokeResult=@{Success=$false;Models=@();Message=$_.Exception.Message} }
    finally {
        $script:fileBusy=$false
        foreach ($owned in @($script:smokeOwnedManagers)) {
            try {
                if (-not $owned.HasExited) { [void]$owned.CloseMainWindow();if (-not $owned.WaitForExit(3000)) { $owned.Kill();[void]$owned.WaitForExit(3000) } }
                $owned.Dispose()
            } catch { }
        }
        try { $script:smokeResult | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultFile -Encoding UTF8 -ErrorAction Stop }
        finally { $form.Close() }
    }
})
try { . (Join-Path $InstallDir 'Transcriber-UI.ps1') }
catch { @{Success=$false;Message=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $resultFile -Encoding UTF8; exit 1 }
if (-not $script:smokeResult.Success) { exit 1 }
