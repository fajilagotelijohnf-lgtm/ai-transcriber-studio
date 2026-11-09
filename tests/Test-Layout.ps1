param(
    [string]$SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'resources\Transcriber-UI.ps1'),
    [string]$ResultDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'test-results\layout')
)
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File tests\Test-Layout.ps1' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$source = [IO.File]::ReadAllText([IO.Path]::GetFullPath($SourcePath))
$tokens = $null; $parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ('UI parse error: ' + $parseErrors[0].Message) }

# Execute only the real visual construction code. No application settings,
# AudioEngine, audio devices, lifecycle handlers, timers or child processes run.
$helperStart = $source.IndexOf('function C (')
$helperEnd = $source.IndexOf('#  TOOL / MODEL DISCOVERY')
$shellStart = $source.IndexOf('$M      = 24')
$shellEnd = $source.IndexOf('#  STATE')
if ($helperStart -lt 0 -or $helperEnd -le $helperStart -or $shellStart -lt 0 -or $shellEnd -le $shellStart) { throw 'Cannot find isolated visual construction boundaries' }
$helpers = $source.Substring($helperStart, $helperEnd - $helperStart)
$shell = $source.Substring($shellStart, $shellEnd - $shellStart)
$WhisperDir = Join-Path $ResultDir 'empty-app'
[void][IO.Directory]::CreateDirectory($WhisperDir)
$script:Settings = @{UseSystem=$false;UseMic=$false;SaveFolder='';Vocabulary='';FileVocabulary=''}
. ([scriptblock]::Create($helpers))

