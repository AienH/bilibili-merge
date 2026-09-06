# Bilibili Auto Merger - Batch Processing
# Automatically detect and merge all Bilibili cache videos in current directory or subdirectories

param(
    [Parameter(Mandatory=$false)]
    [string]$Path = ".",
    
    [Parameter(Mandatory=$false)]
    [string]$FFmpegPath = "D:\tools\ffmpeg\bin\ffmpeg.exe",
    
    [Parameter(Mandatory=$false)]
    [switch]$Recursive = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$KeepOriginal = $true
)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Bilibili Auto Merger - Batch Mode" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if FFmpeg is available
$ffmpegTest = Get-Command $FFmpegPath -ErrorAction SilentlyContinue
if (-not $ffmpegTest) {
    Write-Host "[ERROR] FFmpeg not found: $FFmpegPath" -ForegroundColor Red
    Write-Host "Please install FFmpeg or specify path with -FFmpegPath" -ForegroundColor Yellow
    exit 1
}

Write-Host "[INFO] FFmpeg: $FFmpegPath" -ForegroundColor Gray
Write-Host "[INFO] Scan path: $Path" -ForegroundColor Gray
Write-Host "[INFO] Recursive: $Recursive" -ForegroundColor Gray
Write-Host ""

# Function: Check m4s file header
function Test-M4sHeader {
    param([string]$FilePath)
    
    try {
        $fs = [System.IO.File]::OpenRead($FilePath)
        $header = New-Object byte[] 32
        $fs.Read($header, 0, 32) | Out-Null
        $fs.Close()
        
        # Check if starts with "000000000" (9 x 0x30)
        $needsFix = ($header[0] -eq 0x30 -and $header[1] -eq 0x30 -and 
                     $header[2] -eq 0x30 -and $header[3] -eq 0x30 -and
                     $header[4] -eq 0x30 -and $header[5] -eq 0x30 -and
                     $header[6] -eq 0x30 -and $header[7] -eq 0x30 -and
                     $header[8] -eq 0x30)
        
        # Find ftyp marker
        $ftypFound = $false
        for ($i = 0; $i -lt 28; $i++) {
            if ($header[$i] -eq 0x66 -and $header[$i+1] -eq 0x74 -and 
                $header[$i+2] -eq 0x79 -and $header[$i+3] -eq 0x70) {
                $ftypFound = $true
                break
            }
        }
        
        return @{
            Valid = $ftypFound
            NeedsFix = $needsFix
            Offset = if ($needsFix) { 9 } else { 0 }
        }
    } catch {
        return @{
            Valid = $false
            NeedsFix = $false
            Offset = 0
        }
    }
}

# Function: Repair m4s file
function Repair-M4sFile {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [int]$Offset
    )
    
    $inputStream = [System.IO.File]::OpenRead($InputFile)
    $outputStream = [System.IO.File]::Create($OutputFile)
    
    if ($Offset -gt 0) {
        $inputStream.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
    }
    
    $inputStream.CopyTo($outputStream)
    $inputStream.Close()
    $outputStream.Close()
}

