# Escucha de atajos globales (proceso oculto, uno solo por usuario). Usa RegisterHotKey de
# Windows, mas fiable que la tecla rapida de un acceso directo del menu Inicio.
#   Ctrl+Alt+Shift+O  repetir el ultimo audio      Ctrl+Alt+Shift+P  parar el audio
#   (configurables en config.json: hotkeys.repeat / hotkeys.stop)
# Lo arranca 'ctl.ps1 hotkeys on' y, al iniciar sesion, el acceso directo de la carpeta Inicio.
. "$PSScriptRoot\common.ps1"

$single = New-Object System.Threading.Mutex($false, 'Local\ClaudeVoiceHotkeys')
$mine = $false
try { $mine = $single.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $mine = $true }
if (-not $mine) { exit 0 }  # ya hay uno escuchando

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ClaudeVoice {
    public static class HotkeyLoop {
        [StructLayout(LayoutKind.Sequential)]
        private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }
        [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] private static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
        [DllImport("user32.dll")] private static extern UIntPtr SetTimer(IntPtr hWnd, UIntPtr id, uint ms, IntPtr proc);
        // mods: 1 Alt, 2 Ctrl, 4 Shift; 0x4000 = no repetir al mantener pulsado
        public static bool Register(int id, uint mods, uint vk) { return RegisterHotKey(IntPtr.Zero, id, mods | 0x4000, vk); }
        public static int LastError() { return Marshal.GetLastWin32Error(); }
        public static void StartTimer(uint ms) { SetTimer(IntPtr.Zero, UIntPtr.Zero, ms, IntPtr.Zero); }
        // Bloquea hasta el siguiente atajo (devuelve su id) o tick del temporizador (-2).
        public static int Next() {
            MSG m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) {
                if (m.message == 0x0312) return m.wParam.ToInt32();
                if (m.message == 0x0113) return -2;
            }
            return -1;
        }
    }
}
'@

$ctl = Join-Path $Root 'ctl.ps1'
$cfg = Get-VoiceConfig
# Teclas (una letra o F1..F12) que se combinan con Ctrl+Alt+Shift. En este equipo algo intercepta
# Ctrl+Alt+R a bajo nivel, por eso repetir va en la O ("oir otra vez").
function ConvertTo-Vk([string]$Key) {
    $Key = $Key.Trim().ToUpper()
    if ($Key -match '^[A-Z0-9]$') { return [uint32][char]$Key }
    if ($Key -match '^F([1-9]|1[0-2])$') { return [uint32](0x6F + [int]$Matches[1]) }
    return 0
}
$keys = @(
    @{ id = 1; key = (Get-Opt $cfg 'hotkeys.repeat' 'O'); action = 'repeat' },
    @{ id = 2; key = (Get-Opt $cfg 'hotkeys.stop' 'P');   action = 'stop' }
) | ForEach-Object { $_.vk = ConvertTo-Vk $_.key; $_.label = "Ctrl+Alt+Shift+$($_.key)"; $_ } | Where-Object { $_.vk }
# Registra los atajos que falten. Si otra app (o el Explorador, que tarda en soltar las teclas
# rapidas de accesos directos borrados) tiene la combinacion, se reintenta cada 15 s.
$pending = @{}
foreach ($k in $keys) { $pending[$k.id] = $k }
$warned = @{}
function Register-Pending {
    foreach ($id in @($pending.Keys)) {
        $k = $pending[$id]
        if ([ClaudeVoice.HotkeyLoop]::Register($k.id, 7, $k.vk)) {
            Write-Log "hotkeys: $($k.label) -> $($k.action)"
            $pending.Remove($id)
        } elseif (-not $warned[$id]) {
            Write-Log ("hotkeys: {0} ocupado (error {1}); reintento cada 15 s" -f $k.label, [ClaudeVoice.HotkeyLoop]::LastError())
            $warned[$id] = $true
        }
    }
}
Register-Pending
[ClaudeVoice.HotkeyLoop]::StartTimer(15000)
[IO.File]::WriteAllText((Join-Path $StateDir 'hotkeys.pid'), "$PID", $Utf8)

while ($true) {
    $id = [ClaudeVoice.HotkeyLoop]::Next()
    if ($id -eq -2) { if ($pending.Count) { Register-Pending }; continue }
    if ($id -lt 0) { break }
    $k = $keys | Where-Object { $_.id -eq $id }
    if ($k) {
        Write-Log "hotkeys: $($k.label)"
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ctl`"", $k.action)
    }
}
