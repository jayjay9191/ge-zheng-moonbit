
@echo off
setlocal
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo Requires Node.js 22.3 or later. The HTML report opens without Node.js.
  pause
  exit /b 1
)
where python >nul 2>nul
if errorlevel 1 (
  echo Requires Python 3.10 or later for the independent verification.
  pause
  exit /b 1
)
python -X utf8 scripts\replay.py
if errorlevel 1 (
  pause
  exit /b 1
)
python -X utf8 scripts\render_report.py
if errorlevel 1 (
  pause
  exit /b 1
)
python -X utf8 scripts\replay_land.py
if errorlevel 1 (
  pause
  exit /b 1
)
python -X utf8 scripts\render_land.py
if errorlevel 1 (
  pause
  exit /b 1
)
for %%F in ("%~dp0*.html") do start "" "%%~fF"
pause

