@echo off
setlocal
set "XIAOQI_FLUTTER_SDK=%USERPROFILE%\develop\flutter-3.47.5\flutter"
set "PUB_CACHE=%LOCALAPPDATA%\Pub\CacheD"
if not exist "%XIAOQI_FLUTTER_SDK%\bin\flutter.bat" (
  echo Flutter 3.47.5 SDK not found at "%XIAOQI_FLUTTER_SDK%". 1>&2
  exit /b 1
)
pushd "%~dp0"
call powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\normalize_flutter_plugin_paths.ps1" -ProjectRoot "%~dp0."
call "%XIAOQI_FLUTTER_SDK%\bin\flutter.bat" %*
set "XIAOQI_FLUTTER_EXIT=%ERRORLEVEL%"
call powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\normalize_flutter_plugin_paths.ps1" -ProjectRoot "%~dp0."
popd
exit /b %XIAOQI_FLUTTER_EXIT%
