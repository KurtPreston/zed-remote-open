<#
    Shared Zed CLI discovery, dot-sourced by install-zed-listener.ps1 and
    check-zed-remote-open.ps1.

    Zed on Windows ships its CLI as bin\Zed.exe inside the install directory and
    does not add it to PATH, so PATH lookup is the least reliable strategy here,
    not the first one. The large Zed.exe at the install root is the GUI binary;
    the small one under bin\ is the CLI shim we want.
#>

function Get-ZedCliCandidate {
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $roots.Add((Join-Path $base 'Programs\Zed'))
        $roots.Add((Join-Path $base 'Zed'))
    }

    # Whatever the installer recorded, in case Zed lives somewhere unusual.
    foreach ($hive in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )) {
        foreach ($entry in @(Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue)) {
            # Uninstall keys are irregular; many have neither property at all.
            $props = $entry.PSObject.Properties.Name
            if ($props -notcontains 'DisplayName' -or $props -notcontains 'InstallLocation') { continue }
            if ($entry.DisplayName -notlike 'Zed*') { continue }
            if ([string]::IsNullOrWhiteSpace($entry.InstallLocation)) { continue }
            $roots.Add($entry.InstallLocation)
        }
    }

    foreach ($root in $roots) {
        $cli = Join-Path $root 'bin\Zed.exe'
        if (Test-Path -LiteralPath $cli -PathType Leaf) { $cli }
    }
}

function Resolve-ZedCliPath {
    [CmdletBinding()]
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
            throw "-ZedExe '$Explicit' does not exist"
        }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $found = Get-ZedCliCandidate | Select-Object -First 1
    if ($found) { return (Resolve-Path -LiteralPath $found).Path }

    $onPath = Get-Command -Name 'zed' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    throw 'could not locate the Zed CLI (looked in the usual install roots, the uninstall registry, and PATH); pass -ZedExe'
}
