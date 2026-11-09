<#
================================================================================
 AI TRANSCRIBER STUDIO  -  Premium Edition
================================================================================
 Rebuilt audio + transcription core. Key fixes vs. previous version:

  [1] DEVICE DETECTION
      PROPVARIANT was declared 16 bytes; the real struct is 24 on x64.
      IPropertyStore::GetValue overran the stack and nulled the adjacent COM
      pointer, throwing NullReferenceException that an empty `catch {}`
      swallowed -> the device list silently came back empty.
      Now marshalled through a correctly sized native buffer + PropVariantClear.

  [2] VU METERS
      IAudioMeterInformation on a *capture* endpoint reports 0.0 unless a
      capture stream is open on that device (measured). The mic meter therefore
      never moved. A lightweight monitor stream now drives the mic meter, and
      while recording the meters read the real captured samples.

  [3] CRASHES
      Process.Exited fires on a ThreadPool thread, and invoking a PowerShell
      scriptblock delegate from there kills the host outright (reproduced: exit
      code 2, handler never ran, so isProcessingChunk stayed $true and live
      transcription stopped after a single chunk).

      Marshalling the event onto the UI thread with SynchronizingObject is not
      enough: the callback still arrives through Control.MarshaledInvoke, and
      when the message pump dispatches it while the runspace is already running
      another scriptblock, the process dies with no error at all. Windows Error
      Reporting named the pair exactly - System.Management.Automation.Runtime /
      System.Windows.Forms.Control.MarshaledInvoke.

      No PowerShell scriptblock is attached to a Process event anywhere now.
      Child processes run through the ProcRunner class below, which buffers
      output using C# delegates, and PowerShell only polls it from the UI
      thread. A DoEvents pump is also latched (UiBusy) so it cannot re-enter
      itself and overflow the stack.

  [4] AUDIO QUALITY
      The old loop called GetBuffer once per 20 ms sleep and zero-padded when
      nothing was ready. Measured loss: 62.3% (mic) / 42.7% (loopback).
      Now every queued packet is drained, streams are mixed from bounded
      queues (never zero-padded), and downsampling runs through a 4th-order
      anti-alias filter instead of bare linear interpolation. Loss: ~1%.

  [5] TRANSCRIPT QUALITY
      -oj emits no per-token data, so the confidence/Levenshtein pass was dead
      code. Now uses -ojf, filters special tokens, and pins English-only
      models to -l en instead of -l auto.
================================================================================
#>

# Deliberately not StrictMode: a typo should not take down a running recording.
# Risky operations are wrapped in try/catch and surfaced in the UI instead.
$ErrorActionPreference = 'Continue'

