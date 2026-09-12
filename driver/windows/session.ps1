# session.ps1 — turns the Windows side of the "second monitor" on and off without admin rights:
#   * attach / detach the virtual monitor to the desktop (ChangeDisplaySettingsEx; the driver stays installed,
#     but the phantom screen disappears from the desktop when the host stops)
#   * switch the default playback device to the virtual cable and back (IPolicyConfig; the previous device is
#     remembered in %LOCALAPPDATA%\ipad-display\prev-audio.json)
#
#   powershell -ExecutionPolicy Bypass -File session.ps1 -Action attach|detach|status|audio-cable|audio-restore
param(
  [Parameter(Mandatory = $true)][ValidateSet('attach', 'detach', 'status', 'paths', 'audio-cable', 'audio-restore', 'audio-hide', 'audio-show')][string]$Action,
  [int]$Width = 1024,
  [int]$Height = 768,
  [int]$Hz = 60,
  [string]$Match = 'Virtual Display|MttVDD|Idd',        # adapter name of the virtual display driver (GDI side)
  [string]$TargetMatch = 'MTT1337|VDD|Virtual Display|IddSample',  # monitor device path / friendly name (CCD side)
  [string]$CableMatch = 'CABLE Input|BlackHole|iPad Display'
)

$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $env:LOCALAPPDATA 'ipad-display'
$stateFile = Join-Path $stateDir 'prev-audio.json'
$posFile = Join-Path $stateDir 'display-pos.json'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
}

[StructLayout(LayoutKind.Sequential)] public struct POINTL { public int x, y; }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public uint dmFields;
    public POINTL dmPosition;
    public uint dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public ushort dmLogPixels;
    public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
}

