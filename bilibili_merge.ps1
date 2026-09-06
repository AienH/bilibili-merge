# Bilibili Cache Video Merger
# Automatically detect, repair and merge Bilibili downloaded m4s files

param(
    [Parameter(Mandatory=$true)]
    [string]$VideoFile,
    
    [Parameter(Mandatory=$true)]
    [string]$AudioFile,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "output.mp4",
    
    [Parameter(Mandatory=$false)]
    [string]$FFmpegPath = "D:\tools\ffmpeg\bin\ffmpeg.exe"
)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Bilibili Video Merger" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if files exist
if (-not (Test-Path $VideoFile)) {
    Write-Host "[ERROR] Video file not found: $VideoFile" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $AudioFile)) {
    Write-Host "[ERROR] Audio file not found: $AudioFile" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Video file: $VideoFile" -ForegroundColor Gray
Write-Host "[INFO] Audio file: $AudioFile" -ForegroundColor Gray
Write-Host ""

# Function: Check m4s file header and determine if repair is needed
function Test-M4sHeader {
    param([string]$FilePath)
    
    $fs = [System.IO.File]::OpenRead($FilePath)
    $header = New-Object byte[] 32
    $fs.Read($header, 0, 32) | Out-Null
    $fs.Close()
    
    # Display first 16 bytes as hex
    $hex = ($header[0..15] | ForEach-Object { $_.ToString("X2") }) -join " "
    
    # Check if starts with "000000000" (9 x 0x30)
    $needsFix = ($header[0] -eq 0x30 -and $header[1] -eq 0x30 -and 
                 $header[2] -eq 0x30 -and $header[3] -eq 0x30 -and
                 $header[4] -eq 0x30 -and $header[5] -eq 0x30 -and
                 $header[6] -eq 0x30 -and $header[7] -eq 0x30 -and
                 $header[8] -eq 0x30)
    
    # Find ftyp marker position (search first 28 bytes)
    $ftypFound = $false
    $ftypOffset = -1
    for ($i = 0; $i -lt 28; $i++) {
        if ($header[$i] -eq 0x66 -and $header[$i+1] -eq 0x74 -and 
            $header[$i+2] -eq 0x79 -and $header[$i+3] -eq 0x70) {
            $ftypFound = $true
            $ftypOffset = $i
            break
        }
    }
    
    return @{
        NeedsFix = $needsFix
        FtypFound = $ftypFound
        FtypOffset = $ftypOffset
        Offset = if ($needsFix) { 9 } else { 0 }
        HeaderHex = $hex
    }
}

# Function: Repair m4s file (skip invalid header)
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

# Step 1: Check video file
Write-Host "[1/5] Checking video file header..." -ForegroundColor Yellow
$videoCheck = Test-M4sHeader $VideoFile
Write-Host "      Hex: $($videoCheck.HeaderHex)" -ForegroundColor Gray

if (-not $videoCheck.FtypFound) {
    Write-Host "      [FAIL] 'ftyp' marker not found, file may be corrupted" -ForegroundColor Red
    exit 1
}

if ($videoCheck.NeedsFix) {
    Write-Host "      [DETECT] Needs repair (skip first $($videoCheck.Offset) bytes)" -ForegroundColor Cyan
} else {
    Write-Host "      [OK] Standard format, no repair needed" -ForegroundColor Green
}

# Step 2: Check audio file
Write-Host "[2/5] Checking audio file header..." -ForegroundColor Yellow
$audioCheck = Test-M4sHeader $AudioFile
Write-Host "      Hex: $($audioCheck.HeaderHex)" -ForegroundColor Gray

if (-not $audioCheck.FtypFound) {
    Write-Host "      [FAIL] 'ftyp' marker not found, file may be corrupted" -ForegroundColor Red
    exit 1
}

if ($audioCheck.NeedsFix) {
    Write-Host "      [DETECT] Needs repair (skip first $($audioCheck.Offset) bytes)" -ForegroundColor Cyan
} else {
    Write-Host "      [OK] Standard format, no repair needed" -ForegroundColor Green
}

# Step 3: Repair files
Write-Host "[3/5] Repairing files..." -ForegroundColor Yellow
$videoTemp = "video_temp.m4s"
$audioTemp = "audio_temp.m4s"

if ($videoCheck.NeedsFix) {
    Write-Host "      Repairing video stream..." -ForegroundColor Gray
    Repair-M4sFile $VideoFile $videoTemp $videoCheck.Offset
    Write-Host "      [DONE] Video repaired -> $videoTemp" -ForegroundColor Green
} else {
    $videoTemp = $VideoFile
    Write-Host "      [SKIP] Video file needs no repair" -ForegroundColor Gray
}

if ($audioCheck.NeedsFix) {
    Write-Host "      Repairing audio stream..." -ForegroundColor Gray
    Repair-M4sFile $AudioFile $audioTemp $audioCheck.Offset
    Write-Host "      [DONE] Audio repaired -> $audioTemp" -ForegroundColor Green
} else {
    $audioTemp = $AudioFile
    Write-Host "      [SKIP] Audio file needs no repair" -ForegroundColor Gray
}

# Step 4: FFmpeg merge
Write-Host "[4/5] Merging with FFmpeg..." -ForegroundColor Yellow

# Check if FFmpeg is available
$ffmpegTest = Get-Command $FFmpegPath -ErrorAction SilentlyContinue
if (-not $ffmpegTest) {
    Write-Host "      [ERROR] FFmpeg not found: $FFmpegPath" -ForegroundColor Red
    Write-Host "      Please install FFmpeg or specify correct path, e.g.:" -ForegroundColor Yellow
    Write-Host "      -FFmpegPath 'D:\tools\ffmpeg\bin\ffmpeg.exe'" -ForegroundColor Yellow
    
    # Cleanup temp files
    if ($videoCheck.NeedsFix -and (Test-Path $videoTemp)) {
        Remove-Item $videoTemp -ErrorAction SilentlyContinue
    }
    if ($audioCheck.NeedsFix -and (Test-Path $audioTemp)) {
        Remove-Item $audioTemp -ErrorAction SilentlyContinue
    }
    
    exit 1
}

Write-Host "      FFmpeg: $FFmpegPath" -ForegroundColor Gray

$ffmpegArgs = @(
    "-i", $videoTemp,
    "-i", $audioTemp,
    "-c", "copy",
    "-y",
    $OutputFile
)

try {
    $process = Start-Process -FilePath $FFmpegPath -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru
    
    # Step 5: Check result
    Write-Host "[5/5] Verifying result..." -ForegroundColor Yellow
    
    if ($process.ExitCode -eq 0 -and (Test-Path $OutputFile)) {
        $outputInfo = Get-Item $OutputFile
        $sizeMB = [math]::Round($outputInfo.Length / 1MB, 2)
        
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "         Merge Successful!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Output file: $OutputFile" -ForegroundColor Cyan
        Write-Host "File size: $sizeMB MB" -ForegroundColor Cyan
        Write-Host "Created: $($outputInfo.LastWriteTime)" -ForegroundColor Cyan
        Write-Host ""
        
    } else {
        Write-Host ""
        Write-Host "[FAIL] FFmpeg returned error code: $($process.ExitCode)" -ForegroundColor Red
        Write-Host "Please check if files are corrupted or format is unsupported" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    
} catch {
    Write-Host ""
    Write-Host "[EXCEPTION] Merge process error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# Cleanup temp files
if ($videoCheck.NeedsFix -and (Test-Path $videoTemp)) {
    Remove-Item $videoTemp -ErrorAction SilentlyContinue
    Write-Host "[CLEANUP] Removed temp file: $videoTemp" -ForegroundColor Gray
}
if ($audioCheck.NeedsFix -and (Test-Path $audioTemp)) {
    Remove-Item $audioTemp -ErrorAction SilentlyContinue
    Write-Host "[CLEANUP] Removed temp file: $audioTemp" -ForegroundColor Gray
}

Write-Host ""
Write-Host "All done!" -ForegroundColor Green
Write-Host ""