# --- High-DPI + visual styles must be set before any control is created ------
try {
    Add-Type -Namespace Native -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@ -ErrorAction SilentlyContinue
    [void][Native.Dpi]::SetProcessDPIAware()
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
# Must be set before any control exists on this thread, otherwise it throws and
# Application.ThreadException never fires, letting handler faults kill the app.
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
        [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch { }

# --- Paths -------------------------------------------------------------------
$WhisperDir = Split-Path -Parent $PSCommandPath
$WhisperExe = Join-Path $WhisperDir 'whisper-cli.exe'
$AppDataDir = Join-Path $env:APPDATA 'AITranscriberStudio'
$SettingsPath = Join-Path $AppDataDir 'settings.json'
if (-not (Test-Path $AppDataDir)) { [void](New-Item -ItemType Directory -Path $AppDataDir -Force) }

# ==============================================================================
#  AUDIO ENGINE
# ==============================================================================
if (-not ([System.Management.Automation.PSTypeName]'AudioEngine.CoreAudio').Type) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace AudioEngine
{
    /// <summary>
    /// Runs a child process and buffers its output entirely inside .NET.
    ///
    /// Attaching PowerShell scriptblocks to Process events is fatal here. Even
    /// with SynchronizingObject set, the event is delivered through
    /// Control.MarshaledInvoke, and if the message pump dispatches it while the
    /// runspace is already executing another scriptblock, the PowerShell
    /// runtime tears the process down - no exception, no error, just gone.
    /// (Confirmed in WER: System.Management.Automation.Runtime /
    /// System.Windows.Forms.Control.MarshaledInvoke.)
    ///
    /// The callbacks below are C# lambdas, so they are safe on any thread, and
    /// PowerShell only ever polls this object from the UI thread.
    /// </summary>
    public sealed class ProcRunner : IDisposable
    {
        Process _p;
        readonly StringBuilder _out = new StringBuilder();
        readonly StringBuilder _err = new StringBuilder();
        readonly object _lock = new object();
        volatile bool _started;
        volatile bool _outputClosed=true, _errorClosed=true;

        public string Error = "";

        public bool Start(string exe, string args, string workDir, bool redirect)
        {
            try
            {
                var psi = new ProcessStartInfo();
                psi.FileName = exe;
                psi.Arguments = args;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                if (!string.IsNullOrEmpty(workDir)) psi.WorkingDirectory = workDir;
                if (redirect)
                {
                    psi.RedirectStandardOutput = true;
                    psi.RedirectStandardError = true;
                    psi.StandardOutputEncoding = Encoding.UTF8;
                    psi.StandardErrorEncoding = Encoding.UTF8;
                }
                _p = new Process();
                _p.StartInfo = psi;
                if (redirect)
                {
                    _outputClosed=false; _errorClosed=false;
                    _p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e)
                    { if (e.Data == null) _outputClosed=true; else { lock (_lock) { AppendBounded(_out,e.Data); } } };
                    _p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e)
                    { if (e.Data == null) _errorClosed=true; else { lock (_lock) { AppendBounded(_err,e.Data); } } };
                }
                if (!_p.Start()) { Error = "Process failed to start."; return false; }
                if (redirect) { _p.BeginOutputReadLine(); _p.BeginErrorReadLine(); }
                _started = true;
                return true;
            }
            catch (Exception ex) { Error = ex.Message; return false; }
        }

        static void AppendBounded(StringBuilder buffer,string line)
        {
            const int limit=262144;
            if(line.Length>limit)line=line.Substring(line.Length-limit);
            if(buffer.Length+line.Length+2>limit)buffer.Remove(0,Math.Min(buffer.Length,buffer.Length+line.Length+2-limit));
            buffer.AppendLine(line);
        }

        public bool HasExited
        {
            get { try { return _p == null || (_p.HasExited && _outputClosed && _errorClosed); } catch { return true; } }
        }

        public int ExitCode
        {
            get { try { return (_p != null && _p.HasExited) ? _p.ExitCode : -1; } catch { return -1; } }
        }

        public int Id { get { try { return _started && _p != null ? _p.Id : -1; } catch { return -1; } } }

        public string DrainOutput()
        {
            lock (_lock) { string s = _out.ToString(); _out.Length = 0; return s; }
        }

        public string DrainError()
        {
            lock (_lock) { string s = _err.ToString(); _err.Length = 0; return s; }
        }

        public void Kill()
        {
            try { if (_p != null && !_p.HasExited) _p.Kill(); } catch { }
        }

        public void WaitForExit(int ms)
        {
            try { if (_p != null) _p.WaitForExit(ms); } catch { }
        }

        public void Dispose()
        {
            try { if (_p != null) _p.Dispose(); } catch { }
            _p = null;
        }
    }

    public class AudioDeviceItem
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public bool IsDefault { get; set; }
        public override string ToString() { return IsDefault ? Name + "   (Default)" : Name; }
    }

    internal enum SampleFormat { Unknown = 0, Float32 = 1, Pcm16 = 2, Pcm24 = 3, Pcm32 = 4 }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IMMDeviceCollection ppDevices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
    }

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceCollection
    {
        int GetCount(out int pcDevices);
        int Item(int nDevice, out IMMDevice ppDevice);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(int stgmAccess, out IPropertyStore ppProperties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        int GetState(out int pdwState);
    }

    // GetValue takes a raw pointer: the caller allocates a correctly sized
    // PROPVARIANT. Declaring it as a managed struct is what corrupted the stack.
    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        int GetCount(out int cProps);
        int GetAt(int iProp, IntPtr pkey);
        int GetValue(ref PropertyKey key, IntPtr pv);
        int SetValue(ref PropertyKey key, IntPtr pv);
        int Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid guid, uint id) { fmtid = guid; pid = id; }
    }

    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioMeterInformation { int GetPeakValue(out float pfPeak); }

    [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
        int Initialize(int ShareMode, int StreamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, ref Guid AudioSessionGuid);
        int GetBufferSize(out uint pNumBufferFrames);
        int GetStreamLatency(out long phnsLatency);
        int GetCurrentPadding(out uint pNumPaddingFrames);
        int IsFormatSupported(int ShareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
        int GetMixFormat(out IntPtr ppDeviceFormat);
        int GetDevicePeriod(out long phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr eventHandle);
        int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioCaptureClient
    {
        int GetBuffer(out IntPtr ppData, out uint pNumFramesToRead, out int pdwFlags, out ulong pu64DevicePosition, out ulong pu64QPCPosition);
        int ReleaseBuffer(uint NumFramesRead);
        int GetNextPacketSize(out uint pNumFramesInNextPacket);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    internal struct WaveFormatEx
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    // Transposed direct-form II biquad. Two cascaded sections give a
    // 4th-order Butterworth low-pass used as the anti-alias filter before
    // decimation to 16 kHz.
    internal sealed class Biquad
    {
        double b0, b1, b2, a1, a2, z1, z2;
        public static Biquad LowPass(double fs, double fc, double q)
        {
            var f = new Biquad();
            double w = 2.0 * Math.PI * fc / fs;
            double cw = Math.Cos(w), sw = Math.Sin(w);
            double alpha = sw / (2.0 * q);
            double a0 = 1.0 + alpha;
            f.b0 = ((1.0 - cw) / 2.0) / a0;
            f.b1 = (1.0 - cw) / a0;
            f.b2 = f.b0;
            f.a1 = (-2.0 * cw) / a0;
            f.a2 = (1.0 - alpha) / a0;
            return f;
        }
        public float Process(float x)
        {
            double y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return (float)y;
        }
    }

    // Removes DC bias, which otherwise eats headroom and skews the meters.
    internal sealed class DcBlocker
    {
        float x1, y1;
        public float Process(float x)
        {
            float y = x - x1 + 0.995f * y1;
            x1 = x; y1 = y;
            return y;
        }
    }

    internal sealed class CaptureStream : IDisposable
    {
        IMMDeviceEnumerator _en;
        IMMDevice _dev;
        IAudioClient _client;
        IAudioCaptureClient _cap;
        int _ch, _rate, _blockAlign;
        SampleFormat _fmt = SampleFormat.Unknown;
        Biquad _lpA, _lpB;
        DcBlocker _dc = new DcBlocker();
        double _phase;
        float _last;
        float[] _mono = new float[0];
        float[] _fbuf = new float[0];
        short[] _sbuf = new short[0];
        int[] _ibuf = new int[0];
        byte[] _bbuf = new byte[0];

        public readonly Queue<float> Out = new Queue<float>();
        public float Peak;
        public string Error = "";
        public bool IsOpen { get { return _cap != null; } }
        public string FormatInfo { get; private set; }

        static readonly Guid CLSID_MMDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        static readonly Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
        static readonly Guid IID_IAudioCaptureClient = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
        static readonly Guid SUBTYPE_PCM = new Guid("00000001-0000-0010-8000-00aa00389b71");
        static readonly Guid SUBTYPE_IEEE_FLOAT = new Guid("00000003-0000-0010-8000-00aa00389b71");

        public bool Open(string devId, int dataFlow, bool loopback)
        {
            IntPtr pFmt = IntPtr.Zero;
            try
            {
                Type t = Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator);
                _en = (IMMDeviceEnumerator)Activator.CreateInstance(t);

                int hr;
                if (string.IsNullOrEmpty(devId) || devId == "default")
                    hr = _en.GetDefaultAudioEndpoint(dataFlow, 0, out _dev);
                else
                {
                    hr = _en.GetDevice(devId, out _dev);
                    // Fall back to the default endpoint if the saved device is gone.
                    if (hr != 0 || _dev == null) hr = _en.GetDefaultAudioEndpoint(dataFlow, 0, out _dev);
                }
                if (hr != 0 || _dev == null) { Error = "No audio endpoint available (hr=0x" + hr.ToString("X8") + ")"; return false; }

                Guid cid = IID_IAudioClient;
                object o;
                hr = _dev.Activate(ref cid, 23, IntPtr.Zero, out o);
                if (hr != 0 || o == null) { Error = "Device is busy or blocked (hr=0x" + hr.ToString("X8") + ")"; return false; }
                _client = (IAudioClient)o;

                hr = _client.GetMixFormat(out pFmt);
                if (hr != 0 || pFmt == IntPtr.Zero) { Error = "GetMixFormat failed (hr=0x" + hr.ToString("X8") + ")"; return false; }

                var wf = (WaveFormatEx)Marshal.PtrToStructure(pFmt, typeof(WaveFormatEx));
                _ch = wf.nChannels > 0 ? wf.nChannels : 2;
                _rate = (int)wf.nSamplesPerSec;
                _blockAlign = wf.nBlockAlign > 0 ? wf.nBlockAlign : (_ch * wf.wBitsPerSample / 8);

                // WAVE_FORMAT_EXTENSIBLE (0xFFFE) hides the real type in SubFormat
                // at offset 24. The old code just assumed 32-bit meant float.
                if (wf.wFormatTag == 0xFFFE && wf.cbSize >= 22)
                {
                    byte[] g = new byte[16];
                    Marshal.Copy(new IntPtr(pFmt.ToInt64() + 24), g, 0, 16);
                    Guid sub = new Guid(g);
                    if (sub == SUBTYPE_IEEE_FLOAT) _fmt = SampleFormat.Float32;
                    else if (sub == SUBTYPE_PCM)
                    {
                        if (wf.wBitsPerSample == 16) _fmt = SampleFormat.Pcm16;
                        else if (wf.wBitsPerSample == 24) _fmt = SampleFormat.Pcm24;
                        else if (wf.wBitsPerSample == 32) _fmt = SampleFormat.Pcm32;
                    }
                }
                else if (wf.wFormatTag == 3) _fmt = SampleFormat.Float32;
                else if (wf.wFormatTag == 1)
                {
                    if (wf.wBitsPerSample == 16) _fmt = SampleFormat.Pcm16;
                    else if (wf.wBitsPerSample == 24) _fmt = SampleFormat.Pcm24;
                    else if (wf.wBitsPerSample == 32) _fmt = SampleFormat.Pcm32;
                }
                if (_fmt == SampleFormat.Unknown)
                {
                    Error = "Unsupported mix format (tag=" + wf.wFormatTag + ", bits=" + wf.wBitsPerSample + ")";
                    return false;
                }
                FormatInfo = _rate + " Hz / " + _ch + " ch / " + _fmt;

                Guid session = Guid.Empty;
                int flags = loopback ? 0x00020000 : 0;   // AUDCLNT_STREAMFLAGS_LOOPBACK
                hr = _client.Initialize(0, flags, 10000000, 0, pFmt, ref session);
                if (hr != 0) { Error = "Initialize failed (hr=0x" + hr.ToString("X8") + ")"; return false; }

                Guid capId = IID_IAudioCaptureClient;
                object co;
                hr = _client.GetService(ref capId, out co);
                if (hr != 0 || co == null) { Error = "GetService failed (hr=0x" + hr.ToString("X8") + ")"; return false; }
                _cap = (IAudioCaptureClient)co;

                if (_rate != 16000)
                {
                    // Butterworth Q pair for a 4th-order cascade, cutoff below
                    // the 8 kHz Nyquist of the 16 kHz target rate.
                    double fc = Math.Min(7200.0, _rate * 0.45);
                    _lpA = Biquad.LowPass(_rate, fc, 0.54119610);
                    _lpB = Biquad.LowPass(_rate, fc, 1.30656296);
                }
                CheckResult(_client.Start(), "Start audio capture");
                return true;
            }
            catch (Exception ex) { Error = ex.Message; return false; }
            finally { if (pFmt != IntPtr.Zero) Marshal.FreeCoTaskMem(pFmt); }
        }

        public float TakePeak() { float p = Peak; Peak = 0f; return p; }
        internal static void CheckResult(int hr,string operation) {
            if(hr<0)throw new IOException(operation+" failed (HRESULT 0x"+hr.ToString("X8")+"). Check whether the audio device was disconnected or changed.",Marshal.GetExceptionForHR(hr));
        }

        // Drains every queued packet. The previous implementation read one
        // packet per 20 ms sleep, which discarded most of the audio.
        public void Drain(bool keep)
        {
            if (_cap == null) return;
            float peak = Peak;
            try
            {
                while (true)
                {
                    uint next;
                    CheckResult(_cap.GetNextPacketSize(out next), "Read audio packet size");
                    if (next == 0) break;

                    IntPtr pData; uint frames; int flags; ulong dpos, qpos;
                    int bufferStatus=_cap.GetBuffer(out pData, out frames, out flags, out dpos, out qpos);
                    CheckResult(bufferStatus, "Read audio buffer");
                    if(bufferStatus!=0)break;
                    try
                    {
                        int n = (int)frames;
                        if (n <= 0) continue;
                        if (_mono.Length < n) _mono = new float[n * 2];

                        if ((flags & 2) != 0 || pData == IntPtr.Zero) Array.Clear(_mono, 0, n);  // AUDCLNT_BUFFERFLAGS_SILENT
                        else ToMono(pData, n);

                        for (int i = 0; i < n; i++) { float a = _mono[i]; if (a < 0f) a = -a; if (a > peak) peak = a; }
                        Resample(n, keep);
                    }
                    finally { CheckResult(_cap.ReleaseBuffer(frames), "Release audio buffer"); }
                }
            }
            catch (Exception ex) { Error=ex.Message;throw; }
            Peak = peak;
        }

        void ToMono(IntPtr p, int frames)
        {
            int ch = _ch;
            int total = frames * ch;
            float inv = 1.0f / ch;
            switch (_fmt)
            {
                case SampleFormat.Float32:
                    if (_fbuf.Length < total) _fbuf = new float[total * 2];
                    Marshal.Copy(p, _fbuf, 0, total);
                    for (int f = 0; f < frames; f++)
                    {
                        float s = 0f; int b = f * ch;
                        for (int c = 0; c < ch; c++) s += _fbuf[b + c];
                        _mono[f] = s * inv;
                    }
                    break;
                case SampleFormat.Pcm16:
                    if (_sbuf.Length < total) _sbuf = new short[total * 2];
                    Marshal.Copy(p, _sbuf, 0, total);
                    for (int f = 0; f < frames; f++)
                    {
                        float s = 0f; int b = f * ch;
                        for (int c = 0; c < ch; c++) s += _sbuf[b + c] * (1f / 32768f);
                        _mono[f] = s * inv;
                    }
                    break;
                case SampleFormat.Pcm32:
                    if (_ibuf.Length < total) _ibuf = new int[total * 2];
                    Marshal.Copy(p, _ibuf, 0, total);
                    for (int f = 0; f < frames; f++)
                    {
                        double s = 0.0; int b = f * ch;
                        for (int c = 0; c < ch; c++) s += _ibuf[b + c] / 2147483648.0;
                        _mono[f] = (float)(s * inv);
                    }
                    break;
                case SampleFormat.Pcm24:
                    int bytes = frames * _blockAlign;
                    if (_bbuf.Length < bytes) _bbuf = new byte[bytes * 2];
                    Marshal.Copy(p, _bbuf, 0, bytes);
                    for (int f = 0; f < frames; f++)
                    {
                        double s = 0.0; int b = f * _blockAlign;
                        for (int c = 0; c < ch; c++)
                        {
                            int o = b + c * 3;
                            int v = _bbuf[o] | (_bbuf[o + 1] << 8) | ((sbyte)_bbuf[o + 2] << 16);
                            s += v / 8388608.0;
                        }
                        _mono[f] = (float)(s * inv);
                    }
                    break;
                default:
                    Array.Clear(_mono, 0, frames);
                    break;
            }
        }

        // Filter, then decimate to 16 kHz with a phase accumulator that carries
        // across packet boundaries (no clicks at packet seams).
        void Resample(int n, bool keep)
        {
            for (int i = 0; i < n; i++) _mono[i] = _dc.Process(_mono[i]);

            if (_rate == 16000)
            {
                if (keep) for (int i = 0; i < n; i++) Out.Enqueue(_mono[i]);
                return;
            }
            for (int i = 0; i < n; i++) _mono[i] = _lpB.Process(_lpA.Process(_mono[i]));

            double step = _rate / 16000.0;
            while (_phase < n)
            {
                int i = (int)_phase;
                double f = _phase - i;
                float a = (i == 0) ? _last : _mono[i - 1];
                float b = _mono[i];
                if (keep) Out.Enqueue((float)(a * (1.0 - f) + b * f));
                _phase += step;
            }
            _phase -= n;
            _last = _mono[n - 1];
        }

        public void Dispose()
        {
            try { if (_client != null) _client.Stop(); } catch { }
            try { if (_cap != null) Marshal.ReleaseComObject(_cap); } catch { }
            try { if (_client != null) Marshal.ReleaseComObject(_client); } catch { }
            try { if (_dev != null) Marshal.ReleaseComObject(_dev); } catch { }
            try { if (_en != null) Marshal.ReleaseComObject(_en); } catch { }
            _cap = null; _client = null; _dev = null; _en = null;
        }
    }

    public static class CoreAudio
    {
        static readonly Guid CLSID_MMDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        static readonly Guid IID_IAudioMeterInformation = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
        static readonly PropertyKey PKEY_Device_FriendlyName = new PropertyKey(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 14);

        [DllImport("ole32.dll")] static extern int PropVariantClear(IntPtr pvar);

        public const int SampleRate = 16000;

        // ---------------- device enumeration ----------------
        public static string LastError = "";

        public static List<AudioDeviceItem> GetDevices(int dataFlow)
        {
            var list = new List<AudioDeviceItem>();
            IMMDeviceEnumerator en = null;
            IMMDeviceCollection col = null;
            IntPtr pv = IntPtr.Zero;
            try
            {
                Type t = Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator);
                if (t == null) { LastError = "MMDeviceEnumerator class not registered."; return list; }
                en = (IMMDeviceEnumerator)Activator.CreateInstance(t);

                string defId = "";
                IMMDevice defDev = null;
                if (en.GetDefaultAudioEndpoint(dataFlow, 0, out defDev) == 0 && defDev != null)
                {
                    defDev.GetId(out defId);
                    Marshal.ReleaseComObject(defDev);
                }

                int hr = en.EnumAudioEndpoints(dataFlow, 1, out col);   // DEVICE_STATE_ACTIVE
                if (hr != 0 || col == null) { LastError = "EnumAudioEndpoints failed (hr=0x" + hr.ToString("X8") + ")"; return list; }

                int count;
                col.GetCount(out count);

                // 32 bytes covers PROPVARIANT on x86 (16) and x64 (24).
                pv = Marshal.AllocCoTaskMem(32);

                for (int i = 0; i < count; i++)
                {
                    IMMDevice dev = null;
                    try
                    {
                        if (col.Item(i, out dev) != 0 || dev == null) continue;
                        string id;
                        if (dev.GetId(out id) != 0 || string.IsNullOrEmpty(id)) continue;

                        string name = "Audio Device";
                        IPropertyStore store = null;
                        try
                        {
                            if (dev.OpenPropertyStore(0, out store) == 0 && store != null)
                            {
                                for (int b = 0; b < 32; b++) Marshal.WriteByte(pv, b, 0);
                                PropertyKey key = PKEY_Device_FriendlyName;
                                if (store.GetValue(ref key, pv) == 0)
                                {
                                    short vt = Marshal.ReadInt16(pv, 0);
                                    IntPtr sp = Marshal.ReadIntPtr(pv, 8);
                                    if (vt == 31 && sp != IntPtr.Zero)   // VT_LPWSTR
                                    {
                                        string s = Marshal.PtrToStringUni(sp);
                                        if (!string.IsNullOrEmpty(s)) name = s;
                                    }
                                }
                                PropVariantClear(pv);
                            }
                        }
                        finally { if (store != null) Marshal.ReleaseComObject(store); }

                        list.Add(new AudioDeviceItem { Id = id, Name = name, IsDefault = (id == defId) });
                    }
                    finally { if (dev != null) Marshal.ReleaseComObject(dev); }
                }
                LastError = "";
            }
            catch (Exception ex) { LastError = ex.Message; }
            finally
            {
                if (pv != IntPtr.Zero) Marshal.FreeCoTaskMem(pv);
                if (col != null) { try { Marshal.ReleaseComObject(col); } catch { } }
                if (en != null) { try { Marshal.ReleaseComObject(en); } catch { } }
            }
            return list;
        }

        // ---------------- cached endpoint meter (render side) ----------------
        // Recreating an enumerator 15x/second was pure COM churn; these are
        // cached per device id and reused.
        static readonly Dictionary<string, IAudioMeterInformation> _meters = new Dictionary<string, IAudioMeterInformation>();
        static readonly Dictionary<string, IMMDevice> _meterDevs = new Dictionary<string, IMMDevice>();

        public static float GetRenderPeak(string deviceId)
        {
            if (string.IsNullOrEmpty(deviceId)) return 0f;
            try
            {
                IAudioMeterInformation meter;
                if (!_meters.TryGetValue(deviceId, out meter))
                {
                    Type t = Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator);
                    var en = (IMMDeviceEnumerator)Activator.CreateInstance(t);
                    IMMDevice dev = null;
                    try
                    {
                        if (en.GetDevice(deviceId, out dev) != 0 || dev == null) return 0f;
                        Guid iid = IID_IAudioMeterInformation;
                        object mo;
                        if (dev.Activate(ref iid, 23, IntPtr.Zero, out mo) != 0 || mo == null) return 0f;
                        meter = (IAudioMeterInformation)mo;
                        _meters[deviceId] = meter;
                        _meterDevs[deviceId] = dev;
                        dev = null;   // ownership moved into the cache
                    }
                    finally
                    {
                        if (dev != null) Marshal.ReleaseComObject(dev);
                        Marshal.ReleaseComObject(en);
                    }
                }
                float peak;
                if (meter.GetPeakValue(out peak) != 0) return 0f;
                return peak;
            }
            catch
            {
                ClearMeterCache();   // device probably went away
                return 0f;
            }
        }

        public static void ClearMeterCache()
        {
            foreach (var kv in _meters) { try { Marshal.ReleaseComObject(kv.Value); } catch { } }
            foreach (var kv in _meterDevs) { try { Marshal.ReleaseComObject(kv.Value); } catch { } }
            _meters.Clear();
            _meterDevs.Clear();
        }

        // ---------------- shared level state ----------------
        static float _sysPeak, _micPeak;
        public static float TakeSysPeak() { float v = _sysPeak; _sysPeak = 0f; return v; }
        public static float TakeMicPeak() { float v = _micPeak; _micPeak = 0f; return v; }

        // ---------------- mic monitor (drives the meter while idle) ----------
        static Thread _monThread;
        static volatile bool _monRunning;
        static volatile int _monGeneration;
        static readonly object _monLock = new object();
        public static string MonitorError = "";

        // Toggling the mic checkbox or switching tabs can restart the monitor
        // faster than a worker can open its endpoint. Each worker carries the
        // generation it was started for and exits as soon as that is stale, so a
        // thread whose Join timed out can never keep using a device the next
        // worker has already taken.
        public static void StartMonitor(string micDevId)
        {
            lock (_monLock)
            {
                StopMonitorLocked();
                int gen = ++_monGeneration;
                string dev = micDevId ?? "";
                _monRunning = true;
                var th = new Thread(delegate () { MonitorWorker(gen, dev); });
                th.IsBackground = true;
                th.Name = "MicMonitor";
                _monThread = th;
                th.Start();
            }
        }

        public static void StopMonitor()
        {
            lock (_monLock) { StopMonitorLocked(); }
        }

        static void StopMonitorLocked()
        {
            _monGeneration++;               // invalidates any worker still running
            _monRunning = false;
            var th = _monThread;
            _monThread = null;
            if (th != null && th.IsAlive) { try { th.Join(1500); } catch { } }
            _micPeak = 0f;
        }

        public static bool IsMonitoring { get { return _monRunning; } }

        static void MonitorWorker(int gen, string devId)
        {
            CaptureStream mic = null;
            try
            {
                mic = new CaptureStream();
                if (!mic.Open(devId, 1, false))
                {
                    if (gen == _monGeneration) MonitorError = mic.Error;
                    return;
                }
                if (gen != _monGeneration) return;          // superseded while opening
                MonitorError = "";
                while (_monRunning && gen == _monGeneration)
                {
                    mic.Drain(false);                       // level only, discard samples
                    float p = mic.TakePeak();
                    if (p > _micPeak) _micPeak = p;
                    Thread.Sleep(15);
                }
            }
            catch (Exception ex) { if (gen == _monGeneration) MonitorError = ex.Message; }
            finally { if (mic != null) mic.Dispose(); if(gen==_monGeneration){_monRunning=false;_monThread=null;} }
        }

        // ---------------- recording ----------------
        static Thread _recThread;
        static readonly object _recLifecycleLock = new object();
        static volatile bool _recRunning;
        static readonly object _wavLock = new object();
        static readonly object _tailLock = new object();
        static FileStream _wav;
        static long _dataBytes;
        static string _wavPath = "";

        const int TailSeconds = 90;
        static readonly short[] _tail = new short[SampleRate * TailSeconds];
        static long _totalSamples;
        static long _lastExportEnd;

        static string _recSysId, _recMicId;
        static bool _recSys, _recMic;
        static float _sysVol = 1f, _micVol = 1f;
        public static string RecordError = "";
        public static string StreamInfo = "";

        public static bool IsRecording { get { return _recRunning; } }
        public static long RecordedSamples { get { return Interlocked.Read(ref _totalSamples); } }

        public static void StartRecording(string outputDevId, string micDevId, bool recordSys, bool recordMic,
                                          float sysVol, float micVol, string wavFilePath)
        {
            lock (_recLifecycleLock)
            {
            if (_recThread != null && _recThread.IsAlive) throw new InvalidOperationException("The previous audio worker is still stopping. Wait before starting another session.");
            if (_recRunning) return;
            StopMonitor();

            _recSysId = outputDevId; _recMicId = micDevId;
            _recSys = recordSys; _recMic = recordMic;
            _sysVol = sysVol; _micVol = micVol;
            _wavPath = wavFilePath;
            RecordError = ""; StreamInfo = "";

            lock (_tailLock) { _totalSamples = 0; _lastExportEnd = 0; Array.Clear(_tail, 0, _tail.Length); }
            lock (_wavLock)
            {
                _dataBytes = 0;
                _wav = new FileStream(wavFilePath, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 16);
                _wav.Write(new byte[44], 0, 44);       // header patched on close
            }

            _recRunning = true;
            _recThread = new Thread(RecordWorker);
            _recThread.IsBackground = true;
            _recThread.Name = "AudioRecorder";
            _recThread.Priority = ThreadPriority.AboveNormal;
            _recThread.Start();
            }
        }

        public static void StopRecording()
        {
            Thread th;
            lock (_recLifecycleLock) { _recRunning = false; th = _recThread; }
            if (th != null && th.IsAlive && !th.Join(2500)) throw new TimeoutException("The audio worker is still stopping. Wait and try again; a new recording has not been started.");
            lock (_recLifecycleLock) { if (_recThread == th) _recThread = null; }
            FinalizeRecordingFile();
            _sysPeak = 0f; _micPeak = 0f;
        }

        static void FinalizeRecordingFile()
        {
            lock (_wavLock)
            {
                if (_wav != null)
                {
                    try
                    {
                        _wav.Flush();
                        _wav.Seek(0, SeekOrigin.Begin);
                        var bw = new BinaryWriter(_wav);
                        WriteWavHeader(bw, (int)_dataBytes, SampleRate, 1, 16);
                        bw.Flush();
                    }
                    catch (Exception ex) { RecordError += " WAV finalization failed: " + ex.Message; }
                    try { _wav.Dispose(); } catch { }
                    _wav = null;
                }
            }
        }

        static float SoftClip(float x)
        {
            // Gentle knee above 0.7 instead of the old hard clamp, which
            // squared off loud passages and added audible distortion.
            const float t = 0.7f;
            float a = x < 0f ? -x : x;
            if (a <= t) return x;
            float sign = x < 0f ? -1f : 1f;
            double over = (a - t) / (1.0 - t);
            return sign * (float)(t + (1.0 - t) * Math.Tanh(over));
        }

        static void RecordWorker()
        {
            CaptureStream sys = null, mic = null;
            short[] mix = new short[SampleRate];
            var errors = new List<string>();
            var info = new List<string>();
            try
            {
                if (_recSys)
                {
                    sys = new CaptureStream();
                    if (!sys.Open(_recSysId, 0, true)) { errors.Add("System audio: " + sys.Error); sys.Dispose(); sys = null; }
                    else info.Add("System " + sys.FormatInfo);
                }
                if (_recMic)
                {
                    mic = new CaptureStream();
                    if (!mic.Open(_recMicId, 1, false)) { errors.Add("Microphone: " + mic.Error); mic.Dispose(); mic = null; }
                    else info.Add("Mic " + mic.FormatInfo);
                }
                RecordError = string.Join(" | ", errors.ToArray());
                StreamInfo = string.Join("   |   ", info.ToArray());
                if (sys == null && mic == null)
                {
                    if (RecordError == "") RecordError = "No capture device could be opened.";
                    return;
                }

                // WASAPI loopback delivers no packets at all while nothing is
                // playing, so an empty system queue usually means real silence
                // rather than "not ready yet". Requiring a few consecutive empty
                // polls before treating a stream as silent keeps normal jitter
                // from pulling the two streams out of alignment.
                int sysIdle = 0, micIdle = 0;
                const int IdleTicks = 3;

                // Started only once the endpoints are actually open, so device
                // open latency is not charged to the recording.
                var clock = System.Diagnostics.Stopwatch.StartNew();

                while (_recRunning)
                {
                    if (sys != null) sys.Drain(true);
                    if (mic != null) mic.Drain(true);

                    if (sys != null) { float p = sys.TakePeak(); if (p > _sysPeak) _sysPeak = p; }
                    if (mic != null) { float p = mic.TakePeak(); if (p > _micPeak) _micPeak = p; }

                    int sc = (sys != null) ? sys.Out.Count : -1;
                    int mc = (mic != null) ? mic.Out.Count : -1;

                    sysIdle = (sc == 0) ? sysIdle + 1 : 0;
                    micIdle = (mc == 0) ? micIdle + 1 : 0;

                    // Independent clocks drift. Trim only when both sides are
                    // actually producing, otherwise a silent loopback stream
                    // would look like a huge negative drift and eat mic audio.
                    if (sc > 0 && mc > 0)
                    {
                        int drift = sc - mc;
                        if (drift > SampleRate) { int drop = drift - SampleRate / 2; for (int i = 0; i < drop; i++) sys.Out.Dequeue(); }
                        else if (drift < -SampleRate) { int drop = -drift - SampleRate / 2; for (int i = 0; i < drop; i++) mic.Out.Dequeue(); }
                        sc = sys.Out.Count; mc = mic.Out.Count;
                    }

                    int avail = PlanMix(sc, mc, sysIdle >= IdleTicks, micIdle >= IdleTicks);
                    if (avail > 0) MixAndWrite(sys, mic, avail, ref mix);
                    else
                    {
                        // Loopback emits nothing at all while playback is silent,
                        // so a system-audio-only session would lose that time and
                        // the recording would drift shorter than real time.
                        // Pad against the wall clock, but only while every stream
                        // is confirmed idle so real audio is never displaced.
                        bool allIdle = ((sys == null) || sysIdle >= IdleTicks)
                                    && ((mic == null) || micIdle >= IdleTicks);
                        if (allIdle)
                        {
                            long shouldHave = (long)(clock.Elapsed.TotalSeconds * SampleRate);
                            long deficit = shouldHave - Interlocked.Read(ref _totalSamples);
                            if (deficit > SampleRate / 20)                     // more than 50 ms behind
                                WriteSilence((int)Math.Min(deficit, SampleRate));
                        }
                    }
                    Thread.Sleep(10);
                }

                // Flush whatever is still queued so the tail of the session is kept.
                if (sys != null) sys.Drain(true);
                if (mic != null) mic.Drain(true);
                int restS = (sys != null) ? sys.Out.Count : -1;
                int restM = (mic != null) ? mic.Out.Count : -1;
                int rest = PlanMix(restS, restM, true, true);
                if (rest > 0) MixAndWrite(sys, mic, rest, ref mix);
            }
            catch (Exception ex) { RecordError = ex.Message; }
            finally
            {
                _recRunning = false;
                try { if (sys != null) sys.Dispose(); } catch { }
                try { if (mic != null) mic.Dispose(); } catch { }
                FinalizeRecordingFile();
                lock (_recLifecycleLock) { if (_recThread == Thread.CurrentThread) _recThread = null; }
            }
        }

        // Counts of -1 mean the stream is disabled. Returns how many samples can
        // be emitted now. A stream that is confirmed silent contributes silence
        // instead of stalling the mix; when neither side has data nothing is
        // written, because inventing samples is what stretched the old timeline.
        static int PlanMix(int sysCount, int micCount, bool sysSilent, bool micSilent)
        {
            if (sysCount >= 0 && micCount >= 0)
            {
                if (sysCount > 0 && micCount > 0) return Math.Min(sysCount, micCount);
                if (sysCount > 0 && micSilent) return sysCount;
                if (micCount > 0 && sysSilent) return micCount;
                return 0;
            }
            if (sysCount >= 0) return sysCount;
            if (micCount >= 0) return micCount;
            return 0;
        }

        static void MixAndWrite(CaptureStream sys, CaptureStream mic, int count, ref short[] mix)
        {
            if (mix.Length < count) mix = new short[count * 2];
            for (int i = 0; i < count; i++)
            {
                float s = (sys != null && sys.Out.Count > 0) ? sys.Out.Dequeue() * _sysVol : 0f;
                float m = (mic != null && mic.Out.Count > 0) ? mic.Out.Dequeue() * _micVol : 0f;
                mix[i] = (short)(SoftClip(s + m) * 32767f);
            }
            WriteSamples(mix, count);
        }

        static short[] _silence = new short[0];
        static void WriteSilence(int count)
        {
            if (count <= 0) return;
            if (_silence.Length < count) _silence = new short[count];
            else Array.Clear(_silence, 0, count);
            WriteSamples(_silence, count);
        }

        static void WriteSamples(short[] buf, int count)
        {
            byte[] bytes = new byte[count * 2];
            Buffer.BlockCopy(buf, 0, bytes, 0, bytes.Length);
            lock (_wavLock)
            {
                if (_wav != null) { _wav.Write(bytes, 0, bytes.Length); _dataBytes += bytes.Length; }
            }
            lock (_tailLock)
            {
                int cap = _tail.Length;
                for (int i = 0; i < count; i++) _tail[(int)((_totalSamples + i) % cap)] = buf[i];
                _totalSamples += count;
            }
        }

        // Returns the audio recorded since the previous call (with a small
        // overlap so words spanning a boundary are not lost), or null when
        // there is not enough new material yet.
        public static string ExportRecentChunk(string chunkWavPath, int secondsWindow)
        {
            short[] buf;
            lock (_tailLock)
            {
                long to = _totalSamples;
                long earliest = Math.Max(0, to - _tail.Length);
                long from = Math.Max(_lastExportEnd, earliest);
                if (to - from < SampleRate * 2) return null;                 // wait for >= 2 s
                long maxLen = (long)SampleRate * secondsWindow;
                if (to - from > maxLen) from = to - maxLen;

                int count = (int)(to - from);
                buf = new short[count];
                int cap = _tail.Length;
                for (int i = 0; i < count; i++) buf[i] = _tail[(int)((from + i) % cap)];

                _lastExportEnd = to - SampleRate / 2;                          // 0.5 s overlap
                if (_lastExportEnd < 0) _lastExportEnd = 0;
            }
            byte[] bytes = new byte[buf.Length * 2];
            Buffer.BlockCopy(buf, 0, bytes, 0, bytes.Length);
            SaveWavFile(chunkWavPath, bytes, SampleRate, 1, 16);
            return chunkWavPath;
        }

        static void WriteWavHeader(BinaryWriter bw, int dataBytes, int sampleRate, short channels, short bits)
        {
            int byteRate = sampleRate * channels * (bits / 8);
            short blockAlign = (short)(channels * (bits / 8));
            bw.Write(new char[] { 'R', 'I', 'F', 'F' });
            bw.Write(36 + dataBytes);
            bw.Write(new char[] { 'W', 'A', 'V', 'E' });
            bw.Write(new char[] { 'f', 'm', 't', ' ' });
            bw.Write(16);
            bw.Write((short)1);
            bw.Write(channels);
            bw.Write(sampleRate);
            bw.Write(byteRate);
            bw.Write(blockAlign);
            bw.Write(bits);
            bw.Write(new char[] { 'd', 'a', 't', 'a' });
            bw.Write(dataBytes);
        }

        static void SaveWavFile(string path, byte[] pcm, int sampleRate, short channels, short bits)
        {
            using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read))
            using (var bw = new BinaryWriter(fs))
            {
                WriteWavHeader(bw, pcm.Length, sampleRate, channels, bits);
                bw.Write(pcm);
            }
        }

        // ---------------- text utility ----------------
        public static int Levenshtein(string s, string t)
        {
            if (string.IsNullOrEmpty(s)) return t == null ? 0 : t.Length;
            if (string.IsNullOrEmpty(t)) return s.Length;
            int n = s.Length, m = t.Length;
            int[] d0 = new int[m + 1];
            int[] d1 = new int[m + 1];
            for (int j = 0; j <= m; j++) d0[j] = j;
            for (int i = 0; i < n; i++)
            {
                d1[0] = i + 1;
                for (int j = 0; j < m; j++)
                {
                    int cost = (s[i] == t[j]) ? 0 : 1;
                    d1[j + 1] = Math.Min(Math.Min(d1[j] + 1, d0[j + 1] + 1), d0[j] + cost);
                }
                for (int j = 0; j <= m; j++) d0[j] = d1[j];
            }
            return d0[m];
        }
    }
}
'@
}


