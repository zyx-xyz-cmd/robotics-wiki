
@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ==========================
echo   Robotics Wiki Update
echo ==========================

echo.
echo [1/3] Adding changed files...
git add -A
if errorlevel 1 goto error

echo.
echo [2/3] Committing changes...
git diff --cached --quiet
if errorlevel 2 goto error
if errorlevel 1 (
    git commit -m "Update robotics notes"
    if errorlevel 1 goto error
) else (
    echo No new changes to commit.
)

echo.
echo [3/3] Pushing to GitHub...
git -c http.version=HTTP/1.1 push origin v4
if errorlevel 1 goto error

echo.
echo ==========================
echo   GitHub Update Successful!
echo ==========================
echo Cloudflare will deploy automatically.
pause
exit /b 0

:error
echo.
echo Update failed. Check the error above.
pause
exit /b 1
