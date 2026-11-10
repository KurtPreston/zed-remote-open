<#
    The dev box's ssh alias, dot-sourced by install-zed-listener.ps1 and
    check-zed-remote-open.ps1.

    There is no default: the alias is specific to each workstation. The installer
    saves the one it was given as REMOTE_HOST in a .env file beside the installed
    scripts, so a re-install and the doctor can reuse it without -RemoteHost.
#>

$RemoteHostKey = 'REMOTE_HOST'

function Get-EnvFile {
    param([Parameter(Mandatory)][string]$InstallDir)
    Join-Path $InstallDir '.env'
}

function Resolve-RemoteHost {
    param([string]$Explicit, [Parameter(Mandatory)][string]$InstallDir)

    if ($Explicit) { return $Explicit }

    # Fall back to the alias the last install saved; the last assignment wins.
    $file = Get-EnvFile -InstallDir $InstallDir
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $line = @(Get-Content -LiteralPath $file | Where-Object { $_ -match "^\s*$RemoteHostKey=" }) |
            Select-Object -Last 1
        if ($line) {
            $saved = ($line -replace "^\s*$RemoteHostKey=", '').Trim().Trim('"', "'")
            if ($saved) { return $saved }
        }
    }

    throw 'remote host unknown; pass -RemoteHost <alias>, the ssh_connections host Zed uses for the dev box'
}

function Save-RemoteHost {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$InstallDir)

    # Replace REMOTE_HOST and keep any other keys in the file.
    $file = Get-EnvFile -InstallDir $InstallDir
    $others = @()
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $others = @(Get-Content -LiteralPath $file | Where-Object { $_ -notmatch "^\s*$RemoteHostKey=" })
    }
    Set-Content -LiteralPath $file -Value ($others + "$RemoteHostKey=$RemoteHost") -Encoding ASCII
}