# ==============================================================================
#  SETTINGS
# ==============================================================================
$script:Settings = @{
    OutputDevice = ''; InputDevice = ''; UseSystem = $true; UseMic = $true
    LiveModel = ''; FinalModel = ''; FileModel = ''; Language = 'auto'
    SaveFolder = [Environment]::GetFolderPath('Desktop'); Vocabulary = ''
    FileVocabulary = ''; SystemGain = 100; MicGain = 100
}

function Import-AppSettings {
    try {
        if (Test-Path $SettingsPath) {
            $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $raw.PSObject.Properties) {
                if (-not $script:Settings.ContainsKey($p.Name)) { continue }
                $expected = $script:Settings[$p.Name]
                if ($expected -is [bool] -and $p.Value -isnot [bool]) { continue }
                if ($expected -is [string] -and ($p.Value -isnot [string] -or $p.Value.Length -gt 32768)) { continue }
                if ($expected -is [int] -and ($p.Value -isnot [int] -or $p.Value -lt 0 -or $p.Value -gt 200)) { continue }
                $script:Settings[$p.Name] = $p.Value
            }
        }
    } catch { }
}

function Export-AppSettings {
    $temp = $SettingsPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ([pscustomobject]$script:Settings | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($true)))
        if ([IO.File]::Exists($SettingsPath)) { [IO.File]::Replace($temp, $SettingsPath, $null) }
        else { [IO.File]::Move($temp, $SettingsPath) }
    } catch { }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
Import-AppSettings

# ==============================================================================
#  THEME
# ==============================================================================
function C ([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }
function CA ([int]$a, [int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

$Theme = @{
    Page        = (C 244 246 250)
    Surface     = (C 255 255 255)
    Inset       = (C 248 250 252)
    Border      = (C 226 232 240)
    BorderMuted = (C 236 240 246)
    Ink         = (C 15 23 42)
    InkSoft     = (C 71 85 105)
    InkMuted    = (C 130 143 163)
    Navy        = (C 16 24 43)
    NavySoft    = (C 148 163 184)
    Accent      = (C 37 99 235)
    AccentDark  = (C 29 78 216)
    AccentSoft  = (C 239 246 255)
    Danger      = (C 220 38 38)
    DangerDark  = (C 185 28 28)
    Success     = (C 5 150 105)
    SuccessSoft = (C 236 253 245)
    Amber       = (C 217 119 6)
    AmberSoft   = (C 255 251 235)
}

$FontUI      = New-Object System.Drawing.Font('Segoe UI', 9)
$FontUISemi  = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$FontLabel   = New-Object System.Drawing.Font('Segoe UI Semibold', 8.25)
$FontTitle   = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$FontBrand   = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$FontBrandSub= New-Object System.Drawing.Font('Segoe UI', 8.5)
$FontBtn     = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$FontMono    = New-Object System.Drawing.Font('Cascadia Mono', 9.5)
if ($FontMono.Name -ne 'Cascadia Mono') { $FontMono = New-Object System.Drawing.Font('Consolas', 9.5) }
$FontMeter   = New-Object System.Drawing.Font('Segoe UI Semibold', 7.5)

# ==============================================================================
#  DRAWING HELPERS
# ==============================================================================
function New-RoundedPath {
    param([System.Drawing.Rectangle]$Rect, [int]$Radius)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Max(1, $Radius * 2)
    if ($Rect.Width -le $d -or $Rect.Height -le $d) { $p.AddRectangle($Rect); return $p }
    $p.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $p.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Enable-DoubleBuffer($ctrl) {
    try {
        [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($ctrl, $true, $null)
    } catch { }
}

# Paint coordinates use the original 96-DPI design space. Pixel-unit fonts
# follow the same Graphics transform as paths, avoiding a second DPI expansion
# of point-unit fonts. The shared cache keeps the meter repaint allocation-free
# for fonts and is disposed after the window closes.
$script:PaintFontCache = @{}
function Get-AppPaintFont([System.Drawing.Font]$Font) {
    $key = $Font.Name + '|' + $Font.SizeInPoints.ToString('R', [Globalization.CultureInfo]::InvariantCulture) + '|' + [int]$Font.Style + '|' + $Font.GdiCharSet + '|' + $Font.GdiVerticalFont
    if (-not $script:PaintFontCache.ContainsKey($key)) {
        $script:PaintFontCache[$key] = [Drawing.Font]::new($Font.FontFamily, [single]($Font.SizeInPoints * 96.0 / 72.0), $Font.Style, [Drawing.GraphicsUnit]::Pixel, $Font.GdiCharSet, $Font.GdiVerticalFont)
    }
    return $script:PaintFontCache[$key]
}

# A card is a panel painted as a rounded white surface with a hairline border and
# a soft drop shadow. Its BackColor matches the page so the corners read clean.
function New-Card {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title = '')
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = [System.Drawing.Point]::new($X, $Y)
    $card.Size = [System.Drawing.Size]::new($W, $H)
    $card.BackColor = $Theme.Page
    Enable-DoubleBuffer $card
    $card | Add-Member -NotePropertyName CardTitle -NotePropertyValue $Title -Force
    $card.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $paintState = $g.Save()
        try {
            $paintScale = [single][Math]::Max(1.0, $script:UiScale)
            $g.PageUnit = [Drawing.GraphicsUnit]::Pixel
            $g.ScaleTransform($paintScale, $paintScale)
            $paintW = [single]($s.Width / $paintScale)
            $paintH = [single]($s.Height / $paintScale)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        # soft shadow: a few progressively lighter rounded outlines
        for ($i = 3; $i -ge 1; $i--) {
            $r = [System.Drawing.Rectangle]::new($i, $i + 1, $paintW - 1 - ($i * 2), $paintH - 1 - ($i * 2))
            $pth = New-RoundedPath $r 12
            $pen = New-Object System.Drawing.Pen((CA (10 * (4 - $i)) 15 23 42), 1)
            $g.DrawPath($pen, $pth); $pen.Dispose(); $pth.Dispose()
        }
        $rect = [System.Drawing.Rectangle]::new(0, 0, $paintW - 5, $paintH - 6)
        $path = New-RoundedPath $rect 12
        $br = New-Object System.Drawing.SolidBrush($Theme.Surface)
        $g.FillPath($br, $path); $br.Dispose()
        $pen = New-Object System.Drawing.Pen($Theme.Border, 1)
        $g.DrawPath($pen, $path); $pen.Dispose()
        $path.Dispose()
        if ($s.CardTitle) {
            $tb = New-Object System.Drawing.SolidBrush($Theme.Ink)
            $g.DrawString($s.CardTitle, (Get-AppPaintFont $FontTitle), $tb, 20, 16)
            $tb.Dispose()
            $lp = New-Object System.Drawing.Pen($Theme.BorderMuted, 1)
            $g.DrawLine($lp, 20, 44, $paintW - 25, 44)
            $lp.Dispose()
        }
    
        } finally { $g.Restore($paintState) }
    })
    return $card
}

function New-FieldLabel {
    param([string]$Text, [int]$X, [int]$Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text.ToUpper()
    $l.Location = [System.Drawing.Point]::new($X, $Y)
    $l.AutoSize = $true
    $l.Font = $FontLabel
    $l.ForeColor = $Theme.InkMuted
    $l.BackColor = $Theme.Surface
    return $l
}

# Owner-drawn button with hover/press states; WinForms flat buttons cannot do
# rounded corners or a real hover tint on their own.
function New-AppButton {
    param(
        [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
        [ValidateSet('Primary', 'Danger', 'Success', 'Ghost', 'Subtle')][string]$Kind = 'Primary',
        $Font = $null, [int]$Radius = 8
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = [System.Drawing.Point]::new($X, $Y)
    $b.Size = [System.Drawing.Size]::new($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Theme.Surface
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = if ($Font) { $Font } else { $FontUISemi }
    $b.TabStop = $true
    $b | Add-Member -NotePropertyName Kind -NotePropertyValue $Kind -Force
    $b | Add-Member -NotePropertyName Hover -NotePropertyValue $false -Force
    $b | Add-Member -NotePropertyName Pressed -NotePropertyValue $false -Force
    $b | Add-Member -NotePropertyName Radius -NotePropertyValue $Radius -Force
    Enable-DoubleBuffer $b
    $b.Add_MouseEnter({ $this.Hover = $true; $this.Invalidate() })
    $b.Add_MouseLeave({ $this.Hover = $false; $this.Pressed = $false; $this.Invalidate() })
    $b.Add_MouseDown({ $this.Pressed = $true; $this.Invalidate() })
    $b.Add_MouseUp({ $this.Pressed = $false; $this.Invalidate() })
    $b.Add_EnabledChanged({ $this.Invalidate() })
    $b.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $paintState = $g.Save()
        try {
            $paintScale = [single][Math]::Max(1.0, $script:UiScale)
            $g.PageUnit = [Drawing.GraphicsUnit]::Pixel
            $g.ScaleTransform($paintScale, $paintScale)
            $paintW = [single]($s.Width / $paintScale)
            $paintH = [single]($s.Height / $paintScale)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.Clear($s.Parent.BackColor)
        $rect = [System.Drawing.Rectangle]::new(0, 0, $paintW - 1, $paintH - 1)
        $path = New-RoundedPath $rect $s.Radius

        $fill = $null; $fore = $null; $border = $null
        switch ($s.Kind) {
            'Primary' { $fill = if (-not $s.Enabled) { C 191 205 228 } elseif ($s.Pressed) { C 24 64 175 } elseif ($s.Hover) { $Theme.AccentDark } else { $Theme.Accent }; $fore = $Theme.Surface }
            'Danger'  { $fill = if (-not $s.Enabled) { C 228 191 191 } elseif ($s.Pressed) { C 153 27 27 } elseif ($s.Hover) { $Theme.DangerDark } else { $Theme.Danger }; $fore = $Theme.Surface }
            'Success' { $fill = if (-not $s.Enabled) { C 191 220 208 } elseif ($s.Pressed) { C 4 108 78 } elseif ($s.Hover) { C 4 120 87 } else { $Theme.Success }; $fore = $Theme.Surface }
            'Ghost'   { $fill = if ($s.Pressed) { C 226 232 240 } elseif ($s.Hover) { $Theme.Inset } else { $Theme.Surface }; $fore = if (-not $s.Enabled) { $Theme.InkMuted } else { $Theme.InkSoft }; $border = $Theme.Border }
            'Subtle'  { $fill = if ($s.Pressed) { C 219 234 254 } elseif ($s.Hover) { $Theme.AccentSoft } else { $Theme.Inset }; $fore = if (-not $s.Enabled) { $Theme.InkMuted } else { $Theme.Accent }; $border = $Theme.Border }
        }
        $br = New-Object System.Drawing.SolidBrush($fill)
        $g.FillPath($br, $path); $br.Dispose()
        if ($border) { $pen = New-Object System.Drawing.Pen($border, 1); $g.DrawPath($pen, $path); $pen.Dispose() }
        $path.Dispose()

        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $tb = New-Object System.Drawing.SolidBrush($fore)
        $g.DrawString($s.Text, (Get-AppPaintFont $s.Font), $tb, [System.Drawing.RectangleF]::new(0, 0, $paintW, $paintH), $sf)
        $tb.Dispose(); $sf.Dispose()
    
        } finally { $g.Restore($paintState) }
    })
    return $b
}

function New-AppCombo {
    param([int]$X, [int]$Y, [int]$W)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = [System.Drawing.Point]::new($X, $Y)
    $c.Size = [System.Drawing.Size]::new($W, 26)
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle = 'Flat'
    $c.Font = $FontUI
    $c.BackColor = $Theme.Inset
    $c.ForeColor = $Theme.Ink
    return $c
}

function New-AppText {
    param([int]$X, [int]$Y, [int]$W, [string]$Value = '')
    # Never name a local here $t: PowerShell variable names are case-insensitive,
    # so $t and $Theme.<x> are easy to confuse and a careless rename once wrote
    # every one of these settings into the theme table instead of the control.
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = [System.Drawing.Point]::new($X, $Y)
    $box.Size = [System.Drawing.Size]::new($W, 26)
    $box.Font = $FontUI
    $box.BackColor = $Theme.Inset
    $box.ForeColor = $Theme.Ink
    $box.BorderStyle = 'FixedSingle'
    $box.Text = $Value
    return $box
}

function New-AppCheck {
    param([string]$Text, [int]$X, [int]$Y, [bool]$Checked = $true)
    $k = New-Object System.Windows.Forms.CheckBox
    $k.Text = $Text
    $k.Location = [System.Drawing.Point]::new($X, $Y)
    $k.AutoSize = $true
    $k.Checked = $Checked
    $k.Font = $FontUISemi
    $k.ForeColor = $Theme.Ink
    $k.BackColor = $Theme.Surface
    $k.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $k
}

# ------------------------------------------------------------------ VU meter --
# Gradient bar with segment ticks, peak-hold marker and a dB readout.
function New-VuMeter {
    param([int]$X, [int]$Y, [int]$W, [int]$H = 26)
    $m = New-Object System.Windows.Forms.PictureBox
    $m.Location = [System.Drawing.Point]::new($X, $Y)
    $m.Size = [System.Drawing.Size]::new($W, $H)
    $m.BackColor = $Theme.Surface
    $m | Add-Member -NotePropertyName Level -NotePropertyValue 0.0 -Force
    $m | Add-Member -NotePropertyName Peak -NotePropertyValue 0.0 -Force
    $m | Add-Member -NotePropertyName Hold -NotePropertyValue 0 -Force
    $m | Add-Member -NotePropertyName Muted -NotePropertyValue $false -Force
    Enable-DoubleBuffer $m
    $m.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $paintState = $g.Save()
        try {
            $paintScale = [single][Math]::Max(1.0, $script:UiScale)
            $g.PageUnit = [Drawing.GraphicsUnit]::Pixel
            $g.ScaleTransform($paintScale, $paintScale)
            $paintW = [single]($s.Width / $paintScale)
            $paintH = [single]($s.Height / $paintScale)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.Clear($s.BackColor)

        $readout = 52
        $barW = $paintW - $readout
        $barH = $paintH
        if ($barW -lt 20) { return }
        $track = [System.Drawing.Rectangle]::new(0, 0, $barW - 1, $barH - 1)
        $tpath = New-RoundedPath $track 6

        $tb = New-Object System.Drawing.SolidBrush((C 241 245 249))
        $g.FillPath($tb, $tpath); $tb.Dispose()

        $lvl = [Math]::Max(0.0, [Math]::Min(1.0, $s.Level))
        if (-not $s.Muted -and $lvl -gt 0.001) {
            $fillW = [int](($barW - 2) * $lvl)
            if ($fillW -gt 0) {
                $old = $g.Clip
                $g.SetClip($tpath)
                $g.IntersectClip([System.Drawing.Rectangle]::new(1, 1, $fillW, $barH - 2))
                $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    [System.Drawing.Rectangle]::new(1, 1, [Math]::Max(1, $barW - 2), $barH - 2),
                    (C 16 185 129), (C 239 68 68), 0.0)
                $blend = New-Object System.Drawing.Drawing2D.ColorBlend 4
                $blend.Colors = @((C 16 185 129), (C 34 197 94), (C 245 158 11), (C 239 68 68))
                $blend.Positions = @(0.0, 0.6, 0.85, 1.0)
                $grad.InterpolationColors = $blend
                $g.FillRectangle($grad, 1, 1, $barW - 2, $barH - 2)
                $grad.Dispose()
                $g.Clip = $old
            }
        }
        # segment ticks
        $tickPen = New-Object System.Drawing.Pen((CA 40 255 255 255), 1)
        for ($x = 6; $x -lt $barW - 2; $x += 6) { $g.DrawLine($tickPen, $x, 1, $x, $barH - 2) }
        $tickPen.Dispose()

        if (-not $s.Muted -and $s.Peak -gt 0.02) {
            $px = [int](($barW - 2) * [Math]::Min(1.0, $s.Peak))
            if ($px -gt 1 -and $px -lt $barW - 2) {
                $pp = New-Object System.Drawing.Pen($Theme.Ink, 2)
                $g.DrawLine($pp, $px, 2, $px, $barH - 3)
                $pp.Dispose()
            }
        }
        $bp = New-Object System.Drawing.Pen($Theme.Border, 1)
        $g.DrawPath($bp, $tpath); $bp.Dispose()
        $tpath.Dispose()

        $txt = if ($s.Muted) { 'OFF' }
               elseif ($lvl -le 0.0009) { '-inf' }
               else { '{0:0} dB' -f [Math]::Max(-60, 20 * [Math]::Log10($lvl)) }
        $col = if ($s.Muted) { $Theme.InkMuted } elseif ($lvl -gt 0.89) { $Theme.Danger } elseif ($lvl -gt 0.001) { $Theme.Ink } else { $Theme.InkMuted }
        $tbr = New-Object System.Drawing.SolidBrush($col)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Far'; $sf.LineAlignment = 'Center'
        $g.DrawString($txt, (Get-AppPaintFont $FontMeter), $tbr, [System.Drawing.RectangleF]::new($barW, 0, $readout - 2, $barH), $sf)
        $tbr.Dispose(); $sf.Dispose()
    
        } finally { $g.Restore($paintState) }
    })
    return $m
}

# Fast attack / slow release so speech reads naturally instead of flickering.
function Set-VuLevel {
    param($Meter, [double]$Value, [bool]$Muted = $false)
    if ($null -eq $Meter -or $Meter.IsDisposed) { return }
    $v = [Math]::Max(0.0, [Math]::Min(1.0, $Value))
    $Meter.Muted = $Muted
    if ($Muted) { $v = 0.0 }
    if ($v -ge $Meter.Level) { $Meter.Level = $v }
    else { $Meter.Level = $Meter.Level - (($Meter.Level - $v) * 0.35) }
    if ($v -gt $Meter.Peak) { $Meter.Peak = $v; $Meter.Hold = 14 }
    elseif ($Meter.Hold -gt 0) { $Meter.Hold = $Meter.Hold - 1 }
    else { $Meter.Peak = [Math]::Max(0.0, $Meter.Peak - 0.02) }
    $Meter.Invalidate()
}

# --------------------------------------------------------------- progress bar --
function New-ProgressBar {
    param([int]$X, [int]$Y, [int]$W, [int]$H = 10)
    $p = New-Object System.Windows.Forms.PictureBox
    $p.Location = [System.Drawing.Point]::new($X, $Y)
    $p.Size = [System.Drawing.Size]::new($W, $H)
    $p.BackColor = $Theme.Surface
    $p | Add-Member -NotePropertyName Value -NotePropertyValue 0.0 -Force
    $p | Add-Member -NotePropertyName Indeterminate -NotePropertyValue $false -Force
    $p | Add-Member -NotePropertyName Phase -NotePropertyValue 0.0 -Force
    Enable-DoubleBuffer $p
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $paintState = $g.Save()
        try {
            $paintScale = [single][Math]::Max(1.0, $script:UiScale)
            $g.PageUnit = [Drawing.GraphicsUnit]::Pixel
            $g.ScaleTransform($paintScale, $paintScale)
            $paintW = [single]($s.Width / $paintScale)
            $paintH = [single]($s.Height / $paintScale)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($s.BackColor)
        $rect = [System.Drawing.Rectangle]::new(0, 0, $paintW - 1, $paintH - 1)
        $path = New-RoundedPath $rect ([int]($paintH / 2))
        $tb = New-Object System.Drawing.SolidBrush((C 233 238 245))
        $g.FillPath($tb, $path); $tb.Dispose()
        $old = $g.Clip
        $g.SetClip($path)
        if ($s.Indeterminate) {
            $w = [int]($paintW * 0.28)
            $x = [int](($paintW + $w) * $s.Phase) - $w
            $gr = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                [System.Drawing.Rectangle]::new($x, 0, [Math]::Max(1, $w), $paintH),
                $Theme.AccentSoft, $Theme.Accent, 0.0)
            $g.FillRectangle($gr, $x, 0, $w, $paintH); $gr.Dispose()
        } else {
            $fw = [int](($paintW) * [Math]::Max(0.0, [Math]::Min(1.0, $s.Value)))
            if ($fw -gt 0) {
                $gr = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    [System.Drawing.Rectangle]::new(0, 0, [Math]::Max(1, $fw), $paintH),
                    $Theme.Accent, (C 96 165 250), 0.0)
                $g.FillRectangle($gr, 0, 0, $fw, $paintH); $gr.Dispose()
            }
        }
        $g.Clip = $old
        $path.Dispose()
    
        } finally { $g.Restore($paintState) }
    })
    return $p
}

