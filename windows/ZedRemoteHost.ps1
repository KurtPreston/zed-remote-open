<#
    The dev box's ssh alias, dot-sourced by install-zed-listener.ps1 and
    check-zed-remote-open.ps1.

    There is no default: the alias is specific to each workstation. The installer
    saves the one it was given beside the installed scripts, so a re-install and
    the doctor can reuse it without -RemoteHost.
#>

function Get-RemoteHostFile {
    param([Parameter(Mandatory)][string]$InstallDir)
    Join-Path $InstallDir 'remote-host.txt'
}

function Resolve-RemoteHost {
    param([string]$Explicit, [Parameter(Mandatory)][string]$InstallDir)

    if ($Explicit) { return $Explicit }

    # Fall back to the alias the last install saved.
    $file = Get-RemoteHostFile -InstallDir $InstallDir
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $saved = (Get-Content -LiteralPath $file -TotalCount 1 -ErrorAction SilentlyContinue)
        if ($saved -and $saved.Trim()) { return $saved.Trim() }
    }

    throw 'remote host unknown; pass -RemoteHost <alias>, the ssh_connections host Zed uses for the dev box'
}

function Save-RemoteHost {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$InstallDir)
    Set-Content -LiteralPath (Get-RemoteHostFile -InstallDir $InstallDir) -Value $RemoteHost -Encoding ASCII
}
