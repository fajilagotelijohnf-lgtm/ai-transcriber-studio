param(
    [Parameter(Mandatory=$true)][string]$InstallDir,
    [Parameter(Mandatory=$true)][string]$ResultDir,
    [ValidateSet('ZeroModels','SingleModel','MultipleModels','MissingEngine','EngineFailure','MalformedJson','MissingModel','CloseDuringFinalization')][string]$Case='SingleModel',
    [switch]$CheckDesktopIdentity
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$resultFile=Join-Path $ResultDir 'recording-ui-result.json'
$script:recordingSmokeHandled=$false
$script:recordingSmokeResult=@{Success=$false;Case=$Case;Message='Application.Idle did not run'}

function Assert-RecordingSmoke([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }

# The installed app is loaded unchanged. Idle runs after its real Shown handler,
# then seeds the state that capture normally leaves for the actual Stop button.
# No capture/monitor API is started, and isolated settings disable both sources.
[Windows.Forms.Application]::add_Idle({
    if ($script:recordingSmokeHandled) { return }
    $script:recordingSmokeHandled=$true
    try {
        Assert-RecordingSmoke (-not $chkSys.Checked -and -not $chkMic.Checked) 'Audio source settings were not isolated'
        Assert-RecordingSmoke (-not [AudioEngine.CoreAudio]::IsRecording -and -not [AudioEngine.CoreAudio]::IsMonitoring) 'Capture or monitoring unexpectedly started'
        if ($CheckDesktopIdentity) {
            $identity=[AITranscriberInstaller.DesktopIdentity]::CurrentId()
            Assert-RecordingSmoke ($identity -eq 'AITranscriberStudio.Desktop') ('Unexpected taskbar desktop identity: '+$identity)
            $script:recordingSmokeResult.DesktopIdentity=$identity
        }
        $models=@($cmbFinalModel.Items | ForEach-Object { [string]$_ })
        $expectedCount=if ($Case -eq 'ZeroModels') { 0 } elseif ($Case -eq 'MultipleModels') { 2 } else { 1 }
        Assert-RecordingSmoke ($models.Count -eq $expectedCount) ('Unexpected model dropdown: '+($models -join ', '))
        $selection=@(foreach ($combo in @($cmbLiveModel,$cmbFinalModel,$cmbModel)) {
            $selected=Get-SelectedModel $combo
            [pscustomobject]@{Index=$combo.SelectedIndex;File=if ($null -ne $selected) {$selected.File} else {$null}}
        })
        # Retain discovery evidence even when a regression makes selection null.
        $script:recordingSmokeResult.Models=$models
        $script:recordingSmokeResult.Selections=$selection
        $script:recordingSmokeResult.CatalogType=if ($null -eq $script:ModelCatalog) {'null'} else {$script:ModelCatalog.GetType().FullName}
        $script:recordingSmokeResult.CatalogCount=$script:ModelCatalog.Count
        $master=Join-Path $ResultDir 'Recording_smoke.wav'
        $json=Join-Path $ResultDir 'Recording_smoke.json'
        $transcript=Join-Path $ResultDir 'Recording_smoke_Transcript.txt'
        Assert-RecordingSmoke (-not (Test-Path -LiteralPath $json) -and -not (Test-Path -LiteralPath $transcript)) 'Output directory was not fresh'
        Copy-Item -LiteralPath (Join-Path $ResultDir 'jfk.wav') -Destination $master
        $masterHash=(Get-FileHash -LiteralPath $master -Algorithm SHA256).Hash
        $script:masterWav=$master
        # New app versions already own a private session directory. Legacy
        # reproduction versions used the shared temp root, so isolate those.
        if ((Split-Path -Leaf $script:tempDir) -notlike 'AITranscriber-*') {
            $script:tempDir=Join-Path $ResultDir 'app-temp'
            [void][IO.Directory]::CreateDirectory($script:tempDir)
        }
        $script:chunkWav=Join-Path $script:tempDir 'unused-chunk.wav'
        $script:liveStart=[DateTime]::Now.AddSeconds(-11)
        $script:recordingSessionActive=$true
        $script:recordErrorShown=$true # Seeded capture has already stopped.
        $script:chunkBusy=$false
        $script:chunkRunner=$null
        $script:cancelRequested=$false
        $txtLiveDest.Text=$ResultDir
        $btnRecord.Text='Stop and Build Transcript'
        $txtLiveFeed.Clear()
        if ($Case -eq 'MissingEngine') { $WhisperExe=Join-Path $InstallDir 'missing-whisper-cli.exe' }
        if ($Case -eq 'EngineFailure') { $WhisperExe=$script:FfmpegPath }
        if ($Case -eq 'MissingModel') {
            # Only the isolated hardlink is removed; its source model is untouched.
            $model=Get-SelectedModel $cmbFinalModel
            Assert-RecordingSmoke ($null -ne $model) 'Cannot test a disappearing model because model selection was null'
            Remove-Item -LiteralPath $model.Path -Force
        }
        if ($Case -eq 'MalformedJson') {
            $script:recordingSmokeFormat=${function:Format-Transcript}
            function Format-Transcript {
                param([string]$JsonPath,[string[]]$Vocabulary,[string[]]$Header)
                [IO.File]::WriteAllText($JsonPath,'{ deliberately malformed JSON')
                & $script:recordingSmokeFormat -JsonPath $JsonPath -Vocabulary $Vocabulary -Header $Header
            }
        }
        if ($Case -eq 'CloseDuringFinalization') {
            $script:recordingSmokeCloseRequested=$false
            $script:recordingSmokeCloseDeferred=$false
            $script:recordingSmokeCloseAccepted=$false
            $form.Add_FormClosing({
                param($sender,$event)
                if ($script:recordingSmokeCloseRequested -and -not $event.Cancel -and -not $script:finalizing -and -not $script:uiBusy) {
                    $script:recordingSmokeCloseAccepted=$true
                }
            })
            # Dispatch Close from the Stop handler's first real DoEvents pump.
            # The form must defer disposal while finalization unwinds/cancels.
            [void]$form.BeginInvoke([Action]{
                $script:recordingSmokeCloseRequested=$true
                $form.Close()
                $script:recordingSmokeCloseDeferred=(-not $form.IsDisposed -and $script:cancelRequested -and $script:closeAfterCancel)
            })
        }
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $btnRecord.PerformClick()
        $script:recordingSmokeResult.ElapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,2)
        $script:recordingSmokeResult.Feed=$txtLiveFeed.Text
        Assert-RecordingSmoke (-not $script:recordingSessionActive -and $btnRecord.Enabled -and $btnRecord.Text -eq 'Start Recording') 'Stop did not restore the recording controls'
        Assert-RecordingSmoke (-not [AudioEngine.CoreAudio]::IsRecording -and -not [AudioEngine.CoreAudio]::IsMonitoring) 'Stop test unexpectedly activated audio hardware'
        Assert-RecordingSmoke ((Get-FileHash -LiteralPath $master -Algorithm SHA256).Hash -eq $masterHash) 'Stop changed or removed the master recording'
        Assert-RecordingSmoke (@($script:childProcs).Count -eq 0) 'Stop left process runners behind'
        Assert-RecordingSmoke (@(Get-ChildItem -LiteralPath $ResultDir -Filter '*.ats-job.lock').Count -eq 0) 'Stop left output reservations behind'
        if (Test-Path -LiteralPath $script:tempDir) {
            Assert-RecordingSmoke (@(Get-ChildItem -LiteralPath $script:tempDir -Filter 'ats_final_*.wav*').Count -eq 0) 'Stop left temporary final-pass audio behind'
        }
        if ($Case -eq 'CloseDuringFinalization') {
            Assert-RecordingSmoke ($script:recordingSmokeCloseRequested -and $script:recordingSmokeCloseDeferred) 'Close disposed the form during finalization instead of deferring cancellation'
            # ShowDialog hides/disposes only after this enclosing Idle callback
            # returns. Its accepted second FormClosing is observable right now.
            Assert-RecordingSmoke $script:recordingSmokeCloseAccepted 'Close was not honored after finalization unwound'
            Assert-RecordingSmoke (-not (Test-Path -LiteralPath $transcript)) 'Cancelled finalization wrote a transcript'
            Assert-RecordingSmoke ($pillLive.Caption -eq 'CANCELLED') 'Close cancellation did not report its final state'
            $script:recordingSmokeResult.CloseDeferred=$true
        } elseif ($Case -in @('SingleModel','MultipleModels')) {
            Assert-RecordingSmoke ($pillLive.Caption -eq 'COMPLETE') ('Recording final pass did not complete. '+$txtLiveFeed.Text)
            foreach ($item in $selection) { Assert-RecordingSmoke (-not [string]::IsNullOrWhiteSpace($item.File)) 'An installed model could not be selected' }
            Assert-RecordingSmoke (Test-Path -LiteralPath $transcript -PathType Leaf) ('No final transcript. '+$txtLiveFeed.Text)
            $text=Get-Content -LiteralPath $transcript -Raw -Encoding UTF8
            Assert-RecordingSmoke ($text -match 'country' -and $text -match 'LIVE SESSION TRANSCRIPT' -and $text -match '\[END OF TRANSCRIPT\]') 'Expected complete JFK recording transcript was missing'
            $parsed=Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-RecordingSmoke (@($parsed.transcription).Count -gt 0) 'Final JSON contains no transcription segments'
            Assert-RecordingSmoke ($script:FfmpegPath -and $txtLiveFeed.Text -match 'Running final pass') 'Real FFmpeg/Whisper recording path was not used'
            $script:recordingSmokeResult.Transcript=$transcript
            $script:recordingSmokeResult.Json=$json
            $script:recordingSmokeResult.Segments=@($parsed.transcription).Count
        } else {
            Assert-RecordingSmoke ($pillLive.Caption -ne 'COMPLETE' -and -not (Test-Path -LiteralPath $transcript)) 'A failed final pass reported success or wrote a transcript'
            $expected= switch ($Case) {
                'ZeroModels' { 'model' }
                'MissingEngine' { 'whisper-cli.exe.*not found|not found.*whisper-cli.exe' }
                'EngineFailure' { 'exit|failed|error' }
                'MalformedJson' { 'JSON|ConvertFrom-Json|Invalid|primitive|serialization' }
                'MissingModel' { 'model|failed|exit' }
            }
            Assert-RecordingSmoke ($txtLiveFeed.Text -match '\[error\]' -and $txtLiveFeed.Text -match $expected) ('Missing actionable error diagnostic. '+$txtLiveFeed.Text)
            Assert-RecordingSmoke ($pillLive.Caption -eq 'TRANSCRIPT FAILED') 'Failed finalization did not display its failure state'
            if ($Case -eq 'ZeroModels') {
                foreach ($item in $selection) { Assert-RecordingSmoke ($null -eq $item.File) 'Zero-model selection returned a model' }
            }
        }
        if ($Case -notin @('SingleModel','MultipleModels')) {
            $diagnostic=$master+'.transcription.log'
            Assert-RecordingSmoke (Test-Path -LiteralPath $diagnostic -PathType Leaf) 'Failed finalization did not preserve a diagnostic log beside the recording'
            $diagnosticText=Get-Content -LiteralPath $diagnostic -Raw -Encoding UTF8
            Assert-RecordingSmoke ($diagnosticText.Contains($master) -and $diagnosticText.Length -gt $master.Length) 'Diagnostic log omitted the audio path or failure details'
            $script:recordingSmokeResult.DiagnosticLog=$diagnostic
        }
        if (-not $form.IsDisposed) {
            $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
            try { $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $ResultDir 'recording-main-ui.png')) } finally { $bitmap.Dispose() }
        }
        $script:recordingSmokeResult.Success=$true
        $script:recordingSmokeResult.Message=if ($Case -in @('SingleModel','MultipleModels')) {
            'Actual Stop button, JFK final transcript and cleanup checks passed'
        } elseif ($Case -eq 'CloseDuringFinalization') {
            'Close deferred disposal, cancelled finalization and cleaned up successfully'
        } else { 'Actual Stop button preserved the recording and reported the expected failure' }
    } catch {
        $script:recordingSmokeResult.Message=$_.Exception.Message
        $script:recordingSmokeResult.ErrorPosition=$_.InvocationInfo.PositionMessage
    } finally {
        $script:recordingSessionActive=$false
        $script:recordingSmokeResult.Feed=$txtLiveFeed.Text
        try { $script:recordingSmokeResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultFile -Encoding UTF8 }
        finally { if (-not $form.IsDisposed) { $form.Close() } }
    }
})
try { . (Join-Path $InstallDir 'Transcriber-UI.ps1') }
catch { $script:recordingSmokeResult.Message=$_.Exception.Message;$script:recordingSmokeResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultFile -Encoding UTF8;exit 1 }
if (-not $script:recordingSmokeResult.Success) { exit 1 }
