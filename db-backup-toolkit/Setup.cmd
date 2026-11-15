@echo off
title Automating Full Database Backups
rem Double-click (or run) this file. It asks for Administrator rights by itself.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
