# AI Transcriber Studio

AI Transcriber Studio is a Windows desktop app for local transcription with Whisper. Record your microphone, system audio, or both. You can also transcribe an existing audio file.

## Install

1. Open **Releases** and download `AI-Transcriber-Setup.exe`.
2. Run setup on a Windows 10 (version 1903 or later) or Windows 11 PC with a 64-bit Intel or AMD processor. Choose the installation folder and a Whisper model.
3. Open **AI Transcriber Studio** from Start. Use **Download / Manage Models** to add models later.

Setup needs internet access to fetch dependencies and your chosen model. Transcription runs on your computer after the downloads finish. This release's installer is unsigned. You can compare its SHA-256 with the checksum on the release page:

```powershell
Get-FileHash .\AI-Transcriber-Setup.exe -Algorithm SHA256
```

## Build and test

Use Windows PowerShell 5.1 on Windows x64. The build uses the compiler bundled with .NET Framework. Keep the checkout path short, such as `C:\src\ats`, because some installer tests add long temporary paths beneath it.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1 -Test
.\build\InstallerTests.exe all
```

The build writes `build\AI-Transcriber-Setup.exe`. The test suite uses isolated fixtures. A rebuild can have a different executable checksum because of compiler metadata.

Optional download and UI smoke tests use real Whisper and FFmpeg packages. Allow more than 2 GB of free space. To run the UI smoke tests, download the [upstream JFK sample](https://raw.githubusercontent.com/ggml-org/whisper.cpp/b5454/samples/jfk.wav) separately and save it as `tests\assets\jfk.wav`.

```powershell
.\build\InstallerTests.exe --smoke-small
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Run-Smoke.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Run-Recording-Smoke.ps1
```

The project source is available under the [MIT license](LICENSE). See the [third-party notices](resources/THIRD-PARTY-NOTICES.md) for the licenses and sources of Whisper, the model weights, FFmpeg, and the Microsoft runtime.
