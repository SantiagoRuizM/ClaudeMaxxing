// Sintetizador de la firma musical de cada sesion: un acorde corto (arpegiado o no) con un
// timbre por tipo de trabajo. Escribe un WAV mono de 16 bits. Sintesis aditiva: cada nota es
// una suma de parciales con ataque corto y caida exponencial (los agudos caen antes).
using System;
using System.IO;

namespace ClaudeVoice
{
    public static class Chime
    {
        private const int Rate = 44100;

        private class Timbre
        {
            public double[] Ratios;   // parciales relativos a la fundamental
            public double[] Amps;
            public double Decay;      // segundos (constante de tiempo de la fundamental)
            public double Damp;       // cuanto mas rapido caen los parciales altos
            public double Attack;     // segundos
            public double Vibrato;    // profundidad relativa
        }

        private static Timbre GetTimbre(string name)
        {
            switch ((name ?? "").ToLowerInvariant())
            {
                case "marimba":
                    return new Timbre { Ratios = new[] { 1, 3.93, 9.2 }, Amps = new[] { 1, 0.3, 0.06 }, Decay = 0.45, Damp = 2.5, Attack = 0.003 };
                case "piano":
                    return new Timbre { Ratios = new[] { 1.0, 2, 3, 4, 5, 6 }, Amps = new[] { 1, 0.5, 0.28, 0.16, 0.09, 0.05 }, Decay = 0.9, Damp = 0.6, Attack = 0.004 };
                case "cristal":
                    return new Timbre { Ratios = new[] { 1.0, 2 }, Amps = new[] { 1, 0.22 }, Decay = 1.1, Damp = 0.3, Attack = 0.05, Vibrato = 0.003 };
                case "kalimba":
                    return new Timbre { Ratios = new[] { 1, 5.95, 2.0 }, Amps = new[] { 1, 0.28, 0.1 }, Decay = 0.7, Damp = 4, Attack = 0.002 };
                case "pluck":
                    return new Timbre { Ratios = new[] { 1.0, 2, 3, 4 }, Amps = new[] { 1, 0.6, 0.3, 0.15 }, Decay = 0.35, Damp = 1.2, Attack = 0.002 };
                default: // campana
                    return new Timbre { Ratios = new[] { 1, 2.0, 3.01, 4.17, 5.43 }, Amps = new[] { 1, 0.45, 0.25, 0.14, 0.07 }, Decay = 1.3, Damp = 0.8, Attack = 0.003 };
            }
        }

        // Momento (s) en que empieza cada nota segun el dibujo.
        private static double[] Onsets(int count, string pattern)
        {
            var t = new double[count];
            for (int i = 0; i < count; i++)
            {
                switch ((pattern ?? "").ToLowerInvariant())
                {
                    case "sube":    t[i] = i * 0.11; break;
                    case "baja":    t[i] = (count - 1 - i) * 0.11; break;
                    case "salto":   t[i] = (i % 2 == 0) ? 0 : 0.17; break;          // 1+3 y luego 2+4
                    case "eco":     t[i] = i == 0 ? 0 : 0.2 + (i - 1) * 0.05; break; // nota sola y luego el resto
                    default:        t[i] = i * 0.018; break;                          // bloque (rasgueo minimo)
                }
            }
            return t;
        }

        // Escribe el WAV y devuelve cuantos ms esperar antes de empezar a hablar
        // (la voz entra mientras se apaga la cola del acorde).
        public static int Write(string path, int[] midiNotes, string pattern, string timbre, double volume)
        {
            var tb = GetTimbre(timbre);
            var onsets = Onsets(midiNotes.Length, pattern);
            double last = 0;
            foreach (var o in onsets) last = Math.Max(last, o);
            double total = last + Math.Min(1.6, tb.Decay * 3.2) + 0.05;
            var buf = new double[(int)(total * Rate)];

            for (int n = 0; n < midiNotes.Length; n++)
            {
                double f0 = 440.0 * Math.Pow(2, (midiNotes[n] - 69) / 12.0);
                int start = (int)(onsets[n] * Rate);
                double noteGain = 1.0 / Math.Sqrt(midiNotes.Length) * (n == 0 ? 1.0 : 0.85);
                for (int k = 0; k < tb.Ratios.Length; k++)
                {
                    double f = f0 * tb.Ratios[k];
                    if (f > Rate / 2.2) continue;
                    double decay = tb.Decay / (1 + tb.Damp * k);
                    double phase = 0;
                    for (int i = start; i < buf.Length; i++)
                    {
                        double t = (i - start) / (double)Rate;
                        double env = (t < tb.Attack ? t / tb.Attack : 1.0) * Math.Exp(-t / decay);
                        if (env < 1e-4 && t > tb.Attack) break;
                        double fm = tb.Vibrato > 0 ? f * (1 + tb.Vibrato * Math.Sin(2 * Math.PI * 5.5 * t)) : f;
                        phase += 2 * Math.PI * fm / Rate;
                        buf[i] += noteGain * tb.Amps[k] * env * Math.Sin(phase);
                    }
                }
            }

            double peak = 1e-9;
            foreach (var s in buf) peak = Math.Max(peak, Math.Abs(s));
            double gain = Math.Max(0.05, Math.Min(0.9, volume)) / peak;
            int fade = (int)(0.04 * Rate);

            using (var w = new BinaryWriter(File.Create(path)))
            {
                int dataBytes = buf.Length * 2;
                w.Write(new[] { 'R', 'I', 'F', 'F' }); w.Write(36 + dataBytes);
                w.Write(new[] { 'W', 'A', 'V', 'E' });
                w.Write(new[] { 'f', 'm', 't', ' ' }); w.Write(16); w.Write((short)1); w.Write((short)1);
                w.Write(Rate); w.Write(Rate * 2); w.Write((short)2); w.Write((short)16);
                w.Write(new[] { 'd', 'a', 't', 'a' }); w.Write(dataBytes);
                for (int i = 0; i < buf.Length; i++)
                {
                    double s = buf[i] * gain;
                    if (i > buf.Length - fade) s *= (buf.Length - i) / (double)fade;
                    w.Write((short)Math.Max(-32767, Math.Min(32767, s * 32767)));
                }
            }
            return (int)((last + 0.45) * 1000);
        }
    }
}
