@echo off
title Restore Point Manager
cd /d "%~dp0"
echo Requesting administrator privileges...
powershell -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0RestorePointManager.ps1\"' -Wait"
exit