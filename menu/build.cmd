@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0"
cl /nologo /O2 /EHsc /std:c++17 /LD /DUNICODE /D_UNICODE ClaudeCodeMenu.cpp /link /DEF:ClaudeCodeMenu.def /OUT:..\ClaudeCodeMenu.dll || exit /b 1
cl /nologo /O2 /DUNICODE /D_UNICODE Stub.cpp /link /SUBSYSTEM:WINDOWS /OUT:..\ClaudeCodeMenuStub.exe || exit /b 1
del /q *.obj ..\ClaudeCodeMenu.exp ..\ClaudeCodeMenu.lib 2>nul
echo BUILD OK