public class Disp {
    const int ENUM_CURRENT_SETTINGS = -1;
    const uint DM_BITSPERPEL = 0x40000, DM_PELSWIDTH = 0x80000, DM_PELSHEIGHT = 0x100000, DM_DISPLAYFREQUENCY = 0x400000, DM_POSITION = 0x20;
    const uint CDS_UPDATEREGISTRY = 0x01, CDS_NORESET = 0x10000;
    const int ATTACHED = 0x1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint num, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);
    [DllImport("user32.dll")] static extern int ChangeDisplaySettingsEx(IntPtr dev, IntPtr dm, IntPtr hwnd, uint flags, IntPtr param);

    public class Info { public string Name, Adapter, Monitor; public bool Attached; public int X, Y, W, H; }

    public static List<Info> List() {
        var res = new List<Info>();
        for (uint i = 0; ; i++) {
            var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            var mon = new DISPLAY_DEVICE(); mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            EnumDisplayDevices(dd.DeviceName, 0, ref mon, 0);
            var dm = new DEVMODE(); dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            EnumDisplaySettings(dd.DeviceName, ENUM_CURRENT_SETTINGS, ref dm);
            res.Add(new Info { Name = dd.DeviceName, Adapter = dd.DeviceString, Monitor = mon.DeviceString,
                Attached = (dd.StateFlags & ATTACHED) != 0, X = dm.dmPosition.x, Y = dm.dmPosition.y, W = (int)dm.dmPelsWidth, H = (int)dm.dmPelsHeight });
        }
        return res;
    }

    static Info Find(string pattern) {
        var re = new System.Text.RegularExpressions.Regex(pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        foreach (var d in List()) if (re.IsMatch(d.Adapter ?? "") || re.IsMatch(d.Monitor ?? "")) return d;
        return null;
    }

    static int Apply() { return ChangeDisplaySettingsEx(IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }

    public static string Detach(string pattern) {
        var d = Find(pattern);
        if (d == null) return "not-found";
        if (!d.Attached) return "already-detached";
        // documented way to detach: an all-zero DEVMODE with only position/size fields set
        var dm = new DEVMODE(); dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        dm.dmDeviceName = d.Name;
        dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
        int r = ChangeDisplaySettingsEx(d.Name, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
        int a = Apply();
        return "detach " + d.Name + " r=" + r + " apply=" + a;
    }

    // px/py < int.MinValue+1 means "no saved position": put the screen to the right of everything else
    public static string Attach(string pattern, int w, int h, int hz, int px, int py) {
        var d = Find(pattern);
        if (d == null) return "not-found";
        // already fine? (same size, and same position when one was asked for)
        if (d.Attached && d.W == w && d.H == h && (px == int.MinValue || (d.X == px && d.Y == py))) return "already-attached";
        int x = px, y = py;
        if (px == int.MinValue) {
            int right = 0;
            foreach (var o in List()) if (o.Attached && o.Name != d.Name && o.X + o.W > right) right = o.X + o.W;
            x = right; y = 0;
        }
        // keep the mode the driver is already in and flag only what actually changes: this IddCx driver
        // rejects a DEVMODE that re-states colour depth / refresh rate (DISP_CHANGE_BADMODE).
        var dm = new DEVMODE(); dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(d.Name, ENUM_CURRENT_SETTINGS, ref dm);
        uint fields = DM_POSITION;
        if (dm.dmPelsWidth != (uint)w || dm.dmPelsHeight != (uint)h) {
            dm.dmPelsWidth = (uint)w; dm.dmPelsHeight = (uint)h;
            fields |= DM_PELSWIDTH | DM_PELSHEIGHT;
            if (dm.dmBitsPerPel == 0) { dm.dmBitsPerPel = 32; fields |= DM_BITSPERPEL; }
            if (dm.dmDisplayFrequency == 0) { dm.dmDisplayFrequency = (uint)hz; fields |= DM_DISPLAYFREQUENCY; }
        }
        dm.dmPosition.x = x; dm.dmPosition.y = y;
        dm.dmFields = fields;
        int r = ChangeDisplaySettingsEx(d.Name, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
        int a = Apply();
        return "attach " + d.Name + " at " + x + "," + y + " " + w + "x" + h + " r=" + r + " apply=" + a;
    }

    public static Info Current(string pattern) { return Find(pattern); }
}

// The IddCx virtual display driver refuses the legacy ChangeDisplaySettingsEx detach, so use the CCD API
// (QueryDisplayConfig / SetDisplayConfig) — the same one the Windows display settings page uses. The monitor
// is identified by its device path, which contains the driver's hardware id and survives reboots.
[StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
[StructLayout(LayoutKind.Sequential)] public struct DC_RATIONAL { public uint Num, Den; }
[StructLayout(LayoutKind.Sequential)] public struct DC_SOURCE_INFO { public LUID adapterId; public uint id, modeInfoIdx, statusFlags; }
[StructLayout(LayoutKind.Sequential)] public struct DC_TARGET_INFO {
    public LUID adapterId; public uint id, modeInfoIdx, outputTechnology, rotation, scaling;
    public DC_RATIONAL refreshRate; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags;
}
[StructLayout(LayoutKind.Sequential)] public struct DC_PATH_INFO { public DC_SOURCE_INFO sourceInfo; public DC_TARGET_INFO targetInfo; public uint flags; }
[StructLayout(LayoutKind.Sequential)] public struct DC_MODE_INFO { public uint infoType, id; public LUID adapterId; public ulong a, b, c, d, e, f; }
[StructLayout(LayoutKind.Sequential)] public struct DC_HEADER { public uint type, size; public LUID adapterId; public uint id; }
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct DC_TARGET_NAME {
    public DC_HEADER header; public uint flags, outputTechnology; public ushort edidVendor, edidProduct; public uint connectorInstance;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string friendlyName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string devicePath;
}

public class Ccd {
    const uint QDC_ALL_PATHS = 1, QDC_ONLY_ACTIVE_PATHS = 2;
    const uint SDC_APPLY = 0x80, SDC_USE_SUPPLIED = 0x20, SDC_ALLOW_CHANGES = 0x400, SDC_SAVE_TO_DATABASE = 0x200, SDC_TOPOLOGY_EXTEND = 0x4;
    const uint PATH_ACTIVE = 1, MODE_INVALID = 0xffffffff;

    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint nPath, out uint nMode);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint nPath, [Out] DC_PATH_INFO[] paths, ref uint nMode, [Out] DC_MODE_INFO[] modes, IntPtr topologyId);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint nPath, DC_PATH_INFO[] paths, uint nMode, DC_MODE_INFO[] modes, uint flags);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref DC_TARGET_NAME info);

    static string TargetPath(LUID adapter, uint id) {
        var n = new DC_TARGET_NAME();
        n.header.type = 2; // DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
        n.header.size = (uint)Marshal.SizeOf(typeof(DC_TARGET_NAME));
        n.header.adapterId = adapter; n.header.id = id;
        if (DisplayConfigGetDeviceInfo(ref n) != 0) return "";
        return (n.devicePath ?? "") + " | " + (n.friendlyName ?? "");
    }

    public static string Paths() {
        uint nPath, nMode;
        if (GetDisplayConfigBufferSizes(QDC_ALL_PATHS, out nPath, out nMode) != 0) return "query-sizes-failed";
        var paths = new DC_PATH_INFO[nPath]; var modes = new DC_MODE_INFO[nMode];
        int hr = QueryDisplayConfig(QDC_ALL_PATHS, ref nPath, paths, ref nMode, modes, IntPtr.Zero);
        var sb = new StringBuilder("query hr=" + hr + " paths=" + nPath + "\n");
        for (uint i = 0; i < nPath; i++)
            sb.AppendLine("  path " + i + " active=" + ((paths[i].flags & PATH_ACTIVE) != 0) + " srcId=" + paths[i].sourceInfo.id +
                " tgtId=" + paths[i].targetInfo.id + " avail=" + paths[i].targetInfo.targetAvailable + " => " + TargetPath(paths[i].targetInfo.adapterId, paths[i].targetInfo.id));
        return sb.ToString();
    }

    // Move the display by editing its source mode (the legacy ChangeDisplaySettingsEx path is rejected by
    // this driver). In DISPLAYCONFIG_MODE_INFO the source mode union starts at offset 16:
    //   width (16), height (20), pixelFormat (24), position.x (28), position.y (32)
    // which is fields a (16-23), b (24-31), c (32-39) of DC_MODE_INFO.
    public static string Move(string pattern, int x, int y) {
        uint nPath, nMode;
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out nPath, out nMode) != 0) return "move: query-sizes-failed";
        var paths = new DC_PATH_INFO[nPath]; var modes = new DC_MODE_INFO[nMode];
        if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref nPath, paths, ref nMode, modes, IntPtr.Zero) != 0) return "move: query-failed";
        var re = new System.Text.RegularExpressions.Regex(pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        for (uint i = 0; i < nPath; i++) {
            if (!re.IsMatch(TargetPath(paths[i].targetInfo.adapterId, paths[i].targetInfo.id))) continue;
            uint idx = paths[i].sourceInfo.modeInfoIdx;
            if (idx >= nMode) return "move: no-source-mode";
            int curX = (int)(uint)(modes[idx].b >> 32), curY = (int)(uint)(modes[idx].c & 0xffffffffUL);
            if (curX == x && curY == y) return "move: already-there";
            modes[idx].b = (modes[idx].b & 0xffffffffUL) | ((ulong)(uint)x << 32);
            modes[idx].c = (modes[idx].c & ~0xffffffffUL) | (uint)y;
            int r = SetDisplayConfig(nPath, paths, nMode, modes, SDC_APPLY | SDC_USE_SUPPLIED | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
            return "move " + curX + "," + curY + " -> " + x + "," + y + " r=" + r;
        }
        return "move: not-found";
    }

    public static string Set(string pattern, bool active) {
        uint nPath, nMode;
        if (GetDisplayConfigBufferSizes(QDC_ALL_PATHS, out nPath, out nMode) != 0) return "query-sizes-failed";
        var paths = new DC_PATH_INFO[nPath]; var modes = new DC_MODE_INFO[nMode];
        if (QueryDisplayConfig(QDC_ALL_PATHS, ref nPath, paths, ref nMode, modes, IntPtr.Zero) != 0) return "query-failed";
        var re = new System.Text.RegularExpressions.Regex(pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        int hits = 0;
        for (uint i = 0; i < nPath; i++) {
            bool isActive = (paths[i].flags & PATH_ACTIVE) != 0;
            if (isActive == active) continue;                       // already in the wanted state
            if (!re.IsMatch(TargetPath(paths[i].targetInfo.adapterId, paths[i].targetInfo.id))) continue;
            if (active) paths[i].flags |= PATH_ACTIVE; else paths[i].flags &= ~PATH_ACTIVE;
            paths[i].sourceInfo.modeInfoIdx = MODE_INVALID;         // let Windows pick the mode
            paths[i].targetInfo.modeInfoIdx = MODE_INVALID;
            hits++;
        }
        if (hits == 0) return active ? "already-attached" : "already-detached";
        int r = SetDisplayConfig(nPath, paths, nMode, modes, SDC_APPLY | SDC_USE_SUPPLIED | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
        if (r != 0 && active) r = SetDisplayConfig(0, null, 0, null, SDC_APPLY | SDC_TOPOLOGY_EXTEND); // fallback: extend everything
        return (active ? "attach" : "detach") + " paths=" + hits + " r=" + r;
    }
}

// Default playback device: the documented API is read-only, IPolicyConfig is what the Sound control panel uses.
[Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPolicyConfig {
    int GetMixFormat(); int GetDeviceFormat(); int ResetDeviceFormat(); int SetDeviceFormat();
    int GetProcessingPeriod(); int SetProcessingPeriod(); int GetShareMode(); int SetShareMode();
    int GetPropertyValue(); int SetPropertyValue();
    int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
    int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, int visible);
}
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] public class CPolicyConfigClient { }

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int flow, int state, out IMMDeviceCollection col);
    int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
}
[Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceCollection { int GetCount(out uint n); int Item(uint i, out IMMDevice d); }
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice { int Activate(); int OpenPropertyStore(int stgm, out IPropertyStore s); int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id); }
[StructLayout(LayoutKind.Sequential)] public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
[StructLayout(LayoutKind.Explicit)] public struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore { int GetCount(out uint c); int GetAt(uint i, out PROPERTYKEY k); int GetValue(ref PROPERTYKEY k, out PROPVARIANT v); int SetValue(); int Commit(); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class MMDeviceEnumeratorClass { }

public class Aud {
    static readonly PROPERTYKEY NameKey = new PROPERTYKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
    public class Dev { public string Id, Name; }

    static string NameOf(IMMDevice d) {
        IPropertyStore s; if (d.OpenPropertyStore(0, out s) != 0) return "?";
        var k = NameKey; PROPVARIANT v;
        if (s.GetValue(ref k, out v) != 0 || v.vt != 31) return "?";
        return Marshal.PtrToStringUni(v.p);
    }

    // state mask: 1 = ACTIVE, 2 = DISABLED, 4 = NOTPRESENT, 8 = UNPLUGGED
    public static List<Dev> All(int flow, int stateMask) {
        var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorClass();
        IMMDeviceCollection col; e.EnumAudioEndpoints(flow, stateMask, out col);
        uint n; col.GetCount(out n);
        var res = new List<Dev>();
        for (uint i = 0; i < n; i++) { IMMDevice d; col.Item(i, out d); string id; d.GetId(out id); res.Add(new Dev { Id = id, Name = NameOf(d) }); }
        return res;
    }

    // "Disable"/"Enable" in the Sound control panel: the endpoint disappears from (comes back to) the list.
    public static string SetVisible(string id, bool visible) {
        var pc = (IPolicyConfig)new CPolicyConfigClient();
        return "hr=" + pc.SetEndpointVisibility(id, visible ? 1 : 0);
    }

    public static List<Dev> Outputs() {
        var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorClass();
        IMMDeviceCollection col; e.EnumAudioEndpoints(0 /*eRender*/, 1 /*ACTIVE*/, out col);
        uint n; col.GetCount(out n);
        var res = new List<Dev>();
        for (uint i = 0; i < n; i++) { IMMDevice d; col.Item(i, out d); string id; d.GetId(out id); res.Add(new Dev { Id = id, Name = NameOf(d) }); }
        return res;
    }

    public static Dev DefaultOutput() {
        var e = (IMMDeviceEnumerator)new MMDeviceEnumeratorClass();
        IMMDevice d;
        if (e.GetDefaultAudioEndpoint(0, 1 /*eMultimedia*/, out d) != 0 || d == null) return null;
        string id; d.GetId(out id);
        return new Dev { Id = id, Name = NameOf(d) };
    }

    public static string SetDefault(string id) {
        var pc = (IPolicyConfig)new CPolicyConfigClient();
        int a = pc.SetDefaultEndpoint(id, 0 /*eConsole*/);
        int b = pc.SetDefaultEndpoint(id, 1 /*eMultimedia*/);
        int c = pc.SetDefaultEndpoint(id, 2 /*eCommunications*/);
        return "hr=" + a + "/" + b + "/" + c;
    }
}
'@

function Get-Cable {
  $devs = [Aud]::Outputs()
  $c = $devs | Where-Object { $_.Name -match $CableMatch } | Select-Object -First 1
  return $c
}

switch ($Action) {
  'status' {
    [Disp]::List() | ForEach-Object { "{0} attached={1} {2}x{3} @{4},{5} '{6}' / '{7}'" -f $_.Name, $_.Attached, $_.W, $_.H, $_.X, $_.Y, $_.Adapter, $_.Monitor }
    $d = [Aud]::DefaultOutput(); "default-output: " + $(if ($d) { $d.Name } else { '?' })
    $c = Get-Cable; "cable: " + $(if ($c) { $c.Name } else { 'не найден' })
  }
  'paths'  { [Ccd]::Paths() }
  'attach' {
    $px = [int]::MinValue; $py = 0
    if (Test-Path $posFile) {
      try { $s = Get-Content $posFile -Raw | ConvertFrom-Json; if ($null -ne $s.x) { $px = [int]$s.x; $py = [int]$s.y }
            if ($s.w -gt 0) { $Width = [int]$s.w; $Height = [int]$s.h } } catch { }
    }
    $r = [Ccd]::Set($TargetMatch, $true)
    if ($r -notmatch 'already') { Start-Sleep -Milliseconds 700 }   # let the desktop settle
    $r2 = if ($px -ne [int]::MinValue) { [Ccd]::Move($TargetMatch, $px, $py) } else { 'move: no-saved-position' }
    if ($r2 -match 'r=[^0]') { $r2 += '; legacy ' + [Disp]::Attach($Match, $Width, $Height, $Hz, $px, $py) }
    "$r; $r2"
  }
  'detach' {
    $cur = [Disp]::Current($Match)
    if ($cur -and $cur.Attached -and $cur.W -gt 0) {
      New-Item -ItemType Directory -Force $stateDir | Out-Null
      @{ x = $cur.X; y = $cur.Y; w = $cur.W; h = $cur.H } | ConvertTo-Json | Set-Content $posFile -Encoding UTF8
    }
    [Ccd]::Set($TargetMatch, $false)
  }
  'audio-cable' {
    $c = Get-Cable
    if (-not $c) { "cable-not-found"; break }
    $cur = [Aud]::DefaultOutput()
    if ($cur -and $cur.Id -ne $c.Id) {
      New-Item -ItemType Directory -Force $stateDir | Out-Null
      @{ id = $cur.Id; name = $cur.Name } | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
    }
    if ($cur -and $cur.Id -eq $c.Id) { "already-cable"; break }
    # Windows re-evaluates the default device shortly after an endpoint is (re-)enabled and can put it back,
    # so set it, verify, and try again a couple of times.
    $msg = ''
    for ($i = 1; $i -le 3; $i++) {
      $msg = [Aud]::SetDefault($c.Id)
      Start-Sleep -Milliseconds 700
      $now = [Aud]::DefaultOutput()
      if ($now -and $now.Id -eq $c.Id) { "to-cable '" + $c.Name + "' " + $msg + " (attempt $i)"; break }
      if ($i -eq 3) { "to-cable-failed '" + $c.Name + "' " + $msg + " now='" + $(if ($now) { $now.Name } else { '?' }) + "'" }
    }
  }
  'audio-hide' {
    # the cable should not sit in the list of outputs while the host is not running
    $out = @()
    foreach ($flow in 0, 1) {
      foreach ($d in [Aud]::All($flow, 1)) {
        if ($d.Name -notmatch $CableMatch -and $d.Name -notmatch 'CABLE') { continue }
        $out += ("hide '" + $d.Name + "' " + [Aud]::SetVisible($d.Id, $false))
      }
    }
    if ($out.Count) { $out } else { "nothing-to-hide" }
  }
  'audio-show' {
    $out = @()
    foreach ($flow in 0, 1) {
      foreach ($d in [Aud]::All($flow, 2)) {   # currently disabled
        if ($d.Name -notmatch $CableMatch -and $d.Name -notmatch 'CABLE') { continue }
        $out += ("show '" + $d.Name + "' " + [Aud]::SetVisible($d.Id, $true))
      }
    }
    if ($out.Count) { $out } else { "nothing-to-show" }
  }
  'audio-restore' {
    if (-not (Test-Path $stateFile)) { "no-saved-device"; break }
    $prev = Get-Content $stateFile -Raw | ConvertFrom-Json
    $cur = [Aud]::DefaultOutput()
    if ($cur -and $cur.Name -notmatch $CableMatch) { "not-on-cable"; break }  # the user switched it themselves
    $still = [Aud]::Outputs() | Where-Object { $_.Id -eq $prev.id } | Select-Object -First 1
    if (-not $still) { "saved-device-gone"; break }
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    "restored '" + $prev.name + "' " + [Aud]::SetDefault($prev.id)
  }
}
