function Get-ZapretService {
    $controller = Get-Service -Name zapret -ErrorAction SilentlyContinue
    if (-not $controller) { return }
    $config = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -ErrorAction SilentlyContinue
    $command = [string]$config.ImagePath
    $exe = $null
    if ($command -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
    elseif ($command -match '^\s*(.+?\.exe)(?=\s|$)') { $exe = $Matches[1] }
    $profile = [string]$config.ZozickProfile
    if (-not $profile -and $config.'zapret-discord-youtube' -eq 'general (ALT11)') { $profile = 'ALT11' }
    [pscustomobject]@{
        Status = [string]$controller.Status
        Command = $command
        Executable = [Environment]::ExpandEnvironmentVariables([string]$exe)
        Profile = $profile
        Managed = [string]$config.ZozickProfile -match '^[a-zA-Z][a-zA-Z0-9_-]{0,31}$'
        Start = $config.Start
    }
}

function Test-ZapretOwner($Service, [string]$Root) {
    if (-not $Service.Executable) { return $false }
    $expected = Join-Path $Root 'bin\winws.exe'
    return $Service.Executable -ieq $expected
}

function Test-ZapretManagedService($Service) {
    return $Service.Managed -and $Service.Executable -match '^[a-z]:[\\/].+[\\/]bin[\\/]winws\.exe$'
}

function Get-ZapretManualStartBlocker($Service) {
    if ($Service -and $Service.Status -eq 'Running') {
        return 'Zapret уже работает как служба.'
    }
    if ($Service -and $Service.Status -ne 'Stopped') {
        return 'Служба Zapret меняет состояние. Повтори через несколько секунд.'
    }
    if (Get-Process -Name winws -ErrorAction SilentlyContinue) {
        return 'Winws уже запущен. Закрой его окно перед ручным запуском.'
    }
}

function Wait-ZapretService([string]$Status) {
    (Get-Service -Name zapret).WaitForStatus($Status, [TimeSpan]::FromSeconds(15))
}

function Set-ZapretServiceConfig([string]$Command, [uint32]$Start) {
    if (-not ('ZapretServiceConfig' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class ZapretServiceConfig
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenSCManager(string machine, string database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenService(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ChangeServiceConfig(IntPtr service, uint type, uint start,
        uint errorControl, string path, string group, IntPtr tag, string dependencies,
        string account, string password, string displayName);
    [DllImport("advapi32.dll")]
    private static extern bool CloseServiceHandle(IntPtr handle);

    public static void Change(string path, uint start)
    {
        IntPtr manager = OpenSCManager(null, null, 1);
        if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            IntPtr service = OpenService(manager, "zapret", 2);
            if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                if (!ChangeServiceConfig(service, UInt32.MaxValue, start, UInt32.MaxValue,
                                         path, null, IntPtr.Zero, null, null, null, null))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { CloseServiceHandle(service); }
        }
        finally { CloseServiceHandle(manager); }
    }
}
'@
    }
    [ZapretServiceConfig]::Change($Command, $Start)
}
