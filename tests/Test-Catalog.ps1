$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $root 'resources\dependencies.json'
if (-not (Test-Path -LiteralPath $catalogPath)) { throw 'RED: dependency catalog does not exist' }
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
if ($catalog.Models.Count -ne 9) { throw 'Expected nine models' }
if (@($catalog.Models.FileName | Sort-Object -Unique).Count -ne 9) { throw 'Duplicate model filename' }
if ($catalog.OriginalScriptSha256 -ne '0F9919B1FAD54F41032B39349A206E0D18A6EBB11FA1E5EC1A0F77ED91E35AF0') { throw 'Wrong source provenance' }
foreach ($item in @($catalog.Whisper,$catalog.Ffmpeg) + @($catalog.Models)) {
    if ($item.Url -notlike 'https://*' -or $item.Hash -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid artifact $($item.Id)" }
}
$hash = (Get-FileHash -LiteralPath (Join-Path $root 'resources\Transcriber-UI.ps1') -Algorithm SHA256).Hash
if ($hash -ne $catalog.ScriptSha256) { throw 'Packaged script integrity mismatch' }
'PASS catalog: nine pinned models, HTTPS/SHA256, packaged script integrity and source provenance'