# ----------------------------------------------------------------- status pill --
function New-StatusPill {
    param([int]$X, [int]$Y, [int]$W = 168, [int]$H = 28)
    $p = New-Object System.Windows.Forms.PictureBox
    $p.Location = [System.Drawing.Point]::new($X, $Y)
    $p.Size = [System.Drawing.Size]::new($W, $H)
    $p.BackColor = $Theme.Surface
    $p | Add-Member -NotePropertyName Caption -NotePropertyValue 'IDLE' -Force
    $p | Add-Member -NotePropertyName Tone -NotePropertyValue 'idle' -Force
    $p | Add-Member -NotePropertyName Pulse -NotePropertyValue 0.0 -Force
    Enable-DoubleBuffer $p
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $paintState = $g.Save()
        try {
            $paintScale = [single][Math]::Max(1.0, $script:UiScale)
            $g.PageUnit = [Drawing.GraphicsUnit]::Pixel
            $g.ScaleTransform($paintScale, $paintScale)
            $paintW = [single]($s.Width / $paintScale)
            $paintH = [single]($s.Height / $paintScale)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $g.Clear($s.BackColor)
        switch ($s.Tone) {
            'rec'   { $bg = C 254 242 242; $dot = $Theme.Danger;  $fg = C 153 27 27 }
            'error' { $bg = C 254 242 242; $dot = $Theme.Danger;  $fg = C 153 27 27 }
            'busy'  { $bg = $Theme.AmberSoft;  $dot = $Theme.Amber;   $fg = C 146 64 14 }
            'ok'    { $bg = $Theme.SuccessSoft;$dot = $Theme.Success; $fg = C 6 95 70 }
            default { $bg = C 241 245 249; $dot = C 148 163 184; $fg = $Theme.InkSoft }
        }
        $rect = [System.Drawing.Rectangle]::new(0, 0, $paintW - 1, $paintH - 1)
        $path = New-RoundedPath $rect ([int]($paintH / 2))
        $br = New-Object System.Drawing.SolidBrush($bg)
        $g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
        $r = 4
        $cy = [int]($paintH / 2)
        if ($s.Tone -eq 'rec') {
            $halo = 4 + (4 * $s.Pulse)
            $hb = New-Object System.Drawing.SolidBrush((CA ([int](70 * (1 - $s.Pulse))) 220 38 38))
            $g.FillEllipse($hb, 12 - $halo, $cy - $halo, $halo * 2, $halo * 2); $hb.Dispose()
        }
        $db = New-Object System.Drawing.SolidBrush($dot)
        $g.FillEllipse($db, 12 - $r, $cy - $r, $r * 2, $r * 2); $db.Dispose()
        $tb = New-Object System.Drawing.SolidBrush($fg)
        $sf = New-Object System.Drawing.StringFormat
        $sf.LineAlignment = 'Center'
        $g.DrawString($s.Caption, (Get-AppPaintFont $FontLabel), $tb, [System.Drawing.RectangleF]::new(24, 0, $paintW - 28, $paintH), $sf)
        $tb.Dispose(); $sf.Dispose()
    
        } finally { $g.Restore($paintState) }
    })
    return $p
}

function Set-Pill {
    param($Pill, [string]$Caption, [ValidateSet('idle', 'rec', 'busy', 'ok', 'error')][string]$Tone = 'idle')
    if ($null -eq $Pill -or $Pill.IsDisposed) { return }
    $Pill.Caption = $Caption; $Pill.Tone = $Tone; $Pill.Invalidate()
}

# ==============================================================================
#  TOOL / MODEL DISCOVERY
# ==============================================================================

# Windows CreateProcess quoting. UseShellExecute is false so no shell is
# involved; the previous version stripped characters like & and | from the
# user's vocabulary, which corrupted legitimate text without adding safety.
function ConvertTo-CmdArg {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * ($slashes * 2 + 1)); [void]$sb.Append('"'); $slashes = 0; continue }
        if ($slashes -gt 0) { [void]$sb.Append('\' * $slashes); $slashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) { [void]$sb.Append('\' * ($slashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-ModelCatalog {
    $models = @()
    try {
        $files = Get-ChildItem -LiteralPath $WhisperDir -Filter 'ggml-*.bin' -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notmatch 'silero|vad' }
        foreach ($f in $files) {
            $base = $f.BaseName -replace '^ggml-', ''
            $isEn = $base -match '\.en$'
            $size = switch -Regex ($base) {
                '^tiny'   { 0 } '^base' { 1 } '^small' { 2 } '^medium' { 3 } '^large' { 4 } default { 5 }
            }
            $pretty = ($base -replace '\.en$', '')
            $pretty = $pretty.Substring(0, 1).ToUpper() + $pretty.Substring(1)
            $label = if ($isEn) { "$pretty (English only)" } else { "$pretty (Multilingual)" }
            $mb = [Math]::Round($f.Length / 1MB)
            $models += [pscustomobject]@{
                File = $f.Name; Path = $f.FullName; IsEnglishOnly = $isEn
                Rank = $size; Display = "$label  -  $mb MB"
            }
        }
    } catch { }
    return @($models | Sort-Object Rank, File)
}

function Resolve-Ffmpeg {
    $candidates = @()
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += (Join-Path $WhisperDir 'ffmpeg.exe')
    $candidates += "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe"
    $candidates += "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe"
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    try {
        $pkg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($pkg) { return $pkg.FullName }
    } catch { }
    return $null
}

$script:FfmpegPath = Resolve-Ffmpeg
$script:ModelCatalog = @(Get-ModelCatalog)

# Starts a child through the C# runner. Nothing here attaches a PowerShell
# scriptblock to a Process event - see the ProcRunner docs for why that is fatal.
function Start-Child {
    param([string]$FilePath, [string]$Arguments, [switch]$Redirect)
    $runner = New-Object AudioEngine.ProcRunner
    if (-not $runner.Start($FilePath, $Arguments, $WhisperDir, [bool]$Redirect)) {
        throw "Could not start $([System.IO.Path]::GetFileName($FilePath)): $($runner.Error)"
    }
    [void]$script:childProcs.Add($runner)
    return $runner
}


# ==============================================================================
#  SHELL
# ==============================================================================
$M      = 24
$FormW  = 1060
$FormH  = 980
$CardW  = $FormW - ($M * 2) - 16
$HeadH  = 78
$TabH   = 60
$TopY   = $HeadH + $TabH

$form = New-Object System.Windows.Forms.Form
$form.SuspendLayout()
$form.Text = 'AI Transcriber Studio'
$brandIcon = Join-Path $WhisperDir 'AITranscriber.exe'
if (Test-Path -LiteralPath $brandIcon) {
    [void][Reflection.Assembly]::LoadFrom($brandIcon)
    [AITranscriberInstaller.DesktopIdentity]::Apply()
    $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($brandIcon)
}
$form.ClientSize = [System.Drawing.Size]::new($FormW, $FormH)
$form.MinimumSize = [System.Drawing.Size]::new(640, 480)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Theme.Page
$form.Font = $FontUI
$form.AutoScaleDimensions = [System.Drawing.SizeF]::new(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.KeyPreview = $true
Enable-DoubleBuffer $form

# ------------------------------------------------------------------- header --
$header = New-Object System.Windows.Forms.Panel
$header.Location = [System.Drawing.Point]::new(0, 0)
$header.Size = [System.Drawing.Size]::new($FormW, $HeadH)
$header.Anchor = 'Top,Left,Right'
$header.BackColor = $Theme.Navy
Enable-DoubleBuffer $header
$header.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
        $paintState = $g.Save()
        try {
            $paintScale = [single][Math]::Max(1.0, $script:UiScale)
            $g.PageUnit = [Drawing.GraphicsUnit]::Pixel
            $g.ScaleTransform($paintScale, $paintScale)
            $paintW = [single]($s.Width / $paintScale)
            $paintH = [single]($s.Height / $paintScale)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $gr = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        [System.Drawing.Rectangle]::new(0, 0, [Math]::Max(1, $paintW), $paintH),
        (C 16 24 43), (C 30 41 66), 0.0)
    $g.FillRectangle($gr, 0, 0, $paintW, $paintH); $gr.Dispose()

    # mark
    $mr = [System.Drawing.Rectangle]::new(26, 20, 38, 38)
    $mp = New-RoundedPath $mr 11
    $mg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($mr, (C 59 130 246), (C 37 99 235), 45.0)
    $g.FillPath($mg, $mp); $mg.Dispose(); $mp.Dispose()
    # waveform glyph
    $pen = New-Object System.Drawing.Pen($Theme.Surface, 2)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $bars = @(8, 15, 20, 12, 6)
    for ($i = 0; $i -lt $bars.Count; $i++) {
        $x = 34 + ($i * 5)
        $h = $bars[$i]
        $g.DrawLine($pen, $x, 39 - ($h / 2), $x, 39 + ($h / 2))
    }
    $pen.Dispose()

    $tb = New-Object System.Drawing.SolidBrush($Theme.Surface)
    $g.DrawString('AI Transcriber Studio', (Get-AppPaintFont $FontBrand), $tb, 76, 15)
    $tb.Dispose()
    $sb = New-Object System.Drawing.SolidBrush((C 138 152 176))
    $g.DrawString('Live Capture and Offline Whisper Transcription', (Get-AppPaintFont $FontBrandSub), $sb, 79, 44)
    $sb.Dispose()
    $lp = New-Object System.Drawing.Pen((C 38 50 76), 1)
    $g.DrawLine($lp, 0, $paintH - 1, $paintW, $paintH - 1)
    $lp.Dispose()

        } finally { $g.Restore($paintState) }
    })
$form.Controls.Add($header)

$lblEngine = New-Object System.Windows.Forms.Label
$lblEngine.AutoSize = $false
$lblEngine.Size = [System.Drawing.Size]::new(430, 34)
$lblEngine.Location = [System.Drawing.Point]::new($FormW - 454, 22)
$lblEngine.Anchor = 'Top,Right'
$lblEngine.TextAlign = 'MiddleRight'
$lblEngine.Font = $FontBrandSub
$lblEngine.ForeColor = C 138 152 176
$lblEngine.BackColor = [System.Drawing.Color]::Transparent
$header.Controls.Add($lblEngine)

