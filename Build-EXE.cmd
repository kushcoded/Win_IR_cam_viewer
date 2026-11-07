@echo off
setlocal
cd /d "%~dp0"
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" ( echo .NET Framework 4 compiler not found. & pause & exit /b 1 )

"%CSC%" /nologo /target:winexe /out:IR-Camera-Viewer.exe /win32icon:app.ico ^
  /reference:System.Windows.Forms.dll /resource:IR-Camera-Viewer.ps1,IR-Camera-Viewer.ps1 Launcher.cs
if errorlevel 1 ( echo Build failed. & pause & exit /b 1 )
echo Built IR-Camera-Viewer.exe
pause
