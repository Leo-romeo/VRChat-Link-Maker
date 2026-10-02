@echo off
setlocal
title VRChat Link Maker
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0VRChatLinkMaker.ps1" %*
if errorlevel 1 (
  echo.
  echo The tool stopped. If there is an error message above, that is what went wrong.
  pause
)
