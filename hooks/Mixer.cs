// Control del volumen por aplicacion (Core Audio de Windows) para bajar la musica mientras
// habla Claude y restaurarla despues. Se compila una vez a una DLL desde common.ps1.
// El estado guardado ("id<TAB>volumen" por linea) permite restaurar desde otro proceso,
// por ejemplo si el reproductor se mato a mitad de frase.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ClaudeVoice
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        int NotUsed_EnumAudioEndpoints();
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionManager2
    {
        int NotUsed_GetAudioSessionControl();
        int NotUsed_GetSimpleAudioVolume();
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int state);
        int NotUsed_GetDisplayName();
        int NotUsed_SetDisplayName();
        int NotUsed_GetIconPath();
        int NotUsed_SetIconPath();
        int NotUsed_GetGroupingParam();
        int NotUsed_SetGroupingParam();
        int NotUsed_RegisterAudioSessionNotification();
        int NotUsed_UnregisterAudioSessionNotification();
        int NotUsed_GetSessionIdentifier();
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out int pid);
        [PreserveSig] int IsSystemSoundsSession();
    }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ISimpleAudioVolume
    {
        [PreserveSig] int SetMasterVolume(float level, ref Guid eventContext);
        [PreserveSig] int GetMasterVolume(out float level);
    }

    public static class Mixer
    {
        private const int AudioSessionStateActive = 1;

        private static List<IAudioSessionControl2> Sessions()
        {
            var result = new List<IAudioSessionControl2>();
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            IMMDevice device;
            if (enumerator.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out device) != 0) return result;
            Guid iid = typeof(IAudioSessionManager2).GUID;
            object manager;
            if (device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out manager) != 0) return result;
            IAudioSessionEnumerator sessions;
            if (((IAudioSessionManager2)manager).GetSessionEnumerator(out sessions) != 0) return result;
            int count;
            sessions.GetCount(out count);
            for (int i = 0; i < count; i++)
            {
                IAudioSessionControl2 session;
                if (sessions.GetSession(i, out session) == 0 && session != null) result.Add(session);
            }
            return result;
        }

        // Sesiones que estan sonando ahora (sin sonidos del sistema ni los PID excluidos).
        public static string Snapshot(int[] excludePids)
        {
            var saved = new StringBuilder();
            foreach (var session in Sessions())
            {
                int state, pid;
                string id;
                if (session.GetState(out state) != 0 || state != AudioSessionStateActive) continue;
                if (session.IsSystemSoundsSession() == 0) continue;  // S_OK = sonidos del sistema
                if (session.GetProcessId(out pid) != 0 || Array.IndexOf(excludePids, pid) >= 0) continue;
                if (session.GetSessionInstanceIdentifier(out id) != 0 || string.IsNullOrEmpty(id)) continue;
                float volume;
                if (((ISimpleAudioVolume)session).GetMasterVolume(out volume) != 0) continue;
                saved.Append(id).Append('\t').Append(volume.ToString(CultureInfo.InvariantCulture)).Append('\n');
            }
            return saved.ToString();
        }

        // Lleva cada sesion guardada a (volumen guardado * factor) con un fundido.
        // factor < 1 baja la musica; factor = 1 la restaura. Devuelve cuantas sesiones toco.
        public static int Apply(string saved, float factor, int fadeMs)
        {
            var original = new Dictionary<string, float>();
            foreach (var line in (saved ?? "").Split('\n'))
            {
                var parts = line.Split('\t');
                float v;
                if (parts.Length == 2 && float.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out v))
                    original[parts[0]] = v;
            }
            if (original.Count == 0) return 0;

            var volumes = new List<ISimpleAudioVolume>();
            var from = new List<float>();
            var to = new List<float>();
            foreach (var session in Sessions())
            {
                string id;
                float target, current;
                if (session.GetSessionInstanceIdentifier(out id) != 0 || id == null || !original.TryGetValue(id, out target)) continue;
                var volume = (ISimpleAudioVolume)session;
                if (volume.GetMasterVolume(out current) != 0) continue;
                volumes.Add(volume);
                from.Add(current);
                to.Add(Math.Max(0f, Math.Min(1f, target * factor)));
            }

            int steps = Math.Max(1, fadeMs / 25);
            Guid context = Guid.Empty;
            for (int step = 1; step <= steps; step++)
            {
                for (int i = 0; i < volumes.Count; i++)
                    volumes[i].SetMasterVolume(from[i] + (to[i] - from[i]) * step / steps, ref context);
                if (step < steps) Thread.Sleep(fadeMs / steps);
            }
            return volumes.Count;
        }
    }
}
