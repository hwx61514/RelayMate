param(
    [ValidateSet("x86", "x64")]
    [string]$Architecture = "x86"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $projectRoot "windows/RelayMate.Windows/RelayMate.Windows.csproj"
$runtime = if ($Architecture -eq "x86") { "win-x86" } else { "win-x64" }
$assemblyName = "RelayMate-Windows-$Architecture"
$output = Join-Path $projectRoot "dist/RelayMate-Windows-$Architecture"
$zip = Join-Path $projectRoot "dist/RelayMate-Windows-$Architecture.zip"
$zipChecksum = "$zip.sha256"
$singleFileExecutable = Join-Path $projectRoot "dist/RelayMate-Windows-$Architecture.exe"
$singleFileChecksum = "$singleFileExecutable.sha256"

Remove-Item $output -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Remove-Item $zipChecksum -Force -ErrorAction SilentlyContinue
Remove-Item $singleFileExecutable -Force -ErrorAction SilentlyContinue
Remove-Item $singleFileChecksum -Force -ErrorAction SilentlyContinue
New-Item $output -ItemType Directory -Force | Out-Null

dotnet publish $project `
    --configuration Release `
    --runtime $runtime `
    --self-contained true `
    --property:Platform=$Architecture `
    --property:RelayMateExecutableName=$assemblyName `
    --property:WindowsAppSDKSelfContained=true `
    --property:PublishSingleFile=true `
    --property:IncludeAllContentForSelfExtract=true `
    --property:IncludeNativeLibrariesForSelfExtract=true `
    --property:PublishTrimmed=false `
    --output $output
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$publishedExecutable = Join-Path $output "$assemblyName.exe"
if (-not (Test-Path $publishedExecutable)) {
    throw "Windows executable was not produced: $publishedExecutable"
}

& (Join-Path $PSScriptRoot "verify-pe-x86.ps1") -Path $publishedExecutable -ExpectedArchitecture $Architecture
Copy-Item $publishedExecutable $singleFileExecutable
& (Join-Path $PSScriptRoot "verify-pe-x86.ps1") -Path $singleFileExecutable -ExpectedArchitecture $Architecture

Compress-Archive -Path (Join-Path $output "*") -DestinationPath $zip -CompressionLevel Optimal
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$zipHash  $(Split-Path $zip -Leaf)" | Set-Content $zipChecksum -Encoding ascii
$singleFileHash = (Get-FileHash $singleFileExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
"$singleFileHash  $(Split-Path $singleFileExecutable -Leaf)" | Set-Content $singleFileChecksum -Encoding ascii

Write-Output $singleFileExecutable
Write-Output $singleFileChecksum
Write-Output $output
Write-Output $zip
Write-Output $zipChecksum