# --------------------------------------------------------------- tab strip --
$tabStrip = New-Object System.Windows.Forms.Panel
$tabStrip.Location = [System.Drawing.Point]::new(0, $HeadH)
$tabStrip.Size = [System.Drawing.Size]::new($FormW, $TabH)
$tabStrip.Anchor = 'Top,Left,Right'
$tabStrip.BackColor = $Theme.Page
$form.Controls.Add($tabStrip)

$btnTabLive = New-AppButton -Text 'Live Recorder' -X $M -Y 14 -W 190 -H 34 -Kind 'Primary' -Radius 9
$btnTabFile = New-AppButton -Text 'File Transcriber' -X ($M + 198) -Y 14 -W 190 -H 34 -Kind 'Ghost' -Radius 9
$tabStrip.Controls.AddRange(@($btnTabLive, $btnTabFile))
$btnManageModels = New-AppButton -Text 'Download / Manage Models' -X ($FormW - $M - 230) -Y 14 -W 230 -H 34 -Kind 'Subtle' -Radius 9
$btnManageModels.Anchor = 'Top,Right'
$tabStrip.Controls.Add($btnManageModels)

# ------------------------------------------------------------------ panels --
$ContentH = $FormH - $TopY - $M
$contentViewport = New-Object System.Windows.Forms.Panel
$contentViewport.Location = [Drawing.Point]::new(0, $TopY)
$contentViewport.Size = [Drawing.Size]::new($FormW, $FormH - $TopY)
$contentViewport.Anchor = 'Top,Left,Right,Bottom'
$contentViewport.AutoScroll = $true
$contentViewport.BackColor = $Theme.Page
$form.Controls.Add($contentViewport)
$pnlLive = New-Object System.Windows.Forms.Panel
$pnlLive.Location = [System.Drawing.Point]::new($M, 0)
$pnlLive.Size = [System.Drawing.Size]::new($FormW - ($M * 2), $ContentH)
$pnlLive.Anchor = 'Top,Left'
$pnlLive.BackColor = $Theme.Page
$contentViewport.Controls.Add($pnlLive)

$pnlFile = New-Object System.Windows.Forms.Panel
$pnlFile.Location = [System.Drawing.Point]::new($M, 0)
$pnlFile.Size = [System.Drawing.Size]::new($FormW - ($M * 2), $ContentH)
$pnlFile.Anchor = 'Top,Left'
$pnlFile.BackColor = $Theme.Page
$pnlFile.Visible = $false
$contentViewport.Controls.Add($pnlFile)

# ==============================================================================
#  TAB 1 - LIVE RECORDER
# ==============================================================================
$cardSrc = New-Card -X 0 -Y 0 -W $CardW -H 272 -Title 'Audio Sources'
$cardSrc.Anchor = 'Top,Left,Right'
$pnlLive.Controls.Add($cardSrc)

$chkSys = New-AppCheck -Text 'System / Application Audio  (Loopback - Your speakers keep playing.)' -X 20 -Y 58 -Checked ([bool]$script:Settings.UseSystem)
$cardSrc.Controls.Add($chkSys)

$cmbOutputDev = New-AppCombo -X 20 -Y 84 -W ($CardW - 175)
$cmbOutputDev.Anchor = 'Top,Left,Right'
$cardSrc.Controls.Add($cmbOutputDev)

$btnRefreshDev = New-AppButton -Text 'Refresh' -X ($CardW - 145) -Y 83 -W 120 -H 28 -Kind 'Subtle'
$btnRefreshDev.Anchor = 'Top,Right'
$cardSrc.Controls.Add($btnRefreshDev)

$vuSys = New-VuMeter -X 20 -Y 120 -W ($CardW - 45)
$vuSys.Anchor = 'Top,Left,Right'
$cardSrc.Controls.Add($vuSys)

$chkMic = New-AppCheck -Text 'Microphone  (Your Voice)' -X 20 -Y 160 -Checked ([bool]$script:Settings.UseMic)
$cardSrc.Controls.Add($chkMic)

$cmbInputDev = New-AppCombo -X 20 -Y 186 -W ($CardW - 45)
$cmbInputDev.Anchor = 'Top,Left,Right'
$cardSrc.Controls.Add($cmbInputDev)

$vuMic = New-VuMeter -X 20 -Y 222 -W ($CardW - 45)
$vuMic.Anchor = 'Top,Left,Right'
$cardSrc.Controls.Add($vuMic)

$lblSrcHint = New-Object System.Windows.Forms.Label
$lblSrcHint.Location = [System.Drawing.Point]::new(20, 250)
$lblSrcHint.Size = [System.Drawing.Size]::new($CardW - 45, 16)
$lblSrcHint.Anchor = 'Top,Left,Right'
$lblSrcHint.Font = $FontBrandSub
$lblSrcHint.ForeColor = $Theme.InkMuted
$lblSrcHint.BackColor = $Theme.Surface
$cardSrc.Controls.Add($lblSrcHint)

# ------------------------------------------------------------- recognition --
$cardRec = New-Card -X 0 -Y 284 -W $CardW -H 224 -Title 'Recognition'
$cardRec.Anchor = 'Top,Left,Right'
$pnlLive.Controls.Add($cardRec)

$colW = [int](($CardW - 65) / 3)
$cardRec.Controls.Add((New-FieldLabel 'Realtime model' 20 58))
$cmbLiveModel = New-AppCombo -X 20 -Y 76 -W $colW
$cardRec.Controls.Add($cmbLiveModel)

$cardRec.Controls.Add((New-FieldLabel 'Final pass model' (20 + $colW + 12) 58))
$cmbFinalModel = New-AppCombo -X (20 + $colW + 12) -Y 76 -W $colW
$cardRec.Controls.Add($cmbFinalModel)

$cardRec.Controls.Add((New-FieldLabel 'Language' (20 + ($colW + 12) * 2) 58))
$cmbLang = New-AppCombo -X (20 + ($colW + 12) * 2) -Y 76 -W $colW
[void]$cmbLang.Items.AddRange(@('Auto detect', 'English', 'Filipino / Tagalog', 'Spanish', 'Japanese', 'Chinese', 'Korean'))
$cmbLang.SelectedIndex = 0
$cardRec.Controls.Add($cmbLang)

$cardRec.Controls.Add((New-FieldLabel 'Save recordings to' 20 112))
$txtLiveDest = New-AppText -X 20 -Y 130 -W ($CardW - 195) -Value ([string]$script:Settings.SaveFolder)
$txtLiveDest.Anchor = 'Top,Left,Right'
$cardRec.Controls.Add($txtLiveDest)
$btnLiveBrowse = New-AppButton -Text 'Choose Folder' -X ($CardW - 165) -Y 129 -W 140 -H 28 -Kind 'Subtle'
$btnLiveBrowse.Anchor = 'Top,Right'
$cardRec.Controls.Add($btnLiveBrowse)

$cardRec.Controls.Add((New-FieldLabel 'Vocabulary - names, jargon, acronyms (comma separated)' 20 166))
$txtLiveKeywords = New-AppText -X 20 -Y 184 -W ($CardW - 45) -Value ([string]$script:Settings.Vocabulary)
$txtLiveKeywords.Anchor = 'Top,Left,Right'
$cardRec.Controls.Add($txtLiveKeywords)

# ---------------------------------------------------------------- transcript --
$cardFeed = New-Card -X 0 -Y 520 -W $CardW -H ($ContentH - 520) -Title ''
$cardFeed.Anchor = 'Top,Left,Right,Bottom'
$pnlLive.Controls.Add($cardFeed)

$pillLive = New-StatusPill -X 20 -Y 18 -W 180 -H 28
$cardFeed.Controls.Add($pillLive)

$lblStreamInfo = New-Object System.Windows.Forms.Label
$lblStreamInfo.Location = [System.Drawing.Point]::new(212, 24)
$lblStreamInfo.Size = [System.Drawing.Size]::new($CardW - 430, 18)
$lblStreamInfo.Anchor = 'Top,Left,Right'
$lblStreamInfo.Font = $FontBrandSub
$lblStreamInfo.ForeColor = $Theme.InkMuted
$lblStreamInfo.BackColor = $Theme.Surface
$cardFeed.Controls.Add($lblStreamInfo)

$lblDuration = New-Object System.Windows.Forms.Label
$lblDuration.Location = [System.Drawing.Point]::new($CardW - 205, 18)
$lblDuration.Size = [System.Drawing.Size]::new(180, 28)
$lblDuration.Anchor = 'Top,Right'
$lblDuration.TextAlign = 'MiddleRight'
$lblDuration.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$lblDuration.ForeColor = $Theme.Ink
$lblDuration.BackColor = $Theme.Surface
$lblDuration.Text = '00:00:00'
$cardFeed.Controls.Add($lblDuration)

$txtLiveFeed = New-Object System.Windows.Forms.TextBox
$txtLiveFeed.Location = [System.Drawing.Point]::new(20, 56)
$txtLiveFeed.Size = [System.Drawing.Size]::new($CardW - 45, $ContentH - 520 - 134)
$txtLiveFeed.Anchor = 'Top,Left,Right,Bottom'
$txtLiveFeed.Multiline = $true
$txtLiveFeed.ScrollBars = 'Vertical'
$txtLiveFeed.ReadOnly = $true
$txtLiveFeed.BackColor = $Theme.Inset
$txtLiveFeed.ForeColor = $Theme.Ink
$txtLiveFeed.Font = $FontMono
$txtLiveFeed.BorderStyle = 'FixedSingle'
$cardFeed.Controls.Add($txtLiveFeed)

$btnRecord = New-AppButton -Text 'Start Recording' -X 20 -Y ($ContentH - 520 - 68) -W ($CardW - 45) -H 46 -Kind 'Danger' -Font $FontBtn -Radius 10
$btnRecord.Anchor = 'Left,Right,Bottom'
$cardFeed.Controls.Add($btnRecord)

# ==============================================================================
#  TAB 2 - FILE TRANSCRIBER
# ==============================================================================
$cardFileSrc = New-Card -X 0 -Y 0 -W $CardW -H 190 -Title 'Source'
$cardFileSrc.Anchor = 'Top,Left,Right'
$pnlFile.Controls.Add($cardFileSrc)

$cardFileSrc.Controls.Add((New-FieldLabel 'Audio or video file  -  you can also drag a file onto this window' 20 58))
$txtInput = New-AppText -X 20 -Y 76 -W ($CardW - 195)
$txtInput.Anchor = 'Top,Left,Right'
$cardFileSrc.Controls.Add($txtInput)
$btnInput = New-AppButton -Text 'Browse' -X ($CardW - 165) -Y 75 -W 140 -H 28 -Kind 'Subtle'
$btnInput.Anchor = 'Top,Right'
$cardFileSrc.Controls.Add($btnInput)

$cardFileSrc.Controls.Add((New-FieldLabel 'Destination folder' 20 118))
$txtOutput = New-AppText -X 20 -Y 136 -W ($CardW - 195)
$txtOutput.Anchor = 'Top,Left,Right'
$cardFileSrc.Controls.Add($txtOutput)
$btnOutput = New-AppButton -Text 'Choose Folder' -X ($CardW - 165) -Y 135 -W 140 -H 28 -Kind 'Subtle'
$btnOutput.Anchor = 'Top,Right'
$cardFileSrc.Controls.Add($btnOutput)

$cardFileAi = New-Card -X 0 -Y 202 -W $CardW -H 170 -Title 'Recognition'
$cardFileAi.Anchor = 'Top,Left,Right'
$pnlFile.Controls.Add($cardFileAi)

$half = [int](($CardW - 57) / 2)
$cardFileAi.Controls.Add((New-FieldLabel 'Model' 20 58))
$cmbModel = New-AppCombo -X 20 -Y 76 -W $half
$cardFileAi.Controls.Add($cmbModel)

$cardFileAi.Controls.Add((New-FieldLabel 'Language' (20 + $half + 12) 58))
$cmbFileLang = New-AppCombo -X (20 + $half + 12) -Y 76 -W $half
[void]$cmbFileLang.Items.AddRange(@('Auto Detect', 'English', 'Filipino / Tagalog', 'Spanish', 'Japanese', 'Chinese', 'Korean'))
$cmbFileLang.SelectedIndex = 0
$cardFileAi.Controls.Add($cmbFileLang)

$cardFileAi.Controls.Add((New-FieldLabel 'Vocabulary - names, jargon, acronyms (comma separated)' 20 112))
$txtContext = New-AppText -X 20 -Y 130 -W ($CardW - 45) -Value ([string]$script:Settings.FileVocabulary)
$txtContext.Anchor = 'Top,Left,Right'
$cardFileAi.Controls.Add($txtContext)

$cardFileRun = New-Card -X 0 -Y 384 -W $CardW -H ($ContentH - 384) -Title ''
$cardFileRun.Anchor = 'Top,Left,Right,Bottom'
$pnlFile.Controls.Add($cardFileRun)

$pillFile = New-StatusPill -X 20 -Y 18 -W 180 -H 28
$cardFileRun.Controls.Add($pillFile)

$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Location = [System.Drawing.Point]::new($CardW - 305, 22)
$lblProgress.Size = [System.Drawing.Size]::new(280, 20)
$lblProgress.Anchor = 'Top,Right'
$lblProgress.TextAlign = 'MiddleRight'
$lblProgress.Font = $FontUISemi
$lblProgress.ForeColor = $Theme.InkSoft
$lblProgress.BackColor = $Theme.Surface
$cardFileRun.Controls.Add($lblProgress)

$progressBar = New-ProgressBar -X 20 -Y 54 -W ($CardW - 45) -H 8
$progressBar.Anchor = 'Top,Left,Right'
$cardFileRun.Controls.Add($progressBar)

$txtStatus = New-Object System.Windows.Forms.TextBox
$txtStatus.Location = [System.Drawing.Point]::new(20, 76)
$txtStatus.Size = [System.Drawing.Size]::new($CardW - 45, $ContentH - 384 - 154)
$txtStatus.Anchor = 'Top,Left,Right,Bottom'
$txtStatus.Multiline = $true
$txtStatus.ScrollBars = 'Vertical'
$txtStatus.ReadOnly = $true
$txtStatus.BackColor = $Theme.Inset
$txtStatus.ForeColor = $Theme.Ink
$txtStatus.Font = $FontMono
$txtStatus.BorderStyle = 'FixedSingle'
$cardFileRun.Controls.Add($txtStatus)

$btnStart = New-AppButton -Text 'Start Transcription' -X 20 -Y ($ContentH - 384 - 68) -W ($CardW - 195) -H 46 -Kind 'Primary' -Font $FontBtn -Radius 10
$btnStart.Anchor = 'Left,Right,Bottom'
$cardFileRun.Controls.Add($btnStart)

$btnCancel = New-AppButton -Text 'Cancel' -X ($CardW - 165) -Y ($ContentH - 384 - 68) -W 140 -H 46 -Kind 'Ghost' -Font $FontBtn -Radius 10
$btnCancel.Anchor = 'Right,Bottom'
$btnCancel.Enabled = $false
$cardFileRun.Controls.Add($btnCancel)

function Update-AppLayout {
    param([Drawing.Rectangle]$WorkingArea = [Windows.Forms.Screen]::FromControl($form).WorkingArea, [switch]$ConstrainWindow)
    if ($script:layoutUpdating -or $form.IsDisposed) { return }
    $script:layoutUpdating = $true
    try {
        $scale = [Math]::Max(1.0, $form.CurrentAutoScaleDimensions.Width / 96.0)
        $script:UiScale = $scale
        if ($ConstrainWindow) {
            $form.MinimumSize = [Drawing.Size]::new([Math]::Min(640,$WorkingArea.Width),[Math]::Min(480,$WorkingArea.Height))
            $w = [Math]::Min($form.Width,$WorkingArea.Width); $h = [Math]::Min($form.Height,$WorkingArea.Height)
            $x = [Math]::Max($WorkingArea.Left,[Math]::Min($form.Left,$WorkingArea.Right-$w))
            $y = [Math]::Max($WorkingArea.Top,[Math]::Min($form.Top,$WorkingArea.Bottom-$h))
            $form.Bounds = [Drawing.Rectangle]::new($x,$y,$w,$h)
        }
        $margin = [int][Math]::Round($M*$scale)
        $headHeight = [int][Math]::Round($HeadH*$scale)
        $header.Bounds = [Drawing.Rectangle]::new(0,0,$form.ClientSize.Width,$headHeight)
        $lblEngine.Visible = $form.ClientSize.Width -ge 900*$scale
        $lblEngine.Bounds = [Drawing.Rectangle]::new([int]($form.ClientSize.Width-454*$scale),[int](22*$scale),[int](430*$scale),[int](34*$scale))
        $tabStrip.AutoScroll = $true
        $btnManageModels.Anchor = 'Top,Left'
        $tabStrip.AutoScrollPosition = [Drawing.Point]::Empty
        $btnTabLive.Bounds = [Drawing.Rectangle]::new($margin,[int](14*$scale),[int](190*$scale),[int](34*$scale))
        $btnTabFile.Bounds = [Drawing.Rectangle]::new([int](($M+198)*$scale),[int](14*$scale),[int](190*$scale),[int](34*$scale))
        $managerX = [int][Math]::Max($btnTabFile.Right+16*$scale,$form.ClientSize.Width-$margin-230*$scale)
        $btnManageModels.Bounds = [Drawing.Rectangle]::new($managerX,[int](14*$scale),[int](230*$scale),[int](34*$scale))
        $tabWidth = $btnManageModels.Right+$margin
        $tabHeight = [int]($TabH*$scale)
        if ($tabWidth -gt $form.ClientSize.Width) { $tabHeight += [Windows.Forms.SystemInformation]::HorizontalScrollBarHeight }
        $tabStrip.Bounds = [Drawing.Rectangle]::new(0,$headHeight,$form.ClientSize.Width,$tabHeight)
        $tabStrip.AutoScrollMinSize = [Drawing.Size]::new($tabWidth,0)
        $top = $headHeight+$tabHeight
        $contentViewport.Bounds = [Drawing.Rectangle]::new(0,$top,$form.ClientSize.Width,[Math]::Max(1,$form.ClientSize.Height-$top))
        $scroll = $contentViewport.AutoScrollPosition
        for($pass=0;$pass -lt 2;$pass++) {
            $width=[int][Math]::Max(($FormW-2*$M)*$scale,$contentViewport.ClientSize.Width-2*$margin)
            $height=[int][Math]::Max($ContentH*$scale,$contentViewport.ClientSize.Height-$margin)
            foreach($body in @($pnlLive,$pnlFile)) { $body.Bounds=[Drawing.Rectangle]::new($margin+$scroll.X,$scroll.Y,$width,$height) }
            $contentViewport.AutoScrollMinSize=[Drawing.Size]::new($width+2*$margin,$height+$margin)
            $contentViewport.PerformLayout()
        }
        $contentViewport.AutoScrollPosition=[Drawing.Point]::new([Math]::Abs($scroll.X),[Math]::Abs($scroll.Y))
        $form.Invalidate($true)
    } finally { $script:layoutUpdating=$false }
}


