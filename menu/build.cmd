@echo off
rem Builds the Explorer menu DLL and the package stub into menu\bin. Needs Visual Studio with the C++ tools.
setlocal
set "VSINSTALLER=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer"
set "PATH=%PATH%;%VSINSTALLER%"
set "VS="
for /f "usebackq delims=" %%i in (`vswhere.exe -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if not defined VS (echo Visual Studio C++ tools not found & exit /b 1)
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0src"
if not exist ..\bin mkdir ..\bin
cl /nologo /O2 /EHsc /std:c++17 /LD /DUNICODE /D_UNICODE /Fo..\bin\ ClaudeCodeMenu.cpp /link /DEF:ClaudeCodeMenu.def /OUT:..\bin\ClaudeCodeMenu.dll /IMPLIB:..\bin\ClaudeCodeMenu.lib || exit /b 1
cl /nologo /O2 /DUNICODE /D_UNICODE /Fo..\bin\ Stub.cpp /link /SUBSYSTEM:WINDOWS /OUT:..\bin\ClaudeCodeMenuStub.exe || exit /b 1
del /q ..\bin\*.obj ..\bin\ClaudeCodeMenu.exp ..\bin\ClaudeCodeMenu.lib 2>nul
echo BUILD OK
