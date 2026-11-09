$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'resources\Transcriber-UI.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'App parse errors.' }
$node = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-ForProcess' }, $true)[0]
. ([scriptblock]::Create($node.Extent.Text))
Add-Type -AssemblyName System.Windows.Forms
$script:uiBusy = $false; $script:cancelRequested = $false
$pass = 0; $fail = 0
function Check($name, [scriptblock]$body) {
    try { & $body; $script:pass++; "PASS $name" }
    catch { $script:fail++; "FAIL $name : $($_.Exception.Message)" }
}
function New-Runner([bool]$Exited, [int]$Code, [string]$ErrorText) {
    $runner = [pscustomobject]@{ HasExited = $Exited; ExitCode = $Code; ErrorText = $ErrorText; OutputText = ''; Killed = $false; Waited = $false }
    $runner | Add-Member ScriptMethod DrainError { $value = $this.ErrorText; $this.ErrorText = ''; return $value }
    $runner | Add-Member ScriptMethod DrainOutput { $value = $this.OutputText; $this.OutputText = ''; return $value }
    $runner | Add-Member ScriptMethod Kill { $this.Killed = $true; $this.HasExited = $true }
    $runner | Add-Member ScriptMethod WaitForExit { param($milliseconds) $this.Waited = $true }
    return $runner
}
Check 'stderr survives the final output callback on a failed native process' {
    $runner = New-Runner $true 7 'NATIVE_FAILURE_MARKER'
    $message = ''
    try { $null = Wait-ForProcess -Runner $runner -OnOutput { param($o, $e) } }
    catch { $message = $_.Exception.Message }
    if ($message -notmatch 'NATIVE_FAILURE_MARKER' -or $message -notmatch '7') { throw "Native diagnostics lost: $message" }
    if ($script:uiBusy) { throw 'Process failure left the UI busy.' }
}
Check 'stderr consumed during progress polling remains available at failure' {
    $runner = New-Runner $false 9 'EARLY_FAILURE_MARKER'
    $script:diagnosticRunner = $runner
    $message = ''
    try {
        $null = Wait-ForProcess -Runner $runner -OnOutput { param($o, $e) $script:diagnosticRunner.HasExited = $true }
    } catch { $message = $_.Exception.Message }
    finally { $script:diagnosticRunner = $null }
    if ($message -notmatch 'EARLY_FAILURE_MARKER') { throw "Polled diagnostics lost: $message" }
}
Check 'large stderr retains its final diagnostic with a bounded failure message' {
    $runner = New-Runner $true 8 (('x' * 100000) + 'FINAL_FAILURE_MARKER')
    $message = ''
    try { $null = Wait-ForProcess -Runner $runner -OnOutput { param($o, $e) } }
    catch { $message = $_.Exception.Message }
    if ($message -notmatch 'FINAL_FAILURE_MARKER' -or $message.Length -gt 65536) { throw 'Failure diagnostics were lost or grew without a bound.' }
}
Check 'successful process still delivers trailing output exactly once' {
    $runner = New-Runner $true 0 'SUCCESS_STDERR'
    $runner.OutputText = 'SUCCESS_STDOUT'
    $script:callbackText = ''
    $finished = Wait-ForProcess -Runner $runner -OnOutput { param($o, $e) $script:callbackText += $o + $e }
    if (-not $finished -or $script:callbackText -ne 'SUCCESS_STDOUTSUCCESS_STDERR') { throw 'Trailing output delivery changed.' }
}
Check 'cancellation restores an already active outer UI latch' {
    $runner = New-Runner $false 0 ''
    $script:uiBusy = $true; $script:cancelRequested = $true
    try {
        $finished = Wait-ForProcess -Runner $runner -Cancellable -OnOutput { param($o, $e) }
        if ($finished -or -not $runner.Killed -or -not $runner.Waited -or -not $script:uiBusy) { throw 'Cancellation lost the outer busy state or failed to stop and await its process.' }
    } finally { $script:uiBusy = $false; $script:cancelRequested = $false }
}
Check 'timeout restores an already active outer UI latch' {
    $runner = New-Runner $false 0 ''
    $script:uiBusy = $true
    $message = ''
    try {
        try { $null = Wait-ForProcess -Runner $runner -TimeoutSeconds 0.01 -OnOutput { param($o, $e) } }
        catch { $message = $_.Exception.Message }
        if ($message -notmatch 'timed out' -or -not $runner.Killed -or -not $runner.Waited -or -not $script:uiBusy) { throw 'Timeout lost the outer busy state or failed to stop and await its process.' }
    } finally { $script:uiBusy = $false }
}
"PROCESS DIAGNOSTICS RESULT $pass passed, $fail failed"
if ($fail) { exit 1 }
