$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'resources\Transcriber-UI.ps1'))
$match = [regex]::Match($source, "Add-Type -TypeDefinition @'\r?\n([\s\S]*?)\r?\n'@")
if (-not $match.Success) { throw 'Embedded AudioEngine source was not found.' }
# Managed fakes run the real Drain code without opening or recording a device.
$fixture = @'
namespace AudioEngine {
    internal sealed class FailingAudioClient : IAudioClient {
        public int Initialize(int mode, int flags, long duration, long period, System.IntPtr format, ref System.Guid session) { return 0; }
        public int GetBufferSize(out uint frames) { frames = 0; return 0; }
        public int GetStreamLatency(out long latency) { latency = 0; return 0; }
        public int GetCurrentPadding(out uint frames) { frames = 0; return 0; }
        public int IsFormatSupported(int mode, System.IntPtr format, out System.IntPtr closest) { closest = System.IntPtr.Zero; return 0; }
        public int GetMixFormat(out System.IntPtr format) { format = System.IntPtr.Zero; return 0; }
        public int GetDevicePeriod(out long normal, out long minimum) { normal = minimum = 0; return 0; }
        public int Start() { return FailingCapture.Failure; }
        public int Stop() { return 0; }
        public int Reset() { return 0; }
        public int SetEventHandle(System.IntPtr handle) { return 0; }
        public int GetService(ref System.Guid id, out object service) { service = null; return 0; }
    }
    internal sealed class FailingCapture : IAudioCaptureClient {
        internal const int Failure = unchecked((int)0x88890004);
        internal string Point;
        internal int NextCalls, BufferCalls, ReleaseCalls;
        public int GetNextPacketSize(out uint frames) {
            NextCalls++; frames = Point == "empty" || NextCalls > 1 ? 0u : 1u;
            return Point == "GetNextPacketSize" ? Failure : 0;
        }
        public int GetBuffer(out System.IntPtr data, out uint frames, out int flags, out ulong device, out ulong clock) {
            BufferCalls++; data = System.IntPtr.Zero; frames = 1; flags = 2; device = clock = 0;
            return Point == "GetBuffer" ? Failure : 0;
        }
        public int ReleaseBuffer(uint frames) {
            ReleaseCalls++; return Point == "ReleaseBuffer" ? Failure : 0;
        }
    }
    public static class CaptureFailureFixture {
        static readonly System.Reflection.BindingFlags Fields = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        public static string[] Drain(string point) {
            var capture = new FailingCapture { Point = point };
            var stream = new CaptureStream();
            typeof(CaptureStream).GetField("_cap", Fields).SetValue(stream, capture);
            typeof(CaptureStream).GetField("_rate", Fields).SetValue(stream, 16000);
            string error = "";
            try { stream.Drain(true); } catch (System.Exception ex) { error = ex.ToString(); }
            finally { typeof(CaptureStream).GetField("_cap", Fields).SetValue(stream, null); stream.Dispose(); }
            return new[] { error, capture.BufferCalls.ToString(), capture.ReleaseCalls.ToString(), stream.Out.Count.ToString() };
        }
        public static bool CheckStartFailure() {
            var method = typeof(CaptureStream).GetMethod("CheckResult", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
            if (method == null) return false;
            IAudioClient client = new FailingAudioClient();
            try { method.Invoke(null, new object[] { client.Start(), "Start" }); }
            catch (System.Reflection.TargetInvocationException ex) { return ex.InnerException != null; }
            return false;
        }
        public static bool CheckSuccessfulStatus() {
            var method = typeof(CaptureStream).GetMethod("CheckResult", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
            if (method == null) return false;
            method.Invoke(null, new object[] { 0, "Start" });
            method.Invoke(null, new object[] { 1, "Start" });
            return true;
        }
        public static string[] WorkerWithReadOnlyWav(string path) {
            var fields = System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic;
            var type = typeof(CoreAudio);
            System.IO.File.WriteAllBytes(path, new byte[44]);
            var readOnly = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Read);
            type.GetField("_wav", fields).SetValue(null, readOnly);
            type.GetField("_dataBytes", fields).SetValue(null, 0L);
            type.GetField("_recSys", fields).SetValue(null, false);
            type.GetField("_recMic", fields).SetValue(null, false);
            type.GetField("_recRunning", fields).SetValue(null, true);
            CoreAudio.RecordError = "";
            string escaped = "";
            try {
                try { type.GetMethod("RecordWorker", fields).Invoke(null, new object[0]); }
                catch (System.Reflection.TargetInvocationException ex) { escaped = (ex.InnerException ?? ex).ToString(); }
                return new[] { escaped, CoreAudio.IsRecording.ToString(), (type.GetField("_wav", fields).GetValue(null) == null).ToString(), (!readOnly.CanRead).ToString(), CoreAudio.RecordError };
            } finally {
                readOnly.Dispose();
                type.GetField("_wav", fields).SetValue(null, null);
                type.GetField("_recRunning", fields).SetValue(null, false);
            }
        }
    }
}
'@
Add-Type -TypeDefinition ($match.Groups[1].Value + "`r`n" + $fixture)
$pass = 0; $fail = 0
function Check($name, [scriptblock]$body) {
    try { & $body; $script:pass++; "PASS $name" }
    catch { $script:fail++; "FAIL $name : $($_.Exception.Message)" }
}
Check 'failed packet-size status is surfaced instead of treated as silence' {
    $result = [AudioEngine.CaptureFailureFixture]::Drain('GetNextPacketSize')
    if (-not $result[0]) { throw 'The capture failure was swallowed.' }
    if ($result[1] -ne '0' -or $result[2] -ne '0') { throw 'A failed packet-size call reached the buffer.' }
}
Check 'failed GetBuffer status is surfaced without releasing an unacquired buffer' {
    $result = [AudioEngine.CaptureFailureFixture]::Drain('GetBuffer')
    if (-not $result[0]) { throw 'The capture failure was swallowed.' }
    if ($result[1] -ne '1' -or $result[2] -ne '0') { throw 'Buffer ownership was not respected.' }
}
Check 'failed ReleaseBuffer status is surfaced after exactly one release' {
    $result = [AudioEngine.CaptureFailureFixture]::Drain('ReleaseBuffer')
    if (-not $result[0]) { throw 'The capture failure was swallowed.' }
    if ($result[1] -ne '1' -or $result[2] -ne '1') { throw 'The acquired buffer was not released exactly once.' }
}
Check 'empty successful packet is ordinary silence' {
    $result = [AudioEngine.CaptureFailureFixture]::Drain('empty')
    if ($result[0] -or $result[1] -ne '0' -or $result[3] -ne '0') { throw 'An empty successful packet was handled as failure or data.' }
}
Check 'silent acquired packet is released and retained' {
    $result = [AudioEngine.CaptureFailureFixture]::Drain('silent')
    if ($result[0] -or $result[2] -ne '1' -or $result[3] -ne '1') { throw 'A valid silent packet was lost or not released.' }
}
Check 'startup status helper rejects a failed Start HRESULT' {
    if (-not [AudioEngine.CaptureFailureFixture]::CheckStartFailure()) { throw 'Failed startup HRESULT was accepted or no status checker exists.' }
}
Check 'startup status helper permits successful HRESULTs' {
    if (-not [AudioEngine.CaptureFailureFixture]::CheckSuccessfulStatus()) { throw 'Successful status check is unavailable.' }
}
Check 'WAV finalization failure is contained and reported after the worker stops' {
    $directory = Join-Path $root ('test-results\capture-failure-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $result = [AudioEngine.CaptureFailureFixture]::WorkerWithReadOnlyWav((Join-Path $directory 'readonly.wav'))
    if ($result[0]) { throw "Exception escaped the worker: $($result[0])" }
    if ($result[1] -ne 'False') { throw 'Failed worker remained marked as recording.' }
    if ($result[2] -ne 'True' -or $result[3] -ne 'True') { throw 'The failed WAV writer was not disposed and cleared.' }
    if ($result[4] -notmatch 'finaliz|writ|WAV') { throw "WAV finalization failure was not reported: $($result[4])" }
}
"CAPTURE FAILURE RESULT $pass passed, $fail failed"
if ($fail) { exit 1 }
