@echo off
chcp 936 >nul
setlocal enabledelayedexpansion

:start
cls
echo.
echo ========================================
echo    Bilibili 视频自动合并工具
echo ========================================
echo.
echo 请选择处理模式：
echo.
echo [1] 当前目录
echo [2] 当前目录（递归所有子文件夹）
echo [3] 指定目录
echo [4] 退出
echo.
set /p choice=请输入选项 (1-4): 

if "%choice%"=="1" goto current
if "%choice%"=="2" goto recursive
if "%choice%"=="3" goto custom
if "%choice%"=="4" goto end
echo 无效选项，请重试
pause
goto start

:current
echo.
echo [模式] 当前目录
echo.
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0bilibili_auto_merge.ps1"
goto done

:recursive
echo.
echo [模式] 当前目录（递归）
echo.
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0bilibili_auto_merge.ps1" -Recursive
goto done

:custom
echo.
set /p targetPath=请输入目录路径: 
if "%targetPath%"=="" (
    echo 路径不能为空
    pause
    goto start
)
echo.
echo [模式] 指定目录: %targetPath%
echo.
set /p recursive_choice=是否递归处理子目录？(Y/N): 
if /i "%recursive_choice%"=="Y" (
    powershell -ExecutionPolicy Bypass -File "%~dp0bilibili_auto_merge.ps1" -Path "%targetPath%" -Recursive
) else (
    powershell -ExecutionPolicy Bypass -File "%~dp0bilibili_auto_merge.ps1" -Path "%targetPath%"
)
goto done

:done
echo.
echo ========================================
echo.
pause
goto end

:end