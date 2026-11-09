# AI Transcriber Studio license and third-party notices

MIT License

Copyright (c) 2026 Transcriber Studio Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Third-party components

Whisper CPU runtime: ggml-org/whisper.cpp build b5454, MIT license.
Release and corresponding source: https://github.com/ggml-org/whisper.cpp/tree/b5454
The full MIT text is included in Whisper-LICENSE.txt.
The downloaded CLI's Windows activation manifest is amended locally to use
UTF-8 as its process code page. This fixes non-ASCII model/output paths on
supported Windows builds. Native program instructions are unchanged.
The archive SHA-256 is verified before this documented resource
change; the derived executable's SHA-256 is stored in installation.json.

Models: ggerganov/whisper.cpp at revision 5359861c739e955e79d9a303bcbc70fb988958b1.
https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1
Whisper model weights and original code: https://github.com/openai/whisper (MIT).

FFmpeg: Gyan.dev 9.0.2 essentials Windows build. Downloaded directly from the
provider's release: https://github.com/GyanD/codexffmpeg/releases/tag/9.0.2
FFmpeg is free software. This build includes GPL components. The archive's
LICENSE and README are retained in the installation's licenses folder.
Build configuration/source information: https://www.gyan.dev/ffmpeg/builds/
Corresponding FFmpeg source: https://github.com/FFmpeg/FFmpeg/tree/n9.0.2
License information: https://ffmpeg.org/legal.html

Microsoft Visual C++ Redistributable x64 is downloaded from Microsoft only
if a required native runtime is missing. Its Microsoft license applies.
https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist

Runtime archives and model weights are not embedded in the setup executable.
