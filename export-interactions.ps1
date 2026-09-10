# File attribution
# created by Christian Stelmach (chrisp.stel@gmail.com), GitHub: @cstelmach
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'interaction-exports'),
    [string]$ComposeFile = ''
)
$ErrorActionPreference = 'Stop'
if (!$ComposeFile) {
    $Workspace = Split-Path $PSScriptRoot -Parent
    if ((Split-Path $Workspace -Leaf) -eq 'pain-setup-worktrees') { $Workspace = Split-Path $Workspace -Parent }
    $ComposeFile = Join-Path $Workspace 'docker-compose.yml'
}
if (!(Test-Path -LiteralPath $ComposeFile -PathType Leaf)) { throw "Compose file not found: $ComposeFile" }
$Docker = (Get-Command docker -CommandType Application | Select-Object -First 1).Source
$ContainerId = (& $Docker compose -f $ComposeFile ps -q pain-db | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $ContainerId -notmatch '^[a-f0-9]+$') { throw 'Expected one running pain-db container.' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$Name = 'pain-interactions-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$Staging = Join-Path $OutputDirectory $Name
[void][IO.Directory]::CreateDirectory($Staging)
$Csv = Join-Path $Staging 'interaction-events.csv'
$Summary = Join-Path $Staging 'summary.json'
Write-Host "Exporting interaction events. Failure diagnostics remain in $Staging"
# Read both pipes asynchronously; CSV bytes stream to disk instead of accumulating in PowerShell.
$Info = New-Object Diagnostics.ProcessStartInfo
$Info.FileName = $Docker
$Info.Arguments = 'exec -i ' + $ContainerId + ' sh -c "exec psql -X -q -A -t --set=ON_ERROR_STOP=1 --username=$POSTGRES_USER --dbname=$POSTGRES_DB"'
$Info.UseShellExecute = $false
$Info.RedirectStandardInput = $true
$Info.RedirectStandardOutput = $true
$Info.RedirectStandardError = $true
$Process = New-Object Diagnostics.Process
$Process.StartInfo = $Info
$CsvStream = [IO.File]::Create($Csv)
$SummaryStream = [IO.File]::Create($Summary)
try {
    [void]$Process.Start()
    $CsvCopy = $Process.StandardOutput.BaseStream.CopyToAsync($CsvStream)
    $SummaryCopy = $Process.StandardError.BaseStream.CopyToAsync($SummaryStream)
    $Process.StandardInput.Write([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'export-interactions.sql')))
    $Process.StandardInput.Close()
    $Process.WaitForExit()
    $CsvCopy.GetAwaiter().GetResult()
    $SummaryCopy.GetAwaiter().GetResult()
    if ($Process.ExitCode -ne 0) { throw "Database export failed. Read $Summary" }
} finally {
    $CsvStream.Dispose()
    $SummaryStream.Dispose()
    $Process.Dispose()
}
$null = Get-Content -Raw -LiteralPath $Summary | ConvertFrom-Json
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'interaction-data-dictionary.txt') -Destination (Join-Path $Staging 'data-dictionary.txt')
$Archive = "$Staging.zip"
# The platform ZIP API streams large CSV files; Compress-Archive has a 2 GiB file-size limit.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($Staging, "$Archive.partial")
[IO.File]::Move("$Archive.partial", $Archive)
# Only this invocation's completed staging directory is removed; failures retain diagnostics.
Remove-Item -LiteralPath $Csv, $Summary, (Join-Path $Staging 'data-dictionary.txt')
Remove-Item -LiteralPath $Staging
Write-Host "Export ready: $Archive"
Write-Host 'Copy this ZIP to your USB stick. The database was not changed.'