# ==============================================================================
#  STATE
# ==============================================================================
$script:liveStart      = [DateTime]::MinValue
$script:masterWav      = ''
$script:chunkWav       = ''
$script:tempDir        = Join-Path ([IO.Path]::GetTempPath()) ('AITranscriber-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:tempDir)
$script:ownedTempDir   = $script:tempDir
$script:chunkBusy      = $false
$script:chunkBase      = ''
$script:chunkRunner    = $null
$script:monitorDev     = $null
$script:cancelRequested = $false
$script:fileBusy       = $false
$script:recordingSessionActive = $false
$script:finalizing = $false
$script:childProcs     = New-Object System.Collections.ArrayList
$script:pulse          = 0.0

$script:Threads = 4
try {
    $cores = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property NumberOfCores -Sum).Sum
    if ($cores -gt 0) { $script:Threads = [Math]::Max(1, [Math]::Min(12, $cores - 1)) }
    else { $script:Threads = [Math]::Max(1, [int]([Environment]::ProcessorCount / 2)) }
} catch { $script:Threads = [Math]::Max(1, [int]([Environment]::ProcessorCount / 2)) }

# ==============================================================================
#  SMALL HELPERS
# ==============================================================================
function Add-Line {
    param($Box, [string]$Text)
    if ($null -eq $Box -or $Box.IsDisposed) { return }
    $Box.AppendText($Text + "`r`n")
    if($Box.TextLength -gt 262144){$Box.Select(0,$Box.TextLength-196608);$Box.SelectedText=''}
    $Box.SelectionStart = $Box.TextLength
    $Box.ScrollToCaret()
}

function Get-LangCode($Combo) {
    switch ("$($Combo.SelectedItem)") {
        'English'            { 'en' }
        'Filipino / Tagalog' { 'tl' }
        'Spanish'            { 'es' }
        'Japanese'           { 'ja' }
        'Chinese'            { 'zh' }
        'Korean'             { 'ko' }
        default              { 'auto' }
    }
}

function Get-SelectedModel($Combo) {
    if ($null -eq $Combo -or $Combo.SelectedIndex -lt 0) { return $null }
    $catalog = @($script:ModelCatalog)
    if ($Combo.SelectedIndex -ge $catalog.Count) { return $null }
    return $catalog[$Combo.SelectedIndex]
}

# English-only models cannot auto-detect; asking them to would degrade output.
function Resolve-Language {
    param($Model, [string]$Requested)
    if ($null -ne $Model -and $Model.IsEnglishOnly) { return 'en' }
    return $Requested
}

function Build-WhisperArgs {
    param(
        [string]$ModelPath, [string]$AudioPath, [string]$OutBase, [string]$Lang,
        [string]$Prompt, [int]$Threads, [switch]$Realtime, [switch]$ShowProgress
    )
    $a = New-Object System.Collections.ArrayList
    [void]$a.Add('-m');  [void]$a.Add((ConvertTo-CmdArg $ModelPath))
    [void]$a.Add('-f');  [void]$a.Add((ConvertTo-CmdArg $AudioPath))
    [void]$a.Add('-of'); [void]$a.Add((ConvertTo-CmdArg $OutBase))
    [void]$a.Add('-t');  [void]$a.Add($Threads)
    [void]$a.Add('-l');  [void]$a.Add($Lang)
    if ($Realtime) {
        # Greedy decode keeps up with the 4 s chunk cadence.
        [void]$a.Add('-bo'); [void]$a.Add('1')
        [void]$a.Add('-bs'); [void]$a.Add('1')
        [void]$a.Add('-nt')
        [void]$a.Add('-otxt')
    } else {
        [void]$a.Add('-bo'); [void]$a.Add('5')
        [void]$a.Add('-bs'); [void]$a.Add('5')
        [void]$a.Add('-et'); [void]$a.Add('2.4')
        [void]$a.Add('-lpt'); [void]$a.Add('-1.0')
        # -ojf, not -oj: only the full form emits per-token confidence, which
        # the vocabulary correction and uncertainty marking depend on.
        [void]$a.Add('-ojf')
    }
    if ($ShowProgress) { [void]$a.Add('-pp') }
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        $clean = ($Prompt -replace '[\r\n]+', ' ').Trim()
        if ($clean.Length -gt 800) { $clean = $clean.Substring(0, 800) }
        [void]$a.Add('--prompt'); [void]$a.Add((ConvertTo-CmdArg $clean))
        [void]$a.Add('--carry-initial-prompt')
    }
    return ($a -join ' ')
}

function Stop-Children {
    foreach ($p in @($script:childProcs)) {
        try { if ($null -ne $p) { $p.Kill(); $p.Dispose() } } catch { }
    }
    $script:childProcs.Clear()
}

# Drop finished runners so a long session does not accumulate handles.
function Clear-FinishedChildren {
    $live = New-Object System.Collections.ArrayList
    foreach ($p in @($script:childProcs)) {
        try {
            if ($null -ne $p -and -not $p.HasExited) { [void]$live.Add($p) }
            elseif ($null -ne $p) { $p.Dispose() }
        } catch { }
    }
    $script:childProcs = $live
}

# Pumps the UI while a child process runs so the window never greys out.
#
# DoEvents re-enters the message loop, so anything it dispatches - a timer tick,
# a button click - can call back into this function and start another pump on
# top of this one. Nested far enough that overflows the stack and Windows kills
# the process with no error at all. UiBusy marks a pump as active so handlers
# that would recurse bail out instead.
$script:uiBusy = $false

