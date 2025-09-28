@echo off
setlocal enabledelayedexpansion

rem Paths
for %%I in ("%~dp0\..") do set ROOT=%%~fI
set REL=%ROOT%\release

if not exist "%REL%\windows_amd64" mkdir "%REL%\windows_amd64"
if not exist "%REL%\windows_arm64" mkdir "%REL%\windows_arm64"

rem ----- amd64 -----
echo ==^> Go c-shared windows/amd64
set GOOS=windows
set GOARCH=amd64
set CGO_ENABLED=1
go build -buildmode=c-shared -o "%REL%\windows_amd64\teleport_amd64_windows.dll" "%ROOT%\main.go"
copy /Y "%REL%\windows_amd64\teleport_amd64_windows.dll.h" "%REL%\windows_amd64\teleport.h" >NUL

echo ==^> MSVC bench link (amd64)
pushd "%REL%\windows_amd64"
cl /nologo /std:c11 "%ROOT%\simple_bench.c" teleport_amd64_windows.lib /I. /Fe:simple_bench_windows_amd64.exe
popd

rem ----- arm64 -----
echo ==^> Go c-shared windows/arm64
set GOOS=windows
set GOARCH=arm64
set CGO_ENABLED=1
go build -buildmode=c-shared -o "%REL%\windows_arm64\teleport_arm64_windows.dll" "%ROOT%\main.go"
copy /Y "%REL%\windows_arm64\teleport_arm64_windows.dll.h" "%REL%\windows_arm64\teleport.h" >NUL

echo ==^> MSVC bench link (arm64)
pushd "%REL%\windows_arm64"
rem Use the ARM64 Developer Prompt for this; otherwise specify /arm64 switch + proper libs
cl /nologo /std:c11 "%ROOT%\simple_bench.c" teleport_arm64_windows.lib /I. /Fe:simple_bench_windows_arm64.exe
popd

echo Done. See %REL%
