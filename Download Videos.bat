@echo off
setlocal
set VRCLM_FROM_BAT=1
title VRChat Link Maker - download
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0VRChatLinkMaker.ps1" --download %*
if errorlevel 1 (
  echo.
  echo The tool stopped. If there is an error message above, that is what went wrong.
  pause
)