function Wait-ForProcess {
    param($Runner, [switch]$Cancellable, [scriptblock]$OnOutput, [double]$TimeoutSeconds = 0)
    if ($null -eq $Runner) { throw 'No child process was started.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $errorTail = New-Object Text.StringBuilder
    $outer = $script:uiBusy
    $script:uiBusy = $true
    try {
        while ($null -ne $Runner -and -not $Runner.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($Cancellable -and $script:cancelRequested) { $Runner.Kill(); $Runner.WaitForExit(2000); return $false }
            if ($TimeoutSeconds -gt 0 -and $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { $Runner.Kill(); $Runner.WaitForExit(2000); throw 'The child process timed out and was stopped.' }
            $outText=$Runner.DrainOutput();$errText=$Runner.DrainError()
            [void]$errorTail.Append($errText)
            if($errorTail.Length -gt 32768){[void]$errorTail.Remove(0,$errorTail.Length-32768)}
            if ($OnOutput) { & $OnOutput $outText $errText }
            Start-Sleep -Milliseconds 35
        }
        # one last sweep so trailing output is not lost
        $outText=$Runner.DrainOutput();$errText=$Runner.DrainError();[void]$errorTail.Append($errText)
        if($errorTail.Length -gt 32768){[void]$errorTail.Remove(0,$errorTail.Length-32768)}
        if ($OnOutput) { & $OnOutput $outText $errText }
        [System.Windows.Forms.Application]::DoEvents()
        if ($Cancellable -and $script:cancelRequested) { return $false }
        if ($Runner.ExitCode -ne 0) { throw "Child process failed (exit $($Runner.ExitCode)). $($errorTail.ToString())" }
        return $true
    }
    finally { $script:uiBusy = $outer }
}

# ==============================================================================
#  TRANSCRIPT FORMATTING
# ==============================================================================
function Format-Transcript {
    param([string]$JsonPath, [string[]]$Vocabulary, [string[]]$Header)

    $json = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $json -or -not ($json.PSObject.Properties.Name -contains 'transcription') -or $json.transcription -isnot [System.Collections.IList]) { throw 'Whisper JSON has an invalid transcription schema.' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lowConf = 0; $corrected = 0; $totalTokens = 0; [double]$confSum = 0

    if ($null -ne $json.transcription) {
        foreach ($seg in $json.transcription) {
            $from = "$($seg.timestamps.from)"
            if ($from -match '(\d{2}:\d{2}:\d{2})') { $from = $matches[1] }
            $text = ''

            if ($null -ne $seg.tokens) {
                foreach ($tok in $seg.tokens) {
                    $w = [string]$tok.text
                    # Control tokens come in two shapes: [_BEG_] / [_TT_123] and
                    # <|endoftext|> / <|en|>. Neither is speech.
                    if ($w -match '^\s*\[_' -or $w -match '^\s*<\|') { continue }
                    $p = 1.0
                    try { $p = [double]$tok.p } catch { }
                    $totalTokens++; $confSum += $p

                    $trimmed = $w.Trim()
                    if ($p -lt 0.85 -and $p -gt 0.30 -and $Vocabulary.Count -gt 0 -and $trimmed.Length -gt 3) {
                        foreach ($v in $Vocabulary) {
                            if ([string]::IsNullOrWhiteSpace($v)) { continue }
                            if ([AudioEngine.CoreAudio]::Levenshtein($trimmed.ToLower(), $v.ToLower()) -le 2) {
                                $w = $w.Replace($trimmed, $v); $corrected++; break
                            }
                        }
                    }
                    # Only flag whole words. Whisper splits words into sub-word
                    # pieces ("Haw"+"aii"+"an") and assigns low probability to
                    # punctuation, so marking any low-probability token would
                    # both litter the page and cut words in half. A leading
                    # space is what identifies the start of a new word.
                    if ($p -lt 0.30 -and $w -match '^\s' -and $trimmed -match '^[\p{L}]{3,}$') {
                        $text += " [?$trimmed]"; $lowConf++
                    }
                    else { $text += $w }
                }
            } else {
                $text = [string]$seg.text
            }
            $segText = $text.Trim()
            if ($segText.Length -gt 0) { $lines.Add("[$from]  $segText") }
        }
    }
    $avg = if ($totalTokens -gt 0) { [Math]::Round($confSum / $totalTokens, 3) } else { 0 }
    return [pscustomobject]@{
        Lines = $lines; LowConfidence = $lowConf; Corrected = $corrected
        AvgConfidence = $avg; TokenCount = $totalTokens
        Header = $Header
    }
}

function Save-Transcript {
    param($Result, [string]$Path)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($h in $Result.Header) { $out.Add($h) }
    $out.Add(('Average confidence : {0}   |   Low-confidence tokens : {1}   |   Vocabulary corrections : {2}' -f `
        $Result.AvgConfidence, $Result.LowConfidence, $Result.Corrected))
    $out.Add('=' * 78)
    $out.Add('')
    if ($Result.Lines.Count -eq 0) { $out.Add('(no speech detected)') }
    foreach ($l in $Result.Lines) { $out.Add($l) }
    $out.Add('')
    $out.Add('=' * 78)
    $out.Add('[END OF TRANSCRIPT]')
    $temp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.ats-transcript-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllLines($temp, $out.ToArray(), (New-Object Text.UTF8Encoding($true)))
        [IO.File]::Move($temp, $Path)
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function New-OutputJob {
    param([string]$Directory, [string]$BaseName)
    for ($i = 1; $i -lt 10000; $i++) {
        $name = if ($i -eq 1) { $BaseName } else { $BaseName + '_' + $i }
        $base = Join-Path $Directory $name
        if ((Test-Path -LiteralPath ($base + '.json')) -or (Test-Path -LiteralPath ($base + '_Transcript.txt'))) { continue }
        $reservation = $base + '.ats-job.lock'
        try { $stream = [IO.File]::Open($reservation, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        catch [IO.IOException] { if (Test-Path -LiteralPath $reservation) { continue }; throw }
        return [pscustomobject]@{ OutBase = $base; Path = $reservation; Stream = $stream }
    }
    throw 'Could not reserve a unique output filename.'
}

function Close-OutputJob($Job) {
    if ($null -ne $Job) { $Job.Stream.Dispose(); Remove-Item -LiteralPath $Job.Path -Force -ErrorAction SilentlyContinue }
}

# ==============================================================================
#  AUDIO PREPARATION
# ==============================================================================
# Measured: highpass alone beat both the raw capture and a loudnorm chain.
# loudnorm lifts the noise floor during silence and makes Whisper hallucinate,
# so gain is applied only when the source is genuinely quiet, as a flat boost.
function Convert-ForWhisper {
    param([string]$InputPath, [string]$OutputPath, $StatusBox)
    $result = [pscustomobject]@{ Ok = $false; DurationSeconds = 0; Log = '' }
    $tmp = $OutputPath + '.gain.wav'
    try {
    if($script:cancelRequested){throw 'Cancelled by user.'}
    if (-not $script:FfmpegPath) {
        if ([System.IO.Path]::GetExtension($InputPath) -eq '.wav') {
            Copy-Item -LiteralPath $InputPath -Destination $OutputPath -Force
            $result.Ok = $true
            return $result
        }
        $result.Log = 'FFmpeg not found and the input is not a WAV file.'
        return $result
    }

    $args = @(
        '-hide_banner', '-nostdin', '-y', '-protocol_whitelist', 'file,pipe',
        '-i', (ConvertTo-CmdArg $InputPath),
        '-vn', '-af', 'highpass=f=80,volumedetect',
        '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
        (ConvertTo-CmdArg $OutputPath)
    ) -join ' '

    $sb = New-Object System.Text.StringBuilder
    $runner = Start-Child -FilePath $script:FfmpegPath -Arguments $args -Redirect
    $null = Wait-ForProcess -Runner $runner -Cancellable -OnOutput {
        param($o, $e)
        if ($o) { [void]$sb.Append($o) }
        if ($e) { [void]$sb.Append($e) }
        if ($sb.Length -gt 1048576) { [void]$sb.Remove(0, $sb.Length - 1048576) }
    }
    $log = $sb.ToString()
    $result.Log = $log

    if ($log -match 'Duration:\s*(\d{2}):(\d{2}):(\d{2})') {
        $result.DurationSeconds = ([int]$matches[1] * 3600) + ([int]$matches[2] * 60) + [int]$matches[3]
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) { return $result }

    # Flat make-up gain only for quiet sources.
    if ($log -match 'max_volume:\s*(-?\d+(\.\d+)?)\s*dB') {
        $maxVol = [double]$matches[1]
        if ($maxVol -lt -12.0) {
            $gain = [Math]::Min(20.0, [Math]::Round(-3.0 - $maxVol, 1))
            Add-Line $StatusBox ("   quiet source ({0} dB peak) - applying +{1} dB" -f $maxVol, $gain)
            $tmp = $OutputPath + '.gain.wav'
            $ga = @(
                '-hide_banner', '-nostdin', '-y', '-protocol_whitelist', 'file,pipe', '-i', (ConvertTo-CmdArg $OutputPath),
                '-af', "volume=$($gain)dB", '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
                (ConvertTo-CmdArg $tmp)
            ) -join ' '
            $gp = Start-Child -FilePath $script:FfmpegPath -Arguments $ga -Redirect
            $null = Wait-ForProcess -Runner $gp -Cancellable
            if (Test-Path -LiteralPath $tmp) {
                Move-Item -LiteralPath $tmp -Destination $OutputPath -Force
            }
        }
    }
    $result.Ok = $true
    return $result
    } finally { if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)} }
}

# ==============================================================================
#  DEVICES
# ==============================================================================
function Update-DeviceLists {
    $prevOut = if ($cmbOutputDev.SelectedItem) { $cmbOutputDev.SelectedItem.Id } else { [string]$script:Settings.OutputDevice }
    $prevIn  = if ($cmbInputDev.SelectedItem)  { $cmbInputDev.SelectedItem.Id }  else { [string]$script:Settings.InputDevice }

    [AudioEngine.CoreAudio]::ClearMeterCache()
    $cmbOutputDev.Items.Clear()
    $cmbInputDev.Items.Clear()

    $outs = @([AudioEngine.CoreAudio]::GetDevices(0))
    foreach ($d in $outs) { [void]$cmbOutputDev.Items.Add($d) }
    $ins = @([AudioEngine.CoreAudio]::GetDevices(1))
    foreach ($d in $ins) { [void]$cmbInputDev.Items.Add($d) }

    function Select-Best($combo, $prevId) {
        if ($combo.Items.Count -eq 0) { return }
        for ($i = 0; $i -lt $combo.Items.Count; $i++) {
            if ($combo.Items[$i].Id -eq $prevId) { $combo.SelectedIndex = $i; return }
        }
        for ($i = 0; $i -lt $combo.Items.Count; $i++) {
            if ($combo.Items[$i].IsDefault) { $combo.SelectedIndex = $i; return }
        }
        $combo.SelectedIndex = 0
    }
    Select-Best $cmbOutputDev $prevOut
    Select-Best $cmbInputDev  $prevIn

    $err = [AudioEngine.CoreAudio]::LastError
    if ($outs.Count -eq 0 -and $ins.Count -eq 0) {
        $lblSrcHint.ForeColor = $Theme.Danger
        $lblSrcHint.Text = if ($err) { "No audio devices found - $err" } else { 'No active audio devices found. Check Windows Sound settings.' }
    } else {
        $lblSrcHint.ForeColor = $Theme.InkMuted
        $lblSrcHint.Text = "$($outs.Count) Playback and $($ins.Count) Recording Device(s) Detected."
    }
    $lblEngine.Text = "$($script:ModelCatalog.Count) Models  |  $($script:Threads) Threads  |  FFMPEG: " +
                      $(if ($script:FfmpegPath) { 'Ready' } else { 'not found' })
}

# The capture endpoint meter reads 0 unless a stream is open on the device, so
# the mic meter needs a live monitor whenever we are not already recording.
function Sync-MicMonitor {
    $recording = [AudioEngine.CoreAudio]::IsRecording
    $want = $pnlLive.Visible -and $chkMic.Checked -and (-not $recording) -and ($null -ne $cmbInputDev.SelectedItem) -and $form.Visible
    if ($want) {
        $id = $cmbInputDev.SelectedItem.Id
        if ((-not [AudioEngine.CoreAudio]::IsMonitoring) -or ($script:monitorDev -ne $id)) {
            $script:monitorDev = $id
            [AudioEngine.CoreAudio]::StartMonitor($id)
        }
    } elseif ([AudioEngine.CoreAudio]::IsMonitoring) {
        [AudioEngine.CoreAudio]::StopMonitor()
        $script:monitorDev = $null
    }
}

function Update-ModelCombos {
    foreach ($c in @($cmbLiveModel, $cmbFinalModel, $cmbModel)) { $c.Items.Clear() }
    foreach ($m in $script:ModelCatalog) {
        [void]$cmbLiveModel.Items.Add($m.Display)
        [void]$cmbFinalModel.Items.Add($m.Display)
        [void]$cmbModel.Items.Add($m.Display)
    }
    if ($script:ModelCatalog.Count -eq 0) { return }

    function Pick($combo, $savedFile, $preferRank) {
        for ($i = 0; $i -lt $script:ModelCatalog.Count; $i++) {
            if ($script:ModelCatalog[$i].File -eq $savedFile) { $combo.SelectedIndex = $i; return }
        }
        $best = 0; $bestDelta = 99
        for ($i = 0; $i -lt $script:ModelCatalog.Count; $i++) {
            $d = [Math]::Abs($script:ModelCatalog[$i].Rank - $preferRank)
            if ($d -lt $bestDelta) { $bestDelta = $d; $best = $i }
        }
        $combo.SelectedIndex = $best
    }
    # realtime wants speed (small), the final pass wants accuracy (medium)
    Pick $cmbLiveModel  ([string]$script:Settings.LiveModel)  2
    Pick $cmbFinalModel ([string]$script:Settings.FinalModel) 3
    Pick $cmbModel      ([string]$script:Settings.FileModel)  3
}

# ==============================================================================
#  TAB SWITCHING
# ==============================================================================
function Show-Tab([string]$Which) {
    $live = ($Which -eq 'live')
    $pnlLive.Visible = $live
    $pnlFile.Visible = -not $live
    $btnTabLive.Kind = if ($live) { 'Primary' } else { 'Ghost' }
    $btnTabFile.Kind = if ($live) { 'Ghost' } else { 'Primary' }
    $btnTabLive.Invalidate(); $btnTabFile.Invalidate()
    Sync-MicMonitor
}
$btnTabLive.Add_Click({ Show-Tab 'live' })
$btnTabFile.Add_Click({ Show-Tab 'file' })

# A separate process handles downloads. Its lifetime is independent of recording.
# Poll on the UI thread; never attach PowerShell delegates to Process.Exited.
$script:modelManagerProcess = $null
$script:modelRefreshPending = $false
function Refresh-InstalledModels {
    foreach ($entry in @(@($cmbLiveModel, 'LiveModel'), @($cmbFinalModel, 'FinalModel'), @($cmbModel, 'FileModel'))) {
        $selected = Get-SelectedModel $entry[0]
        if ($selected) { $script:Settings[$entry[1]] = $selected.File }
    }
    $script:ModelCatalog = @(Get-ModelCatalog)
    Update-ModelCombos
    $lblEngine.Text = "$($script:ModelCatalog.Count) Models  |  $($script:Threads) Threads  |  FFMPEG: " + $(if ($script:FfmpegPath) { 'Ready' } else { 'not found' })
}
$modelManagerTimer = New-Object System.Windows.Forms.Timer
$modelManagerTimer.Interval = 500
$modelManagerTimer.Add_Tick({
    if ($null -ne $script:modelManagerProcess -and $script:modelManagerProcess.HasExited) {
        $script:modelManagerProcess.Dispose(); $script:modelManagerProcess = $null
        $btnManageModels.Enabled = $true; $script:modelRefreshPending = $true
    }
    if ($script:modelRefreshPending -and -not $script:fileBusy -and -not $script:uiBusy -and -not $script:recordingSessionActive -and -not $script:finalizing) {
        Refresh-InstalledModels; $script:modelRefreshPending = $false
        Add-Line $txtStatus 'Model list refreshed. Newly downloaded models are available.'
    }
    if ($null -eq $script:modelManagerProcess -and -not $script:modelRefreshPending) { $modelManagerTimer.Stop() }
})
$btnManageModels.Add_Click({
    if ($null -ne $script:modelManagerProcess -and -not $script:modelManagerProcess.HasExited) { return }
    try {
        $managerExe = Join-Path $WhisperDir 'AITranscriber.exe'
        if (-not (Test-Path -LiteralPath $managerExe)) { throw 'Install or repair using the updated AI-Transcriber-Setup.exe first. The model manager is installed alongside this app.' }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $managerExe; $psi.Arguments = '--models --install-dir ' + (ConvertTo-CmdArg $WhisperDir)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $WhisperDir
        $script:modelManagerProcess = [Diagnostics.Process]::Start($psi)
        $btnManageModels.Enabled = $false; $modelManagerTimer.Start()
    } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Manage Models', 'OK', 'Warning') }
})

# ==============================================================================
#  METER TIMER
# ==============================================================================
$vuTimer = New-Object System.Windows.Forms.Timer
$vuTimer.Interval = 50
$vuTimer.Add_Tick({
    try {
        $script:pulse += 0.06
        if ($script:pulse -gt 1.0) { $script:pulse = 0.0 }
        $recording = [AudioEngine.CoreAudio]::IsRecording

        if ($script:recordingSessionActive -and -not $recording -and -not $script:recordErrorShown) {
            $script:recordErrorShown = $true
            Add-Line $txtLiveFeed ('[warning] Capture stopped. ' + [AudioEngine.CoreAudio]::RecordError)
            $liveTimer.Stop()
            $btnRecord.Text = 'Finish Recording'
            Set-Pill $pillLive 'CAPTURE STOPPED' 'error'
        }

        if ($recording -and $pillLive.Tone -eq 'rec') { $pillLive.Pulse = $script:pulse; $pillLive.Invalidate() }
        if ($progressBar.Indeterminate) { $progressBar.Phase = $script:pulse; $progressBar.Invalidate() }

        if (-not $pnlLive.Visible) { return }

        if ($chkSys.Checked -and $null -ne $cmbOutputDev.SelectedItem) {
            $v = if ($recording) { [AudioEngine.CoreAudio]::TakeSysPeak() }
                 else { [AudioEngine.CoreAudio]::GetRenderPeak($cmbOutputDev.SelectedItem.Id) }
            Set-VuLevel -Meter $vuSys -Value $v
        } else { Set-VuLevel -Meter $vuSys -Value 0 -Muted $true }

        if ($chkMic.Checked -and $null -ne $cmbInputDev.SelectedItem) {
            Set-VuLevel -Meter $vuMic -Value ([AudioEngine.CoreAudio]::TakeMicPeak())
        } else { Set-VuLevel -Meter $vuMic -Value 0 -Muted $true }
    } catch { }
})

# ==============================================================================
#  LIVE CHUNK TRANSCRIPTION
# ==============================================================================
# Ticks fast so a finished chunk is picked up promptly; ChunkIntervalMs governs
# how often a new chunk is actually submitted. Polling on the slow cadence added
# up to four seconds of latency to every line.
$script:ChunkIntervalMs = 4000
$script:lastChunkStart = [DateTime]::MinValue

$liveTimer = New-Object System.Windows.Forms.Timer
$liveTimer.Interval = 500
$liveTimer.Add_Tick({
    if (-not [AudioEngine.CoreAudio]::IsRecording) { return }
    # Never start chunk work from inside someone else's DoEvents pump.
    if ($script:uiBusy) { return }
    try {
        $elapsed = [DateTime]::Now - $script:liveStart
        $lblDuration.Text = '{0:00}:{1:00}:{2:00}' -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
    } catch { }

    # A chunk already running: poll it instead of starting another. Collecting
    # the result here, on the UI thread, avoids any cross-thread callback.
    if ($script:chunkBusy) {
        try {
            if ($null -ne $script:chunkRunner -and $script:chunkRunner.HasExited) {
                $txt = $script:chunkBase + '.txt'
                if (Test-Path -LiteralPath $txt) {
                    $line = (Get-Content -LiteralPath $txt -Raw -Encoding UTF8).Trim()
                    $line = ($line -replace '\[BLANK_AUDIO\]', '' -replace '\s+', ' ').Trim()
                    if ($line.Length -gt 1) {
                        Add-Line $txtLiveFeed ("[{0}]  {1}" -f (Get-Date -Format 'HH:mm:ss'), $line)
                    }
                    Remove-Item -LiteralPath $txt -Force -ErrorAction SilentlyContinue
                }
                $script:chunkRunner.Dispose()
                $script:chunkRunner = $null
                $script:chunkBusy = $false
                Clear-FinishedChildren
            }
        } catch { $script:chunkBusy = $false; $script:chunkRunner = $null }
        return
    }

    if (([DateTime]::Now - $script:lastChunkStart).TotalMilliseconds -lt $script:ChunkIntervalMs) { return }

    try {
        $model = Get-SelectedModel $cmbLiveModel
        if ($null -eq $model) { return }
        $chunk = [AudioEngine.CoreAudio]::ExportRecentChunk($script:chunkWav, 8)
        if (-not $chunk -or -not (Test-Path -LiteralPath $chunk)) { return }

        $script:lastChunkStart = [DateTime]::Now
        $script:chunkBase = Join-Path $script:tempDir ('ats_live_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $lang = Resolve-Language -Model $model -Requested (Get-LangCode $cmbLang)
        $args = Build-WhisperArgs -ModelPath $model.Path -AudioPath $chunk -OutBase $script:chunkBase `
                                  -Lang $lang -Prompt $txtLiveKeywords.Text -Threads $script:Threads -Realtime

        $script:chunkRunner = Start-Child -FilePath $WhisperExe -Arguments $args
        $script:chunkBusy = $true
    } catch {
        $script:chunkBusy = $false
        $script:chunkRunner = $null
    }
})

# ==============================================================================
#  RECORD BUTTON
# ==============================================================================
$btnRecord.Add_Click({
    # A pump elsewhere can dispatch this click again while the stop sequence is
    # still running; re-entering it would start a second final pass.
    if ($script:uiBusy) { return }
    if (-not $script:recordingSessionActive) {
        # ---------------- start ----------------
        if (-not $chkSys.Checked -and -not $chkMic.Checked) {
            [void][System.Windows.Forms.MessageBox]::Show('Select at least one audio source.', 'Nothing to record',
                'OK', 'Warning'); return
        }
        $dest = $txtLiveDest.Text.Trim()
        if (-not (Test-Path -LiteralPath $dest)) {
            [void][System.Windows.Forms.MessageBox]::Show("Destination folder not found:`n$dest", 'Folder missing',
                'OK', 'Error'); return
        }
        if ($script:ModelCatalog.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show("No Whisper models (ggml-*.bin) found in:`n$WhisperDir",
                'No models', 'OK', 'Error'); return
        }

        [AudioEngine.CoreAudio]::StopMonitor()
        $script:monitorDev = $null

        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss_fff') + '_' + [Guid]::NewGuid().ToString('N').Substring(0,8)
        $script:masterWav = Join-Path $dest "Recording_$stamp.wav"
        $script:chunkWav  = Join-Path $script:tempDir ('ats_chunk_' + $PID + '.wav')

        $sysId = if ($chkSys.Checked -and $cmbOutputDev.SelectedItem) { $cmbOutputDev.SelectedItem.Id } else { '' }
        $micId = if ($chkMic.Checked -and $cmbInputDev.SelectedItem)  { $cmbInputDev.SelectedItem.Id }  else { '' }

        try {
            [AudioEngine.CoreAudio]::StartRecording($sysId, $micId, [bool]$chkSys.Checked, [bool]$chkMic.Checked,
                                                    1.0, 1.0, $script:masterWav)
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("Could not start recording:`n$($_.Exception.Message)",
                'Recording failed', 'OK', 'Error'); return
        }

        Start-Sleep -Milliseconds 350   # let the engine report device errors
        $err = [AudioEngine.CoreAudio]::RecordError
        if ($err) {
            Add-Line $txtLiveFeed "[warning] $err"
            if (-not [AudioEngine.CoreAudio]::IsRecording -or -not [AudioEngine.CoreAudio]::StreamInfo) {
                [AudioEngine.CoreAudio]::StopRecording()
                [void][System.Windows.Forms.MessageBox]::Show("Could not open any audio device.`n`n$err",
                    'Recording failed', 'OK', 'Error')
                Sync-MicMonitor
                return
            }
        }
        $lblStreamInfo.Text = [AudioEngine.CoreAudio]::StreamInfo
        $script:recordingSessionActive = $true
        $script:recordErrorShown = $false
        $script:cancelRequested = $false

        $script:liveStart = [DateTime]::Now
        $script:chunkBusy = $false
        $script:chunkRunner = $null
        $script:lastChunkStart = [DateTime]::MinValue
        $liveTimer.Start()

        Set-Pill $pillLive 'RECORDING' 'rec'
        $btnRecord.Text = 'Stop and Build Transcript'
        $btnRecord.Kind = 'Success'
        $btnRecord.Invalidate()
        $chkSys.Enabled = $false; $chkMic.Enabled = $false
        $cmbOutputDev.Enabled = $false; $cmbInputDev.Enabled = $false; $btnRefreshDev.Enabled = $false
        $btnTabFile.Enabled = $false
        $txtLiveFeed.Clear()
        Add-Line $txtLiveFeed ('Session started {0}' -f (Get-Date -Format 'dddd, MMMM d yyyy  h:mm tt'))
        Add-Line $txtLiveFeed ('Audio: ' + [AudioEngine.CoreAudio]::StreamInfo)
        Add-Line $txtLiveFeed ('-' * 70)
        return
    }

    # ---------------- stop ----------------
    $script:finalizing = $true
    $script:cancelRequested = $false
    try {
    $btnRecord.Enabled = $false
    $liveTimer.Stop()
    Set-Pill $pillLive 'FINALIZING' 'busy'
    Add-Line $txtLiveFeed ('-' * 70)
    Add-Line $txtLiveFeed 'Stopping Capture and Writing Master Audio'
    try { [AudioEngine.CoreAudio]::StopRecording(); $script:recordingSessionActive = $false }
    catch { Add-Line $txtLiveFeed "[error] $($_.Exception.Message)"; $btnRecord.Enabled = $true; return }
    [System.Windows.Forms.Application]::DoEvents()

    # Retire any in-flight realtime chunk. The live timer is already stopped, so
    # nothing else will collect it; give it a moment, then take the result or
    # kill it so it cannot compete with the final pass for CPU.
    if ($script:chunkBusy -and $null -ne $script:chunkRunner) {
        try { $null = Wait-ForProcess -Runner $script:chunkRunner -TimeoutSeconds 3 } catch { Add-Line $txtLiveFeed "[warning] $($_.Exception.Message)" }
        try {
            $txt = $script:chunkBase + '.txt'
            if (Test-Path -LiteralPath $txt) {
                $line = (Get-Content -LiteralPath $txt -Raw -Encoding UTF8).Trim()
                $line = ($line -replace '\[BLANK_AUDIO\]', '' -replace '\s+', ' ').Trim()
                if ($line.Length -gt 1) { Add-Line $txtLiveFeed ("[{0}]  {1}" -f (Get-Date -Format 'HH:mm:ss'), $line) }
                Remove-Item -LiteralPath $txt -Force -ErrorAction SilentlyContinue
            }
        } catch { }
        try { $script:chunkRunner.Dispose() } catch { }
    }
    $script:chunkRunner = $null
    $script:chunkBusy = $false
    Clear-FinishedChildren

    try { [AudioEngine.CoreAudio]::StopRecording() } catch { }

    $ok = $false
    $finalJob = $null
    $prepared = $null
    $preparedTemp = $null
    $failureMessage = 'The final transcription did not finish.'
    $diagnosticLog = $script:masterWav + '.transcription.log'
    try {
        if($script:cancelRequested){throw 'Cancelled by user.'}
        if (Test-Path -LiteralPath $script:masterWav) {
            $sizeMb = [Math]::Round((Get-Item -LiteralPath $script:masterWav).Length / 1MB, 2)
            Add-Line $txtLiveFeed "Master audio saved ($sizeMb MB): $script:masterWav"

            $model = Get-SelectedModel $cmbFinalModel
            if ($null -eq $model) { throw 'No model selected for the final pass. Select or install a model.' }
            elseif (-not (Test-Path -LiteralPath $WhisperExe)) { throw "whisper-cli.exe not found at $WhisperExe. Run setup to repair the app." }
            else {
                Add-Line $txtLiveFeed "Running final pass with $($model.Display)."
                [System.Windows.Forms.Application]::DoEvents()

                $prepared = $script:masterWav
                if ($script:FfmpegPath) {
                    $tmpWav = Join-Path $script:tempDir ('ats_final_' + $PID + '.wav')
                    $preparedTemp = $tmpWav
                    $conv = Convert-ForWhisper -InputPath $script:masterWav -OutputPath $tmpWav -StatusBox $txtLiveFeed
                    if ($conv.Ok) { $prepared = $tmpWav }
                }

                if($script:cancelRequested){throw 'Cancelled by user.'}
                $finalJob = New-OutputJob -Directory ([IO.Path]::GetDirectoryName($script:masterWav)) -BaseName ([IO.Path]::GetFileNameWithoutExtension($script:masterWav))
                $outBase = $finalJob.OutBase
                $lang = Resolve-Language -Model $model -Requested (Get-LangCode $cmbLang)
                $args = Build-WhisperArgs -ModelPath $model.Path -AudioPath $prepared -OutBase $outBase `
                                          -Lang $lang -Prompt $txtLiveKeywords.Text -Threads $script:Threads -ShowProgress

                $runner = Start-Child -FilePath $WhisperExe -Arguments $args -Redirect
                $finished = Wait-ForProcess -Runner $runner -Cancellable -OnOutput {
                    param($o, $e)
                    if ($e -and $e -match 'progress\s*=\s*(\d+)') {
                        Set-Pill $pillLive "FINALIZING $($matches[1])%" 'busy'
                    }
                }
                if (-not $finished) { throw 'Cancelled by user.' }

                $jsonPath = $outBase + '.json'
                if (Test-Path -LiteralPath $jsonPath) {
                    $vocab = @()
                    if (-not [string]::IsNullOrWhiteSpace($txtLiveKeywords.Text)) {
                        $vocab = @($txtLiveKeywords.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    }
                    $header = @(
                        ('=' * 78), 'LIVE SESSION TRANSCRIPT', ('=' * 78),
                        "Master audio  : $script:masterWav",
                        "Recorded      : $(Get-Date -Format 'MMMM d, yyyy  h:mm tt')",
                        "Duration      : $($lblDuration.Text)",
                        "Model         : $($model.Display)",
                        "Language      : $lang"
                    )
                    $res = Format-Transcript -JsonPath $jsonPath -Vocabulary $vocab -Header $header
                    $txtPath = $outBase + '_Transcript.txt'
                    Save-Transcript -Result $res -Path $txtPath
                    Add-Line $txtLiveFeed ''
                    Add-Line $txtLiveFeed "Transcript saved: $txtPath"
                    Add-Line $txtLiveFeed ("   {0} segments, average confidence {1}" -f $res.Lines.Count, $res.AvgConfidence)
                    $ok = $true
                } else {
                    throw 'Whisper did not produce a JSON result.'
                }
                if ($prepared -ne $script:masterWav) { Remove-Item -LiteralPath $prepared -Force -ErrorAction SilentlyContinue }
            }
        } else {
            throw 'No master audio file was written.'
        }
    } catch {
        $failureMessage=$_.Exception.Message
        Add-Line $txtLiveFeed "[error] $failureMessage"
        try { [IO.File]::WriteAllText($diagnosticLog, ((Get-Date -Format s)+"`r`n"+$failureMessage+"`r`nAudio: "+$script:masterWav), (New-Object Text.UTF8Encoding($true))); Add-Line $txtLiveFeed "Diagnostic log: $diagnosticLog" } catch { }
    } finally {
        Close-OutputJob $finalJob; Clear-FinishedChildren
        if($prepared -and $prepared -ne $script:masterWav){Remove-Item -LiteralPath $prepared -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath ($prepared+'.gain.wav') -Force -ErrorAction SilentlyContinue}
        if($preparedTemp){Remove-Item -LiteralPath $preparedTemp -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath ($preparedTemp+'.gain.wav') -Force -ErrorAction SilentlyContinue}
    }

    Set-Pill $pillLive $(if ($ok) { 'COMPLETE' } elseif($script:cancelRequested){'CANCELLED'} else { 'TRANSCRIPT FAILED' }) $(if ($ok) { 'ok' } else { 'error' })
    if(-not $ok){$lblStreamInfo.Text='Audio kept. '+$failureMessage}
    $btnRecord.Text = 'Start Recording'
    $btnRecord.Kind = 'Danger'
    $btnRecord.Enabled = $true
    $btnRecord.Invalidate()
    $chkSys.Enabled = $true; $chkMic.Enabled = $true
    $cmbOutputDev.Enabled = $true; $cmbInputDev.Enabled = $true; $btnRefreshDev.Enabled = $true
    $btnTabFile.Enabled = $true
    Remove-Item -LiteralPath $script:chunkWav -Force -ErrorAction SilentlyContinue
    Sync-MicMonitor
    } finally {
        $script:finalizing=$false
        if ($script:closeAfterCancel) { $script:closeAfterCancel = $false; $form.Close() }
    }
})

# ==============================================================================
#  FILE TRANSCRIPTION
# ==============================================================================
$btnStart.Add_Click({
    if ($script:fileBusy -or $script:uiBusy) { return }
    $inputFile = $txtInput.Text.Trim()
    $outDir    = $txtOutput.Text.Trim()
    $model     = Get-SelectedModel $cmbModel

    if (-not (Test-Path -LiteralPath $inputFile)) { Add-Line $txtStatus '[error] Input file not found.'; return }
    if (-not (Test-Path -LiteralPath $outDir))    { Add-Line $txtStatus '[error] Destination folder not found.'; return }
    if ($null -eq $model)                          { Add-Line $txtStatus '[error] No model selected.'; return }
    if (-not (Test-Path -LiteralPath $WhisperExe)) { Add-Line $txtStatus "[error] whisper-cli.exe not found at $WhisperExe"; return }

    $script:fileBusy = $true
    $script:cancelRequested = $false
    $btnStart.Enabled = $false; $btnCancel.Enabled = $true; $btnTabLive.Enabled = $false
    $txtStatus.Clear()
    Set-Pill $pillFile 'PREPARING' 'busy'
    $progressBar.Indeterminate = $true
    $lblProgress.Text = 'Extracting Audio, Please Wait!'

    $info = Get-Item -LiteralPath $inputFile
    $tempWav = Join-Path $script:tempDir ('ats_file_' + $PID + '.wav')
    $outputJob = $null
    $done = $false

    try {
        $outputJob = New-OutputJob -Directory $outDir -BaseName $info.BaseName
        $outBase = $outputJob.OutBase
        Add-Line $txtStatus "Source : $($info.Name)  ($([Math]::Round($info.Length/1MB,1)) MB)"
        Add-Line $txtStatus "Model  : $($model.Display)"
        Add-Line $txtStatus ''
        Add-Line $txtStatus '1. Extracting and Conditioning Audio, Please Wait!'
        [System.Windows.Forms.Application]::DoEvents()

        $conv = Convert-ForWhisper -InputPath $inputFile -OutputPath $tempWav -StatusBox $txtStatus
        if ($script:cancelRequested) { throw 'Cancelled by user.' }
        if (-not $conv.Ok -or -not (Test-Path -LiteralPath $tempWav)) {
            Add-Line $txtStatus '[error] Could not extract audio.'
            if (-not $script:FfmpegPath) {
                Add-Line $txtStatus '   FFmpeg was not found. Install it with:  winget install Gyan.FFmpeg'
            } elseif ($conv.Log) {
                $tail = ($conv.Log -split "`n" | Select-Object -Last 6) -join "`r`n"
                Add-Line $txtStatus "   ffmpeg said:`r`n$tail"
            }
            throw 'audio extraction failed'
        }
        $total = [Math]::Max(1, $conv.DurationSeconds)
        Add-Line $txtStatus "   duration $([TimeSpan]::FromSeconds($total).ToString('hh\:mm\:ss'))"
        Add-Line $txtStatus ''
        Add-Line $txtStatus '2. Transcribing, Please Wait!'

        $progressBar.Indeterminate = $false
        $progressBar.Value = 0; $progressBar.Invalidate()
        Set-Pill $pillFile 'TRANSCRIBING' 'busy'

        $lang = Resolve-Language -Model $model -Requested (Get-LangCode $cmbFileLang)
        $args = Build-WhisperArgs -ModelPath $model.Path -AudioPath $tempWav -OutBase $outBase `
                                  -Lang $lang -Prompt $txtContext.Text -Threads $script:Threads -ShowProgress

        $runner = Start-Child -FilePath $WhisperExe -Arguments $args -Redirect
        $completed = Wait-ForProcess -Runner $runner -Cancellable -OnOutput {
            param($o, $e)
            # -pp writes "progress = NN%" to stderr; segment lines go to stdout.
            if ($e) {
                $m = [regex]::Matches($e, 'progress\s*=\s*(\d+)')
                if ($m.Count -gt 0) {
                    $pct = [int]$m[$m.Count - 1].Groups[1].Value
                    $progressBar.Value = $pct / 100.0
                    $progressBar.Invalidate()
                    $lblProgress.Text = "$pct%"
                }
            }
            if ($o) {
                $m = [regex]::Matches($o, '\[(\d{2}):(\d{2}):(\d{2})\.\d{3}\s+--')
                if ($m.Count -gt 0) {
                    $g = $m[$m.Count - 1].Groups
                    $secs = ([int]$g[1].Value * 3600) + ([int]$g[2].Value * 60) + [int]$g[3].Value
                    if ($progressBar.Value -lt 0.01) {
                        $lblProgress.Text = "$([TimeSpan]::FromSeconds($secs).ToString('hh\:mm\:ss')) processed"
                    }
                }
            }
        }
        if (-not $completed) { throw 'Cancelled by user.' }

        $progressBar.Value = 1.0; $progressBar.Invalidate()
        $lblProgress.Text = '100%'
        Add-Line $txtStatus ''
        Add-Line $txtStatus '3. Formatting Transcript, Please Wait!'

        $jsonPath = $outBase + '.json'
        if (-not (Test-Path -LiteralPath $jsonPath)) { Add-Line $txtStatus '[error] Whisper produced no JSON output.'; throw 'no json' }

        $vocab = @()
        if (-not [string]::IsNullOrWhiteSpace($txtContext.Text)) {
            $vocab = @($txtContext.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $header = @(
            ('=' * 78), 'TRANSCRIPT', ('=' * 78),
            "Source     : $($info.Name)",
            "Transcribed: $(Get-Date -Format 'MMMM d, yyyy  h:mm tt')",
            "Duration   : $([TimeSpan]::FromSeconds($total).ToString('hh\:mm\:ss'))",
            "Model      : $($model.Display)",
            "Language   : $lang"
        )
        $res = Format-Transcript -JsonPath $jsonPath -Vocabulary $vocab -Header $header
        $txtPath = $outBase + '_Transcript.txt'
        Save-Transcript -Result $res -Path $txtPath

        Add-Line $txtStatus ''
        Add-Line $txtStatus "Done. $($res.Lines.Count) segments, average confidence $($res.AvgConfidence)."
        if ($res.Corrected -gt 0)  { Add-Line $txtStatus "   $($res.Corrected) vocabulary correction(s) applied." }
        if ($res.LowConfidence -gt 0) { Add-Line $txtStatus "   $($res.LowConfidence) uncertain token(s) marked with [?]." }
        Add-Line $txtStatus ''
        Add-Line $txtStatus "Saved: $txtPath"
        $done = $true
    } catch {
        if ($script:cancelRequested) { Add-Line $txtStatus 'Cancelled.' }
        elseif ("$($_.Exception.Message)" -notin @('audio extraction failed', 'no json')) {
            Add-Line $txtStatus "[error] $($_.Exception.Message)"
        }
    } finally {
        Close-OutputJob $outputJob
        Clear-FinishedChildren
        Remove-Item -LiteralPath $tempWav -Force -ErrorAction SilentlyContinue
        $progressBar.Indeterminate = $false
        if (-not $done) { $progressBar.Value = 0; $progressBar.Invalidate(); $lblProgress.Text = '' }
        Set-Pill $pillFile $(if ($done) { 'COMPLETE' } elseif ($script:cancelRequested) { 'CANCELLED' } else { 'FAILED' }) `
                 $(if ($done) { 'ok' } else { 'idle' })
        $btnStart.Enabled = $true; $btnCancel.Enabled = $false; $btnTabLive.Enabled = $true
        $script:fileBusy = $false
        $script:cancelRequested = $false
        if ($script:closeAfterCancel) { $script:closeAfterCancel = $false; $form.Close() }
    }
})

$btnCancel.Add_Click({
    if ($script:fileBusy) { $script:cancelRequested = $true; Set-Pill $pillFile 'CANCELLING' 'busy' }
})

# ==============================================================================
#  BROWSE / DRAG AND DROP
# ==============================================================================
$btnLiveBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Where should recordings and transcripts be saved?'
    if (Test-Path -LiteralPath $txtLiveDest.Text) { $dlg.SelectedPath = $txtLiveDest.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtLiveDest.Text = $dlg.SelectedPath }
    $dlg.Dispose()
})

$btnInput.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Media files|*.mp4;*.mkv;*.avi;*.mov;*.webm;*.mp3;*.wav;*.m4a;*.flac;*.ogg;*.aac;*.wma|All files|*.*'
    $dlg.Title = 'Select an audio or video file'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtInput.Text = $dlg.FileName
        if ([string]::IsNullOrWhiteSpace($txtOutput.Text)) {
            $txtOutput.Text = [System.IO.Path]::GetDirectoryName($dlg.FileName)
        }
    }
    $dlg.Dispose()
})