$probe = New-Object Windows.Forms.Form
$graphics = $probe.CreateGraphics()
try { $hostDpi = [double]$graphics.DpiX } finally { $graphics.Dispose(); $probe.Dispose() }
$script:layoutPass = 0
$script:layoutFail = 0
$script:layoutSamples = New-Object Collections.ArrayList
$script:layoutFailures = New-Object Collections.ArrayList
$paintMethod = [Windows.Forms.Control].GetMethod('OnPaint', [Reflection.BindingFlags]'NonPublic,Instance')
function Require-Layout([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Check-Layout([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:layoutPass++; Write-Output ('PASS ' + $Name) }
    catch {
        $script:layoutFail++
        [void]$script:layoutFailures.Add([ordered]@{Name=$Name;Message=$_.Exception.Message})
        Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message)
    }
}
function Assert-LayoutBody($Body, $RunCard, $Log, $Action, [double]$Scale) {
    Require-Layout ($Body.Parent -eq $contentViewport) 'Tab body must be in the scroll viewport'
    Require-Layout ($Log.Height -ge [Math]::Floor(160 * $Scale)) ('Transcript/status area collapsed: ' + $Log.Bounds)
    Require-Layout ($Action.Top -ge $Log.Bottom + [Math]::Floor(8 * $Scale)) 'Action overlaps the transcript/status area'
    Require-Layout ($Action.Bottom -le $RunCard.ClientSize.Height) 'Action extends outside its card'
    Require-Layout ($RunCard.Bottom -le $Body.Height) 'Run card extends outside its tab canvas'
    Require-Layout ($contentViewport.AutoScroll) 'Tab viewport must scroll when the canvas cannot fit'
    # AutoScrollMinSize is a physical extent and must include both the entire
    # canvas and the lower/right margins, even with a nested action button.
    Require-Layout ($contentViewport.AutoScrollMinSize.Height -ge $Body.Height + [Math]::Floor(20 * $Scale)) 'Bottom action is not reachable with a lower margin'
    Require-Layout ($contentViewport.AutoScrollMinSize.Width -ge $Body.Width + [Math]::Floor(40 * $Scale)) 'Right edge is not reachable with side margins'
}

# These exercise the same WinForms DPI scale operation without changing the
# user's monitor configuration. Fonts remain rendered at the host monitor DPI;
# this suite verifies geometry, not high-DPI raster/text rendering.
foreach ($targetDpi in @(96,120,144,192)) {
    $scale = $targetDpi / 96.0
    $baseline = ($hostDpi / $scale).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    $caseShell = [regex]::Replace($shell,
        '\[System\.Drawing\.SizeF\]::new\(96,\s*96\)',
        ('[System.Drawing.SizeF]::new(' + $baseline + ', ' + $baseline + ')'))
    # Layout's scale must agree with the simulated AutoScaleDimensions ratio.
    $caseShell = $caseShell.Replace('$form.CurrentAutoScaleDimensions.Width', [string]$targetDpi)
    foreach ($workSize in @(@(1366,728),@(1920,1040))) {
        $area = New-Object Drawing.Rectangle(73,41,$workSize[0],$workSize[1])
        $label = ('{0} DPI / workarea {1}x{2}' -f $targetDpi,$workSize[0],$workSize[1])
        $form = $null
        try {
            . ([scriptblock]::Create($caseShell))
            $form.ResumeLayout($true)
            Check-Layout ($label + ' construction scales the whole tree together') {
                Require-Layout ($header.Width -eq $form.ClientSize.Width) ('Mixed DPI construction leaves blank width: header=' + $header.Width + ', client=' + $form.ClientSize.Width)
            }
            if (-not (Get-Command Update-AppLayout -ErrorAction SilentlyContinue)) { throw 'Missing Update-AppLayout scroll and workarea helper' }
            Update-AppLayout -WorkingArea $area -ConstrainWindow
            Check-Layout ($label + ' startup fills width and fits workarea') {
                Require-Layout ($header.Width -eq $form.ClientSize.Width) ('Header leaves blank width: header=' + $header.Width + ', client=' + $form.ClientSize.Width)
                Require-Layout ($tabStrip.Width -eq $form.ClientSize.Width) 'Tab strip leaves blank width'
                Require-Layout ($form.Width -le $area.Width -and $form.Height -le $area.Height) 'Window exceeds workarea'
                Require-Layout ($form.Left -ge $area.Left -and $form.Top -ge $area.Top -and $form.Right -le $area.Right -and $form.Bottom -le $area.Bottom) 'Window lies outside workarea'
                Require-Layout ($contentViewport.Bottom -le $form.ClientSize.Height) 'Viewport extends below client area'
            }
            Check-Layout ($label + ' custom paints scale and restore graphics state') {
                $vuSys.Level = 0.55; $vuSys.Peak = 0.7
                $progressBar.Value = 0.6
                $pillLive.Tone = 'rec'; $pillLive.Pulse = 0.5
                foreach ($control in @($header,$cardSrc,$btnTabLive,$vuSys,$progressBar,$pillLive)) {
                    # Render only our own isolated control into a memory bitmap.
                    # This never reads the desktop or another application's UI.
                    $bitmap = [Drawing.Bitmap]::new($control.Width,$control.Height)
                    $graphics = [Drawing.Graphics]::FromImage($bitmap)
                    $paintArgs = [Windows.Forms.PaintEventArgs]::new($graphics,[Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height))
                    try {
                        $unit = $graphics.PageUnit
                        $transform = $graphics.Transform.Elements -join ','
                        $previousErrors = $Error.Count
                        $null = $paintMethod.Invoke($control,@($paintArgs))
                        Require-Layout ($Error.Count -eq $previousErrors) 'A custom paint handler raised an error'
                        Require-Layout ($graphics.PageUnit -eq $unit -and ($graphics.Transform.Elements -join ',') -eq $transform) 'A custom paint handler leaked its Graphics transform'
                    } finally { $paintArgs.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
                }
                $paintFont = Get-AppPaintFont $FontTitle
                Require-Layout ([Object]::ReferenceEquals($paintFont,(Get-AppPaintFont $FontTitle))) 'Repaints allocate another font instead of reusing the cache'
                Require-Layout ($paintFont.Unit -eq [Drawing.GraphicsUnit]::Pixel) 'Paint fonts must use pixels to avoid a second DPI expansion'
                Require-Layout ([Math]::Abs($paintFont.Size - $FontTitle.SizeInPoints * 96.0 / 72.0) -lt 0.01) 'Paint font has the wrong logical pixel size'
            }
            foreach ($size in @(@($form.ClientSize.Width,$form.ClientSize.Height),@(960,600),@(1280,900))) {
                $form.ClientSize = New-Object Drawing.Size($size[0],$size[1])
                Update-AppLayout -WorkingArea $area
                $sizeLabel = $label + (' / client {0}x{1}' -f $form.ClientSize.Width,$form.ClientSize.Height)
                Check-Layout ($sizeLabel + ' live transcript remains reachable') { Assert-LayoutBody $pnlLive $cardFeed $txtLiveFeed $btnRecord $scale }
                Check-Layout ($sizeLabel + ' file status remains reachable') { Assert-LayoutBody $pnlFile $cardFileRun $txtStatus $btnStart $scale }
                Check-Layout ($sizeLabel + ' resizing fills header width') { Require-Layout ($header.Width -eq $form.ClientSize.Width) 'Header width failed after resize' }
                Check-Layout ($sizeLabel + ' recognition columns retain their right margin') {
                    Require-Layout ($cmbLang.Right -le $cardRec.ClientSize.Width - [Math]::Floor(16 * $scale)) 'Live language field is clipped by its card edge'
                    Require-Layout ($cmbFileLang.Right -le $cardFileAi.ClientSize.Width - [Math]::Floor(16 * $scale)) 'File language field is clipped by its card edge'
                }
                Check-Layout ($sizeLabel + ' tab actions remain separate and reachable') {
                    Require-Layout ($btnTabFile.Left -ge $btnTabLive.Right) 'Live and File tab buttons overlap'
                    Require-Layout ($btnManageModels.Left -ge $btnTabFile.Right) 'Model manager overlaps the File tab button'
                    if ($btnManageModels.Right -gt $tabStrip.ClientSize.Width) {
                        Require-Layout ($tabStrip.AutoScroll -and $tabStrip.AutoScrollMinSize.Width -ge $btnManageModels.Right) 'Model manager is outside the tab strip with no scroll reachability'
                    }
                }
                [void]$script:layoutSamples.Add([ordered]@{
                    TargetDpi=$targetDpi;HostDpi=$hostDpi;WorkWidth=$area.Width;WorkHeight=$area.Height
                    ClientWidth=$form.ClientSize.Width;ClientHeight=$form.ClientSize.Height
                    HeaderWidth=$header.Width;ViewportWidth=$contentViewport.Width;ViewportHeight=$contentViewport.Height
                    CanvasWidth=$pnlLive.Width;CanvasHeight=$pnlLive.Height
                    FeedHeight=$txtLiveFeed.Height;StatusHeight=$txtStatus.Height
                    ScrollWidth=$contentViewport.AutoScrollMinSize.Width;ScrollHeight=$contentViewport.AutoScrollMinSize.Height
                })
            }
        } catch {
            $script:layoutFail++
            [void]$script:layoutFailures.Add([ordered]@{Name=$label;Message=$_.Exception.Message})
            Write-Output ('FAIL ' + $label + ': ' + $_.Exception.Message)
        }
        finally { if ($null -ne $form) { $form.Dispose() } }
    }
}
[ordered]@{Passed=$script:layoutPass;Failed=$script:layoutFail;GeometrySimulation=$true;Failures=@($script:layoutFailures);Samples=@($script:layoutSamples)} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ResultDir 'layout-results.json') -Encoding UTF8
Write-Output ('Layout checks: {0} passed, {1} failed; results: {2}' -f $script:layoutPass,$script:layoutFail,(Join-Path $ResultDir 'layout-results.json'))
foreach ($paintFont in $script:PaintFontCache.Values) { $paintFont.Dispose() }
$script:PaintFontCache.Clear()
if ($script:layoutFail) { exit 1 }
