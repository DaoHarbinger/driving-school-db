@echo off
REM =====================================================================
REM Full backup of driving_school database (Windows)
REM   backup_windows.bat [backup_dir] [keep_days]
REM Schedule daily at 02:30 (run as administrator):
REM   schtasks /create /tn "DrivingSchoolBackup" /sc daily /st 02:30 ^
REM            /tr "C:\driving_school\backup\backup_windows.bat D:\Backups\driving_school 14"
REM Credentials: backup.cnf next to this script (copy of backup.cnf.example).
REM (ASCII only: cmd.exe misreads Cyrillic text inside .bat files)
REM =====================================================================
setlocal

set "MYSQL_BIN=C:\Program Files\MySQL\MySQL Server 8.0\bin"
set "BACKUP_DIR=%~1"
if "%BACKUP_DIR%"=="" set "BACKUP_DIR=%~dp0backups"
set "KEEP_DAYS=%~2"
if "%KEEP_DAYS%"=="" set "KEEP_DAYS=14"
set "CNF=%~dp0backup.cnf"

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "STAMP=%%i"
set "FILE=%BACKUP_DIR%\driving_school_%STAMP%.sql"

if not exist "%CNF%" ( echo [ERROR] %CNF% not found - copy backup.cnf.example to backup.cnf & pause & exit /b 1 )
if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"

echo [%date% %time%] Backup started
"%MYSQL_BIN%\mysqldump.exe" --defaults-extra-file="%CNF%" ^
    --single-transaction --routines --triggers --events ^
    --source-data=2 --set-gtid-purged=OFF --no-tablespaces --hex-blob ^
    --databases driving_school --result-file="%FILE%"
if errorlevel 1 ( echo [ERROR] mysqldump failed & del "%FILE%" 2>nul & pause & exit /b 1 )

REM Check that the dump finished normally
powershell -NoProfile -Command "if ((Get-Content -Tail 1 '%FILE%') -notmatch 'Dump completed') { exit 1 }"
if errorlevel 1 ( echo [ERROR] dump is incomplete & del "%FILE%" & pause & exit /b 1 )

REM Compress and write SHA-256 checksum
powershell -NoProfile -Command "Compress-Archive -Path '%FILE%' -DestinationPath '%FILE%.zip' -Force; Remove-Item '%FILE%'; (Get-FileHash '%FILE%.zip' -Algorithm SHA256).Hash | Out-File '%FILE%.zip.sha256'"
echo [%date% %time%] Done: %FILE%.zip

REM Rotation: delete backups older than KEEP_DAYS days
forfiles /p "%BACKUP_DIR%" /m "driving_school_*.zip*" /d -%KEEP_DAYS% /c "cmd /c del @path & echo   deleted old backup: @file" 2>nul
endlocal
