@echo off
setlocal
set "XIAOQI_FLUTTER_SDK=%USERPROFILE%\develop\flutter-3.47.5\flutter"
set "PUB_CACHE=%LOCALAPPDATA%\Pub\CacheD"
for /f "tokens=1,2" %%A in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\resolve_flutter_local_proxy.ps1"') do call :set_flutter_proxy %%A %%B
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

:set_flutter_proxy
set "HTTP_PROXY=http://%~1:%~2"
set "HTTPS_PROXY=http://%~1:%~2"
if defined JAVA_TOOL_OPTIONS (
  set "JAVA_TOOL_OPTIONS=%JAVA_TOOL_OPTIONS% -Dhttp.proxyHost=%~1 -Dhttp.proxyPort=%~2 -Dhttps.proxyHost=%~1 -Dhttps.proxyPort=%~2"
) else (
  set "JAVA_TOOL_OPTIONS=-Dhttp.proxyHost=%~1 -Dhttp.proxyPort=%~2 -Dhttps.proxyHost=%~1 -Dhttps.proxyPort=%~2"
)
exit /b 0
