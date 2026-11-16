@echo off
REM Run the dedicated SpaceMMO server headless on Windows.
REM Set GODOT to your Godot executable, e.g.  set GODOT=C:\Godot\Godot_v4.3-stable_win64_console.exe
if "%GODOT%"=="" set GODOT=godot
cd /d "%~dp0"
if not exist .godot "%GODOT%" --headless --path . --import
"%GODOT%" --headless --path . -- --server --data ./server_data %*
