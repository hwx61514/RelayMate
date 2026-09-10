param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [ValidateSet("x86", "x64")]
    [string]$ExpectedArchitecture = "x86"
)

$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $Path))
if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
    throw "$Path is not a PE executable (missing MZ header)."
}
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length) {
    throw "$Path has an invalid PE header offset."
}
if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45) {
    throw "$Path is not a PE executable (missing PE signature)."
}
$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
$expected = if ($ExpectedArchitecture -eq "x86") { 0x014C } else { 0x8664 }
if ($machine -ne $expected) {
    throw ("Expected {0} PE machine 0x{1:X4}, got 0x{2:X4}." -f $ExpectedArchitecture, $expected, $machine)
}
Write-Output ("Verified {0} PE executable: {1}" -f $ExpectedArchitecture, $Path)
