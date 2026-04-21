@echo off
REM ============================================================
REM  Retro Rewind Movie Workshop — Build Executable
REM  Run this script from the same folder as RR_VHS_Tool.py
REM ============================================================

echo.
echo ========================================
echo   Retro Rewind Movie Workshop — Building Executable
echo ========================================
echo.

REM Check Python
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python not found. Install Python 3.10+ from python.org
    pause
    exit /b 1
)

REM Install/upgrade build dependencies
echo [1/4] Installing build dependencies...
pip install --upgrade pyinstaller pillow >nul 2>&1
if errorlevel 1 (
    echo ERROR: Failed to install dependencies.
    pause
    exit /b 1
)

REM Check that the script exists
if not exist "RR_VHS_Tool.py" (
    echo ERROR: RR_VHS_Tool.py not found in current directory.
    echo Place this build script next to RR_VHS_Tool.py
    pause
    exit /b 1
)

REM Clean previous build
echo [2/4] Cleaning previous build...
if exist "dist\RR_Movie_Workshop" rmdir /s /q "dist\RR_Movie_Workshop"
if exist "build\RR_Movie_Workshop" rmdir /s /q "build\RR_Movie_Workshop"

REM Build
echo [3/4] Building executable (this takes 1-2 minutes)...
python -m PyInstaller RR_Movie_Workshop.spec --noconfirm

if errorlevel 1 (
    echo.
    echo ERROR: Build failed. Check the output above for details.
    pause
    exit /b 1
)

REM Package all distribution files
echo [4/4] Packaging distribution files...

REM Create tools subfolder and copy modding tools
if not exist "dist\RR_Movie_Workshop\tools" mkdir "dist\RR_Movie_Workshop\tools"
if exist "repak.exe" (
    copy "repak.exe" "dist\RR_Movie_Workshop\tools\" >nul
    echo   + tools\repak.exe
) else (
    echo   ! WARNING: repak.exe not found — add it manually
)
if exist "texconv.exe" (
    copy "texconv.exe" "dist\RR_Movie_Workshop\tools\" >nul
    echo   + tools\texconv.exe
) else (
    echo   ! WARNING: texconv.exe not found — add it manually
)

REM Copy license files
if not exist "dist\RR_Movie_Workshop\LICENSES" mkdir "dist\RR_Movie_Workshop\LICENSES"
if exist "LICENSES" (
    xcopy "LICENSES\*" "dist\RR_Movie_Workshop\LICENSES\" /s /q >nul 2>&1
    echo   + LICENSES\
)
if exist "LICENSE" (
    copy "LICENSE" "dist\RR_Movie_Workshop\LICENSES\RR_Movie_Workshop-LICENSE" >nul
    echo   + LICENSES\RR_Movie_Workshop-LICENSE
)

REM Copy README
if exist "README.txt" (
    copy "README.txt" "dist\RR_Movie_Workshop\" >nul
    echo   + README.txt
)

echo.
echo ========================================
echo   BUILD COMPLETE — Ready to zip!
echo ========================================
echo.
echo Output: dist\RR_Movie_Workshop\
echo.
echo Contents:
echo   RR_Movie_Workshop.exe
echo   README.txt
echo   tools\repak.exe
echo   tools\texconv.exe
echo   LICENSES\
echo   _internal\
echo.
echo Just zip the dist\RR_Movie_Workshop folder and upload to Nexus Mods.
echo.
pause