$btnOutput.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select destination folder'
    if (Test-Path -LiteralPath $txtOutput.Text) { $dlg.SelectedPath = $txtOutput.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtOutput.Text = $dlg.SelectedPath }
    $dlg.Dispose()
})

$form.AllowDrop = $true
$form.Add_DragEnter({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' }
})
$form.Add_DragDrop({
    param($s, $e)
    try {
        $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        if ($files -and $files.Count -gt 0) {
            Show-Tab 'file'
            $txtInput.Text = $files[0]
            if ([string]::IsNullOrWhiteSpace($txtOutput.Text)) {
                $txtOutput.Text = [System.IO.Path]::GetDirectoryName($files[0])
            }
        }
    } catch { }
})

$btnRefreshDev.Add_Click({ Update-DeviceLists; Sync-MicMonitor })
$chkMic.Add_CheckedChanged({ Sync-MicMonitor })
$chkSys.Add_CheckedChanged({ })
$cmbInputDev.Add_SelectedIndexChanged({ Sync-MicMonitor })

# ==============================================================================
#  ERROR HANDLING
# ==============================================================================
# A dialog raised from inside the exception handler can itself fault while it
# pumps messages, re-entering this handler. Without the latch that recursion
# runs until the stack overflows and the process dies with no diagnostics.
$script:inErrorDialog = $false
function Show-AppError($ex) {
    if ($script:inErrorDialog) { return }
    $script:inErrorDialog = $true
    try {
        $msg = if ($ex) { "$ex" } else { 'Unknown error' }
        if ($msg.Length -gt 900) { $msg = $msg.Substring(0, 900) + '...' }
        [void][System.Windows.Forms.MessageBox]::Show(
            "Something went wrong, but the app is still running.`n`n$msg",
            'AI Transcriber Studio', 'OK', 'Warning')
    } catch { }
    finally { $script:inErrorDialog = $false }
}
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) Show-AppError $e.Exception })

# ==============================================================================
#  LIFECYCLE
# ==============================================================================
$form.Add_Shown({
    Update-ModelCombos
    Update-DeviceLists
    Show-Tab 'live'
    $vuTimer.Start()
    Sync-MicMonitor
    Set-Pill $pillLive 'IDLE' 'idle'
    Set-Pill $pillFile 'READY' 'idle'
    Add-Line $txtLiveFeed 'Ready. Choose your sources and press Start Recording.'
    Add-Line $txtStatus 'Ready. Select a media file, or drag one onto this window.'
    if ($script:ModelCatalog.Count -eq 0) {
        Add-Line $txtLiveFeed "[warning] No ggml-*.bin models found in $WhisperDir"
    }
    if (-not $script:FfmpegPath) {
        Add-Line $txtStatus '[warning] FFmpeg not found - only WAV input will work. Install: winget install Gyan.FFmpeg'
    }
})

$form.Add_FormClosing({
    param($s, $e)
    if ($script:fileBusy -or $script:uiBusy -or $script:finalizing) { $script:cancelRequested = $true; $script:closeAfterCancel = $true; $e.Cancel = $true; return }
    if ($script:recordingSessionActive -or [AudioEngine.CoreAudio]::IsRecording) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'A recording is still running. Stop it and close?', 'Recording in progress', 'YesNo', 'Warning')
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        try { [AudioEngine.CoreAudio]::StopRecording(); $script:recordingSessionActive = $false }
        catch { $e.Cancel = $true; Add-Line $txtLiveFeed ('[warning] ' + $_.Exception.Message); return }
    }
    if ($script:fileBusy) { $script:cancelRequested = $true }
    try { $vuTimer.Stop(); $liveTimer.Stop(); $modelManagerTimer.Stop() } catch { }
    if ($null -ne $script:modelManagerProcess) { $script:modelManagerProcess.Dispose() }
    try { [AudioEngine.CoreAudio]::StopMonitor() } catch { }
    try { if ([AudioEngine.CoreAudio]::IsRecording) { [AudioEngine.CoreAudio]::StopRecording() } } catch { }
    try { [AudioEngine.CoreAudio]::ClearMeterCache() } catch { }

    # Only this session's children. The old build killed every whisper-cli and
    # ffmpeg process on the machine, including other people's work.
    Stop-Children
    try { Get-ChildItem -LiteralPath $script:ownedTempDir -File -ErrorAction Stop | Remove-Item -Force -ErrorAction Stop; [IO.Directory]::Delete($script:ownedTempDir) } catch { }

    try {
        $script:Settings.OutputDevice = if ($cmbOutputDev.SelectedItem) { $cmbOutputDev.SelectedItem.Id } else { '' }
        $script:Settings.InputDevice  = if ($cmbInputDev.SelectedItem)  { $cmbInputDev.SelectedItem.Id }  else { '' }
        $script:Settings.UseSystem    = [bool]$chkSys.Checked
        $script:Settings.UseMic       = [bool]$chkMic.Checked
        $m = Get-SelectedModel $cmbLiveModel;  if ($m) { $script:Settings.LiveModel = $m.File }
        $m = Get-SelectedModel $cmbFinalModel; if ($m) { $script:Settings.FinalModel = $m.File }
        $m = Get-SelectedModel $cmbModel;      if ($m) { $script:Settings.FileModel = $m.File }
        $script:Settings.SaveFolder     = $txtLiveDest.Text
        $script:Settings.Vocabulary     = $txtLiveKeywords.Text
        $script:Settings.FileVocabulary = $txtContext.Text
        Export-AppSettings
    } catch { }
    Remove-Item -LiteralPath (Join-Path $script:tempDir ('ats_chunk_' + $PID + '.wav')) -Force -ErrorAction SilentlyContinue
})

$form.Add_Shown({ Update-AppLayout -ConstrainWindow })
$form.ResumeLayout($true)
Update-AppLayout -ConstrainWindow
$form.Add_Resize({ Update-AppLayout })
[void]$form.ShowDialog()
$form.Dispose()
foreach ($paintFont in $script:PaintFontCache.Values) { $paintFont.Dispose() }
$script:PaintFontCache.Clear()
