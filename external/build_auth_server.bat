@echo off
REM Build script for Spotify Auth Server
REM Requires: Go compiler installed and in PATH
REM Download Go from: https://golang.org/dl/

echo Checking for Go compiler...
go version >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Go compiler not found in PATH
    echo.
    echo Please install Go from: https://golang.org/dl/
    echo Make sure to add Go to your system PATH
    echo.
    echo After installing Go, run this script again.
    pause
    exit /b 1
)

echo.
echo Building Spotify Auth Server...
echo.

go build -o auth_server.exe -ldflags="-s -w" auth_server.go

if errorlevel 1 (
    echo.
    echo ERROR: Build failed
    echo Please check that auth_server.go is in the same directory
) else (
    echo.
    echo SUCCESS! auth_server.exe created
    echo.
)

pause
