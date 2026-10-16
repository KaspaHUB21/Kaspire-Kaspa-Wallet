param([Parameter(Mandatory=$true)][string]$Bundle)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Inspect the final PE files, not merely the compiler command line. Flutter's
# prebuilt engine and external runtimes are not claimed to be rebuilt here.
foreach ($Name in @('kaspire.exe', 'kaspa_secure_core.dll')) {
    $Path = Join-Path $Bundle $Name
    $Bytes = [IO.File]::ReadAllBytes($Path)
    if ($Bytes.Length -lt 256 -or [BitConverter]::ToUInt16($Bytes, 0) -ne 0x5a4d) { throw "Invalid PE: $Name" }
    $Pe = [BitConverter]::ToInt32($Bytes, 0x3c)
    if ($Pe -lt 0 -or $Pe + 264 -gt $Bytes.Length -or [BitConverter]::ToUInt32($Bytes, $Pe) -ne 0x4550) { throw "Invalid PE header: $Name" }
    $Optional = $Pe + 24
    if ([BitConverter]::ToUInt16($Bytes, $Optional) -ne 0x20b) { throw "Expected PE64: $Name" }
    $Flags = [BitConverter]::ToUInt16($Bytes, $Optional + 70)
    # HIGH_ENTROPY_VA | DYNAMIC_BASE | NX_COMPAT | GUARD_CF
    if (($Flags -band 0x4160) -ne 0x4160) { throw "ASLR, high-entropy VA, DEP or CFG missing: $Name" }
    $LoadRva = [BitConverter]::ToUInt32($Bytes, $Optional + 112 + 80)
    $Sections = [BitConverter]::ToUInt16($Bytes, $Pe + 6)
    $SectionTable = $Optional + [BitConverter]::ToUInt16($Bytes, $Pe + 20)
    $Load = -1
    for ($Index = 0; $Index -lt $Sections; $Index++) {
        $Section = $SectionTable + $Index * 40
        $Rva = [BitConverter]::ToUInt32($Bytes, $Section + 12)
        $RawSize = [BitConverter]::ToUInt32($Bytes, $Section + 16)
        $Raw = [BitConverter]::ToUInt32($Bytes, $Section + 20)
        if ($LoadRva -ge $Rva -and [uint64]$LoadRva + 148 -le [uint64]$Rva + $RawSize) { $Load = [int]($Raw + $LoadRva - $Rva); break }
    }
    if ($Load -lt 0 -or $Load + 148 -gt $Bytes.Length -or [BitConverter]::ToUInt32($Bytes, $Load) -lt 148) { throw "CFG load configuration missing: $Name" }
    $GuardFlags = [BitConverter]::ToUInt32($Bytes, $Load + 144)
    $GuardTable = [BitConverter]::ToUInt64($Bytes, $Load + 128)
    $GuardCount = [BitConverter]::ToUInt64($Bytes, $Load + 136)
    if (($GuardFlags -band 0x500) -ne 0x500 -or $GuardTable -eq 0 -or $GuardCount -eq 0) { throw "CFG instrumentation or function table missing: $Name" }
    Write-Host "PASSED: $Name has ASLR, high-entropy VA, DEP and instrumented CFG ($GuardCount targets)."
}
