@echo off
REM Driving school IS - web UI launcher for Windows.
REM (ASCII only: cmd.exe misreads Cyrillic text inside .bat files)
cd /d "%~dp0"

set "PY="
python --version >nul 2>&1 && set "PY=python"
if not defined PY ( py -3 --version >nul 2>&1 && set "PY=py -3" )
if not defined PY (
    echo.
    echo [ERROR] Python not found.
    echo Install Python 3.10+ from https://www.python.org/downloads/
    echo and tick "Add python.exe to PATH" on the first installer screen.
    echo.
    pause
    exit /b 1
)
%PY% --version

REM --- optional database reinstall (default: No after 10 seconds) ---
echo.
choice /c YN /n /t 10 /d N /m "Reinstall database? ALL data will be reset. [Y/N, default N in 10 s]: "
if errorlevel 2 goto start_ui
call "%~dp0..\reset_db.bat" nopause
cd /d "%~dp0"

:start_ui
echo.
echo Installing libraries (first run may take a minute)...
%PY% -m pip install -q -r requirements.txt
if errorlevel 1 (
    echo.
    echo [ERROR] Could not install libraries. Check the Internet connection.
    pause
    exit /b 1
)

echo.
echo Web UI: http://127.0.0.1:5000
echo To stop the server close this window or press Ctrl+C
echo.
start "" /b cmd /c "timeout /t 3 >nul & start http://127.0.0.1:5000"
%PY% app.py

echo.
echo Server stopped. If there is an error message above, send it.
pause
