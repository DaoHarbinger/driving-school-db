@echo off
REM =====================================================================
REM Reinstall driving_school database from install.sql.
REM WARNING: ALL data is reset to the initial test data.
REM Usage: double-click, or "reset_db.bat nopause" from another script.
REM (ASCII only: cmd.exe misreads Cyrillic text inside .bat files)
REM =====================================================================
setlocal
cd /d "%~dp0"

REM --- find mysql.exe: MySQL Server folders in Program Files, then PATH ---
set "MYSQL="
for /d %%D in ("%ProgramFiles%\MySQL\MySQL Server *") do (
    if exist "%%D\bin\mysql.exe" set "MYSQL=%%D\bin\mysql.exe"
)
if not defined MYSQL (
    where mysql >nul 2>&1 && set "MYSQL=mysql"
)
if not defined MYSQL (
    echo [ERROR] mysql.exe not found.
    echo Edit this file and set MYSQL to the full path of mysql.exe.
    if "%~1"=="" pause
    exit /b 1
)
if not exist "install.sql" (
    echo [ERROR] install.sql not found in %cd%
    if "%~1"=="" pause
    exit /b 1
)

echo Using: %MYSQL%
echo Reinstalling database driving_school ...
echo Enter the MySQL root password (characters are not shown):
"%MYSQL%" -u root -p --default-character-set=utf8mb4 < install.sql
if errorlevel 1 (
    echo.
    echo [ERROR] Installation failed - see the message above.
    if "%~1"=="" pause
    exit /b 1
)
echo.
echo Database reinstalled successfully.
if "%~1"=="" pause
exit /b 0