# Function: Merge video and audio
function Merge-BilibiliVideo {
    param(
        [string]$VideoFile,
        [string]$AudioFile,
        [string]$OutputFile,
        [object]$VideoCheck,
        [object]$AudioCheck
    )
    
    $videoTemp = if ($VideoCheck.NeedsFix) { "video_temp_$(Get-Random).m4s" } else { $VideoFile }
    $audioTemp = if ($AudioCheck.NeedsFix) { "audio_temp_$(Get-Random).m4s" } else { $AudioFile }
    
    try {
        # Repair if needed
        if ($VideoCheck.NeedsFix) {
            Repair-M4sFile $VideoFile $videoTemp $VideoCheck.Offset
        }
        if ($AudioCheck.NeedsFix) {
            Repair-M4sFile $AudioFile $audioTemp $AudioCheck.Offset
        }
        
        # Merge with FFmpeg
        $ffmpegArgs = @(
            "-i", $videoTemp,
            "-i", $audioTemp,
            "-c", "copy",
            "-y",
            $OutputFile
        )
        
        $process = Start-Process -FilePath $FFmpegPath -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru
        
        # Cleanup temp files
        if ($VideoCheck.NeedsFix -and (Test-Path $videoTemp)) {
            Remove-Item $videoTemp -Force
        }
        if ($AudioCheck.NeedsFix -and (Test-Path $audioTemp)) {
            Remove-Item $audioTemp -Force
        }
        
        return $process.ExitCode -eq 0
        
    } catch {
        # Cleanup on error
        if ($VideoCheck.NeedsFix -and (Test-Path $videoTemp)) {
            Remove-Item $videoTemp -Force -ErrorAction SilentlyContinue
        }
        if ($AudioCheck.NeedsFix -and (Test-Path $audioTemp)) {
            Remove-Item $audioTemp -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

# Scan for m4s files
Write-Host "[SCAN] Looking for .m4s files..." -ForegroundColor Yellow

$searchPath = Resolve-Path $Path
$m4sFiles = if ($Recursive) {
    Get-ChildItem -Path $searchPath -Filter "*.m4s" -Recurse -File
} else {
    Get-ChildItem -Path $searchPath -Filter "*.m4s" -File
}

if ($m4sFiles.Count -eq 0) {
    Write-Host "[INFO] No .m4s files found" -ForegroundColor Yellow
    exit 0
}

Write-Host "[FOUND] $($m4sFiles.Count) .m4s files" -ForegroundColor Green
Write-Host ""

# Group files by directory
$filesByDir = $m4sFiles | Group-Object DirectoryName

Write-Host "[DETECT] Analyzing file pairs..." -ForegroundColor Yellow
Write-Host ""

$taskList = @()

foreach ($dirGroup in $filesByDir) {
    $dir = $dirGroup.Name
    $files = $dirGroup.Group
    
    # Try to find video/audio pairs
    # Pattern 1: xxxxx_sr1-xxx.m4s (video) + xxxxx-1-xxx.m4s (audio)
    # Pattern 2: largest file as video + smallest as audio
    
    $videoFiles = @($files | Where-Object { $_.Name -match "_sr1-.*\.m4s$" })
    $audioFiles = @($files | Where-Object { $_.Name -match "-1-\d+\.m4s$" -and $_.Name -notmatch "_sr1-" })
    
    # If patterns don't match, use size-based detection
    if ($videoFiles.Count -eq 0 -or $audioFiles.Count -eq 0) {
        $sorted = $files | Sort-Object Length -Descending
        if ($sorted.Count -ge 2) {
            $videoFiles = @($sorted[0])
            $audioFiles = @($sorted[-1])
        }
    }
    
    # Match video and audio pairs
    for ($i = 0; $i -lt [Math]::Min($videoFiles.Count, $audioFiles.Count); $i++) {
        $video = $videoFiles[$i]
        $audio = $audioFiles[$i]
        
        # Check if files are valid m4s
        $videoCheck = Test-M4sHeader $video.FullName
        $audioCheck = Test-M4sHeader $audio.FullName
        
        if ($videoCheck.Valid -and $audioCheck.Valid) {
            $taskList += @{
                Video = $video.FullName
                Audio = $audio.FullName
                VideoCheck = $videoCheck
                AudioCheck = $audioCheck
                Directory = $dir
            }
        }
    }
}

if ($taskList.Count -eq 0) {
    Write-Host "[INFO] No valid video/audio pairs found" -ForegroundColor Yellow
    exit 0
}

Write-Host "[READY] Found $($taskList.Count) video(s) to process" -ForegroundColor Green
Write-Host ""

# Process each task
$successCount = 0
$failCount = 0

for ($i = 0; $i -lt $taskList.Count; $i++) {
    $task = $taskList[$i]
    $num = $i + 1
    
    Write-Host "[$num/$($taskList.Count)] Processing..." -ForegroundColor Cyan
    
    $videoName = [System.IO.Path]::GetFileName($task.Video)
    $audioName = [System.IO.Path]::GetFileName($task.Audio)
    
    Write-Host "  Video: $videoName" -ForegroundColor Gray
    Write-Host "  Audio: $audioName" -ForegroundColor Gray
    
    # Generate output filename
    $videoBaseName = [System.IO.Path]::GetFileNameWithoutExtension($videoName)
    $outputFile = Join-Path $task.Directory "$videoBaseName.mp4"
    
    # Check if output already exists
    if (Test-Path $outputFile) {
        Write-Host "  [SKIP] Output file already exists: $([System.IO.Path]::GetFileName($outputFile))" -ForegroundColor Yellow
        Write-Host ""
        continue
    }
    
    Write-Host "  Output: $([System.IO.Path]::GetFileName($outputFile))" -ForegroundColor Gray
    
    # Check repair status
    if ($task.VideoCheck.NeedsFix) {
        Write-Host "  [CHECK] Video needs repair (skip 9 bytes)" -ForegroundColor Cyan
    }
    if ($task.AudioCheck.NeedsFix) {
        Write-Host "  [CHECK] Audio needs repair (skip 9 bytes)" -ForegroundColor Cyan
    }
    
    # Merge
    Write-Host "  [MERGE] Starting..." -ForegroundColor Yellow
    
    $success = Merge-BilibiliVideo `
        -VideoFile $task.Video `
        -AudioFile $task.Audio `
        -OutputFile $outputFile `
        -VideoCheck $task.VideoCheck `
        -AudioCheck $task.AudioCheck
    
    if ($success -and (Test-Path $outputFile)) {
        $sizeMB = [math]::Round((Get-Item $outputFile).Length / 1MB, 2)
        Write-Host "  [SUCCESS] $([System.IO.Path]::GetFileName($outputFile)) ($sizeMB MB)" -ForegroundColor Green
        $successCount++
        
        # Delete original files if requested
        if (-not $KeepOriginal) {
            Remove-Item $task.Video -Force -ErrorAction SilentlyContinue
            Remove-Item $task.Audio -Force -ErrorAction SilentlyContinue
            Write-Host "  [CLEANUP] Removed original .m4s files" -ForegroundColor Gray
        }
    } else {
        Write-Host "  [FAIL] Merge failed" -ForegroundColor Red
        $failCount++
    }
    
    Write-Host ""
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "           Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total tasks: $($taskList.Count)" -ForegroundColor Gray
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor Red
Write-Host ""
Write-Host "All done!" -ForegroundColor Green
Write-Host ""
