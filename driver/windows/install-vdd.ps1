# Installs the Virtual Display Driver (IddCx, VirtualDrivers/Virtual-Display-Driver) and creates
# one root-enumerated Root\MttVDD device. Run elevated. Settings live in C:\VirtualDisplayDriver.
$ErrorActionPreference = 'Stop'
$src = "C:\Users\kurma\vdd\VirtualDisplayDriver"
$cfgDir = "C:\VirtualDisplayDriver"
New-Item -ItemType Directory -Force $cfgDir | Out-Null
Copy-Item "$src\vdd_settings.xml" "$cfgDir\vdd_settings.xml" -Force
Write-Host "settings -> $cfgDir\vdd_settings.xml"

Write-Host "pnputil /add-driver"
& pnputil.exe /add-driver "$src\MttVDD.inf" /install | Out-String | Write-Host

$existing = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'ROOT\DISPLAY\*' -and $_.FriendlyName -match 'Virtual Display|MttVDD' }
if ($existing) { Write-Host "device already exists: $($existing.InstanceId)"; exit 0 }

Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class Dev {
  [StructLayout(LayoutKind.Sequential)] public struct DEVINFO_DATA { public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid g, IntPtr h);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid g, string desc, IntPtr h, uint flags, ref DEVINFO_DATA d);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref DEVINFO_DATA d, uint prop, byte[] buf, uint size);
  [DllImport("setupapi.dll", SetLastError=true)] public static extern bool SetupDiCallClassInstaller(uint f, IntPtr set, ref DEVINFO_DATA d);
  [DllImport("setupapi.dll", SetLastError=true)] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
  [DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr h, string hwid, string inf, uint flags, out bool reboot);
  public static string Create(string hwid, string inf, string cls) {
    Guid g = new Guid(cls);
    IntPtr set = SetupDiCreateDeviceInfoList(ref g, IntPtr.Zero);
    if (set == (IntPtr)(-1)) return "CreateDeviceInfoList failed " + Marshal.GetLastWin32Error();
    DEVINFO_DATA d = new DEVINFO_DATA(); d.cbSize = (uint)Marshal.SizeOf(typeof(DEVINFO_DATA));
    if (!SetupDiCreateDeviceInfo(set, "Display", ref g, "Virtual Display Driver", IntPtr.Zero, 1 /*DICD_GENERATE_ID*/, ref d)) return "CreateDeviceInfo failed " + Marshal.GetLastWin32Error();
    byte[] id = Encoding.Unicode.GetBytes(hwid + "\0\0");
    if (!SetupDiSetDeviceRegistryProperty(set, ref d, 1 /*SPDRP_HARDWAREID*/, id, (uint)id.Length)) return "SetHardwareId failed " + Marshal.GetLastWin32Error();
    if (!SetupDiCallClassInstaller(0x19 /*DIF_REGISTERDEVICE*/, set, ref d)) return "RegisterDevice failed " + Marshal.GetLastWin32Error();
    SetupDiDestroyDeviceInfoList(set);
    bool reboot;
    if (!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hwid, inf, 1 /*INSTALLFLAG_FORCE*/, out reboot)) return "UpdateDriver failed " + Marshal.GetLastWin32Error();
    return "OK reboot=" + reboot;
  }
}
"@
$r = [Dev]::Create("Root\MttVDD", "$src\MttVDD.inf", "{4D36E968-E325-11CE-BFC1-08002BE10318}")
Write-Host "create device: $r"
Start-Sleep 3
Get-PnpDevice | Where-Object { $_.InstanceId -like 'ROOT\DISPLAY\*' } | Select-Object Status,FriendlyName,InstanceId | Format-Table -AutoSize | Out-String | Write-Host
