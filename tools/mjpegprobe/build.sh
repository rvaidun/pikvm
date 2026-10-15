#!/bin/bash
# Cross-compiles mjpegprobe.exe for x64 Windows with mingw-w64
# (Debian/Ubuntu: apt install g++-mingw-w64-x86-64-posix).
set -euo pipefail
cd "$(dirname "$0")"
x86_64-w64-mingw32-g++-posix -O2 -std=c++17 -static -o mjpegprobe.exe mjpegprobe.cpp \
  -lmfreadwrite -lmfplat -lmf -lmfuuid -ld3d11 -ldxgi -lole32 -luuid -lstrmiids
echo "built $(pwd)/mjpegprobe.exe"
