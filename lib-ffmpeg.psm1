#verion info
$major="4"
$minor="0"

#debug flag
$debug = $false

#ffmpeg pathS
$ffmpegRoot = "C:\ffmpeg\"

enum OutputTags {
    TagNtd
    TagInf
    TagErr
    TagWrn
    TagPrc
    TagAct
    TagHdr
    TagUsr
    TagOvr
}

function Get-TimeStamp {

    return "{0:MM/dd/yy} {0:HH:mm:ss} .. " -f (Get-Date)

}

function Get-TagString {

    Param (
        [OutputTags]$Tag
    )

    switch ($Tag) {
        TagInf { return "Info......" }
        TagWrn { return "Warning..." }
        TagErr { return "Error....." }
        TagPrc { return "Processing" }
        TagOvr { return "Oversize.." }
        TagUsr { return "Input....." }
        TagHdr { return "Executing." }
        TagAct { return "Action...." }
        TagNtd { return "Note......" }
    }
}

function Write-User {

    Param (
        [string]$Text,
        [OutputTags]$Tag
    )
    $updateLog = $true #everything logged by default
    $oTag = Get-TagString $Tag
    
    $oText = "[$oTag] $Text"

    Switch ($Tag) {
        TagInf {
            Write-Host $oText -ForegroundColor Cyan
            break
        }
        TagWrn {
            Write-Host $oText -ForegroundColor DarkRed
            $global:CountWarnings += 1
            break
        }
        TagErr {
            Write-Host $oText -ForegroundColor Red
            $global:CountErrors += 1
            break
        }
        TagPrc {
            Write-Host $oText -ForegroundColor Green
            break
        }
        TagOvr {
            Write-Host $oText -ForegroundColor Blue
            break
        }
        TagUsr {
            $updateLog = $false #no need to log user menu choices
            Write-Host $oText -ForegroundColor White
            break
        }
        TagHdr {
            Write-Host ("-" * $oText.length) -ForegroundColor Magenta
            Write-Host $oText -ForegroundColor Magenta
            Write-Host ("-" * $oText.length) -ForegroundColor Magenta
            break
        }
        TagAct {
            Write-Host $oText -ForegroundColor Yellow
            break
        }
        TagNtd {
            $updateLog = $false #no need to log notes
            Write-Host $oText -ForegroundColor Gray
            break
        }
    }

    if ($updateLog) {
        Add-Content "_lib-ffmpeg.log" -value ((Get-TimeStamp) + "|" + ($oTag).Trim(".") + "|" + $Text)
    }
}

function Get-Bitrate {
    #returns bit rates based on height
    Param (
        [int]$height
    )

    switch($height) {
        {$_ -le 240}{
            $l = 350 * 1024
            $u = 700 * 1024
            break
        }
        {$_ -le 360} {
            $l = 450 * 1024
            $u = 900 * 1024
            break
        }
        {$_ -le 480}{
            $l = 650 * 1024
            $u = 1200 * 1024
            break
        }
        #anything above 480 will default to 800k/1600k
        default {
            $l = 800 * 1024
            $u = 1600 * 1024
        }
    }
    $bitrate = @{
        lower=$l
        upper=$u   
    }
    return $bitrate
}

function Test-File {
#test if a file exists and is not empty, returns true if valid, false if not
    Param (
        [string]$File
    )
    $validFile = try {
        Test-Path -Path $File
        $true
    } catch {
        Write-User "File '$File' does not exist." TagErr
        $false
    }
    if ($validFile) {
        $validFile = (Get-Item -Path $File).Length -gt 0
    }
    return $validFile
}

function Move-MP4 {
#delete original file and copy old file back to original location
    Param (
        [string]$inFile,
        [string]$outFile
    )

    
    if (Test-File -File $outFile) {
        #if new file valid, delete original  
        Write-User "Valid MP4 Created. Force deleting '$inFile'." TagPrc
        $fileDeleted = try {
            Remove-Item -Path "$($inFile)" -Force -ErrorAction Stop
            Write-User "Delete of '$inFile' successful." TagInf
            $true
        } catch {
            Write-User "Failed to delete file '$inFile'." TagErr
            if ($debug) {
                Write-User "Error Details: $($_.Exception.Message)" TagNtd
            }
            $false
        }
    } else {
        Write-User "MP4 Creation Failed. '$inFile' retained." TagErr
    }
    if ($fileDeleted -eq $true) {
        #if old file was deleted, move new file to original location
        Write-User "Moving '$outFile' to original location." TagPrc
        try {
            Move-Item -Path "$($outFile)" -Destination "$(Split-Path -Path $inFile -Parent)" -Force -ErrorAction Stop
            Write-User "Move of '$outFile' successful." TagInf
        } catch {
            Write-User "Failed to move file '$outFile' to original location." TagErr
            if ($debug) {
                Write-User "Error Details: $($_.Exception.Message)" TagNtd
            }
        }
    }   
}

function Invoke-FFmpeg {
#call ffmpeg with the provided arguments a duration, executes ffmpeg with a progress bar
    Param (
        [string]$FFMpeg_args,
        [double]$Duration
    )

    # setup the process start info for ffmpeg
    $ffmpegProc = New-Object System.Diagnostics.ProcessStartInfo
    $ffmpegProc.FileName = "ffmpeg.exe"

    # Use -hide_banner and -loglevel info for a cleaner output that's easier to parse
    $ffmpegProc.Arguments = $FFmpeg_args -join " "
    $ffmpegProc.UseShellExecute = $false
    $ffmpegProc.RedirectStandardError = $true
    $ffmpegProc.RedirectStandardOutput = $true
    $ffmpegProc.CreateNoWindow = $true

    # start the process
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $ffmpegProc
    [void]$process.Start()

    if ($debug) {
        write-user "FFmpeg Arguments: $($FFmpeg_args -join ' ')" TagNtd
        write-user "Video Duration: $($Duration) seconds" TagNtd
        Write-User "FFmpeg process started with PID: $($process.Id)" TagNtd
    }

    # read the output in real-time and update progress
    while (-not $process.HasExited) {
        # Read a line from stderr (FFmpeg progress output goes to stderr)
        $line = $process.StandardError.ReadLine()

        if ($line -match "frame=\s*(?<frame>\d+).*?time=\s*(?<time>[\d:\.]+).*?speed=\s*(?<speed>[\d\.]+)x") {
            # parse the 'time' field from the output (format is HH:MM:SS.ms)
            $timeMatch = $Matches['time']
            # convert to seconds for percentage calculation
            $timeParts = $timeMatch -split ':'
            $hours = [int]$timeParts[0]
            $minutes = [int]$timeParts[1]
            $seconds = [double]::Parse($timeParts[2], [cultureinfo]::InvariantCulture)
            $currentSeconds = ($hours * 3600) + ($minutes * 60) + $seconds

            # calculate percentage
            if ($Duration -gt 0) {
                $percentage = ($currentSeconds / $Duration) * 100
                
                # Update the PowerShell progress bar
                Write-Progress -Activity "FFmpeg Processing" -Status "Time: $timeMatch, Speed: $($Matches['speed'])x" -PercentComplete $percentage
            }
        }
    }

    # Ensure the process is fully closed
    $process.WaitForExit()
    # Hide the progress bar on completion
    Write-Progress -Activity "FFmpeg Processing: $inputFile" -Status "Completed" -PercentComplete 100 -Completed
}

function Get-FileList {
   
#retrieve file directory listing and output to text file

    [CmdletBinding()]
    param (
        [string]$Path = "",
        [switch]$Recurse
    )

    if ($Recurse) {
        Write-User "Retrieving media file list recursively" Tagprc
        return (Get-ChildItem -Path $Path -Recurse -File | Select-Object -ExpandProperty FullName) | Sort-Object
    } else {
        Write-User "Retrieving media file list" Tagprc
        return (Get-ChildItem -Path $Path -File | Select-Object -ExpandProperty FullName) | Sort-Object
    }
    
}

function Join-Media {

    [CmdletBinding()]
    param (
        [string]$List = "_dir.txt",
        [string]$Concat = "_concat.txt",
        [string]$Output = "output"
    )

    Write-User "Joining Media Files" TagHdr
    Write-User "File List:" TagInf
    
    $cList = @()
    $Files = @(Get-Content $List)
    for ($i=0; $i -lt $Files.count; $i++) {
        $filePath = $Files[$i]
        $fileExt = Split-Path -Path $filePath -Extension
        if (Test-File -File $filePath) {
            Write-User "Adding $($i+1) of $($Files.Count) '$($filePath)'" TagPrc
            if ($fileExt.ToLower() -eq ".mp4") {
                $cList += "file '$filePath'" 
            } else {
                Write-User "File: '$fileName' is not in MP4 format. Skipping." TagInf
            }
        } else {
            Write-User "File: '$filePath' does not exist or is empty. Skipping." TagErr
            continue
        }
               
    }
    #output concat list
    $cList | Out-File -Encoding utf8NoBOM -FilePath $Concat
    #output file path
    $outFile = $ffmpegRoot + $Output + ".mp4"

    #setup ffmpeg args
    $ffmpeg_args = @(
        "-f", "concat",
        "-safe", "0",
        "-i", $Concat,
        "-c", "copy",
        "$outFile"
    )

    Write-User "Concatenating to '$outFile'" TagPrc
    #make it so 
    & ffmpeg @ffmpeg_args
    if (Test-File -File $outFile) {
        Write-User "Concatenation Complete. Output file: '$outFile'" TagPrc
    } else {
        Write-User "Concatenation Failed. Output file: '$outFile' not created." TagErr
    }
}

function Convert-ToMP4 {
<#
    .SYNOPSIS
        Converts various video formats to MP4 using FFmpeg.

    .DESCRIPTION
        Converts video files in the specified path to MP4 format using FFmpeg. Supports various input formats such as AVI, MKV, MOV, WMV, M4V, FLV, WEBM, and DIVX. The function can process files recursively and provides options for system behavior after conversion.

    .PARAMETER Path
        The directory path containing video files to convert.

    .PARAMETER Recurse
        Indicates whether to process files in subdirectories.

    .PARAMETER Quit
        Determines the system behavior after conversion. Accepts "p" to prompt, "s" to shutdown, and "x" to exit PowerShell. Default is "p".

    .EXAMPLE
        Convert-ToMP4 -Path "C:\Videos" -Recurse -Quit "s"
        
        Converts all supported video files in "C:\Videos" and its subdirectories to MP4 format and shuts down the system after completion.
        
    .NOTES
        Author: rolytnz
        Date: September 17, 2026
#>
    [CmdletBinding()]
    param (
        [string]$Path = "",
        [switch]$Recurse,
        [string]$Quit = "p"  # p = prompt, s = shutdown, x = exit powershell
    )

    Write-User "Converting other formats to MP4 in path '$($Path)'" TagHdr

    switch($Quit) {
        "p" { Write-User "System will remain on when complete" TagWrn }
        "s" { Write-User "System will shutdown when complete" TagWrn }
        "x" { Write-User "System will exit Powershell when complete" TagWrn }
    }

    $List = Get-Filelist -Path $Path -Recurse:$Recurse

    #output file array of non-MP4 files
    $outList = @()
    foreach ($File in $List) {
        $fileExt = Split-Path -Path $File -Extension
        if ($fileExt.ToLower() -in ".avi",".mkv",".mov",".wmv", ".m4v", ".flv", ".webm",".divx") {
            $outList += $File
        }
    }

    Write-User "Files to convert to MP4: $($outList.Count)" TagInf

    foreach ($File in $outList) {
        $fileName = Split-Path -Path $File -Leaf
        $fileExt = Split-Path -Path $File -Extension
        Write-User "Converting '$($fileName)'." TagInf

        #get duration of source file using ffprobe
        $ffprobeArgs = @(
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "format=duration",
            "-of", "json",
            "$File"
        )
        $ffprobe = (& ffprobe @ffprobeArgs) | ConvertFrom-Json
        
        $outFile = $ffmpegRoot + "$($fileName.Substring(0, $fileName.Length - $fileExt.Length))" + ".mp4"
        $ffmpegArgs = @(
                "-i", "`"$File`"",
                "-c:", "copy",
                "-c:v", "libx264",
                "-crf", "23",
                "-c:a", "aac",
                "`"$outFile`""
            )
        #make it so
        Invoke-FFmpeg -FFmpeg_args $ffmpegArgs -Duration $([double]$ffprobe.format.duration)
        #cleanup
        Move-MP4 -inFile $File -outFile $outFile
    }

    switch($Quit) {
        "p" {
            break
        }
        "s" {
            Write-User "Computer Will shutdown in 30 seconds." TagWrn
            Start-Sleep -Seconds 30
            Stop-Computer -ComputerName localhost
        }
        "x" { 
            Write-User "Exiting Powershell Session in five seconds." TagWrn
            Start-Sleep -Seconds 5
            Exit
        }  
    }    
}

function Optimize-MP4 {
<#
    .SYNOPSIS
        Retrieves a list of MP4 files in the specified path and checks their height and bitrate against optimal values.

    .DESCRIPTION
        Retrieves a list of MP4 files in the specified path and checks their height and bitrate against optimal values and saves the list of files that exceed these values to a sorted text file. The function can process files recursively.

    .PARAMETER Outfile
        The name of the output file where the list of sub-optimal files will be saved. Default is "_dir.txt".

    .PARAMETER Path
        The directory path containing MP4 files to check.

    .PARAMETER Height
        The optimal height value to compare against. Files exceeding this height will be flagged.

    .PARAMETER Recurse
        Specifies whether to process files recursively in subdirectories.

    .EXAMPLE
        Optimize-MP4 -Outfile "sub_optimal_files.txt" -Path "C:\Videos" -Height 540 -Recurse

        Checks all MP4 files in "C:\Videos" and its subdirectories for height exceeding 540 pixels and saves the list of sub-optimal files to "sub_optimal_files.txt".

    .NOTES
        Author: rolytnz
        Date: September 17, 2026
#>

    [CmdletBinding()]
    param (
        [string]$Outfile = "_dir.txt",
        [string]$Path = "",
        [string]$Height = 540,
        [switch]$Recurse
    )

    Write-User "Path  : '$Path'" TagInf
    Write-User "Output: '$Outfile'" TagInf

    $List = Get-FileList -Path $Path -Recurse:$Recurse

    #output file array
    $Output = @()
    #counters for files above height and bitrate limits
    $countHeight = 0
    $countBitrate = 0
    foreach ($File in $List) {
        if ((Split-Path -Path $File -Extension) -eq ".mp4") {
            #get video info using ffprobe
            $ffprobeArgs = @(
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=height,bit_rate:format=duration",
                "-of", "json",
                "$($File)"
            )
            if ($debug) {
                Write-User "ffprobe arguments: $($ffprobeArgs)" TagNtd
            }
            $ffprobe = (& ffprobe @ffprobeArgs) | ConvertFrom-Json

            if ($debug) {
                Write-User "File: '$File'" TagInf
                Write-User "Height: $($ffprobe.streams[0].height)" TagInf
                Write-User "Video: $([int]($ffprobe.streams[0].bit_rate))" TagInf
            }

            #check height is under limit and count up sub-optimal files
            $outFlag = $false
            if(([int]$ffprobe.streams[0].height) -gt $Height){
                Write-User "File '$File' is above the optimal height. Added to list for resizing." TagOvr
                $outFlag = $true
                $countHeight += 1
            } else {
                $bitrate = Get-Bitrate -Height $fileHeight
                #check bitrate is under upper limit
                if ([int]($ffprobe.streams[0].bit_rate) -gt $bitrate.upper) {
                    Write-User "File '$File' is above the optimal bitrate of $([math]::Round($bitrate.upper/1KB,2))KB. Added to list for re-encoding." TagOvr
                    $outFlag = $true
                    $countBitrate += 1
                }
            }
            if ($outFlag) {
                $Output += $File
            }
        }
    }   
    $Output | Out-File -Encoding utf8 -FilePath "$Outfile" -Force
    Write-User "Files To Optimize    : $($Output.Count)" TagInf
    Write-User "Above optimal height : $countHeight" TagInf
    Write-User "Above optimal bitrate: $countBitrate" TagInf
}

function Resize-MP4 {
<#
    .SYNOPSIS
        Resizes MP4 files based on a provided list, trimming and adjusting height as specified.

    .DESCRIPTION
        Resizes MP4 files based on a provided list, trimming and adjusting height as specified. The function can mark original files as resized or replace them with the resized versions. It also provides options for system behavior after resizing.

    .PARAMETER List
        The name of the text file containing the list of MP4 files to resize. Default is "_dir.txt".

    .PARAMETER Trim
        The time to trim from the start of the video in hh:mm:ss format. Default is "00:00:00".

    .PARAMETER Height
        The target height for resizing the video and should match the same as used when calling Optimize-MP4. Default is 540 pixels.

    .PARAMETER Action
        Specifies the action to take on the original files after resizing. Accepts "m" to mark the original files as resized or "r" to replace the original files with the resized versions. Default is "r" (replace original).

    .PARAMETER Quit
        Determines the system behavior after resizing. Accepts "p" to prompt, "s" to shutdown, and "x" to exit PowerShell. Default is "p".

    .EXAMPLE
        Resize-MP4 -List "_dir.txt" -Trim "00:00:10" -Height 480 -Action "m" -Quit "s"
        
        Resizes the MP4 files listed in "_dir.txt", trimming the first 10 seconds, adjusting the height to 480 pixels, marking the original files as resized, and shutting down the system after completion.    

    .NOTES
        Author: rolytnz
        Date: September 17, 2026
#>
    [CmdletBinding()]
    param (
        [string]$List= "_dir.txt",
        [string]$Trim = "00:00:00",
        [string]$Height = 540,
        [string]$Action = "r", # m = mark original as resized, r = replace original
        [string]$Quit = "p", # p = prompt, s = shutdown, x = exit powershell
        [string]$Item = ""
    )

    Write-User "Resizing media files" TagHdr
    switch ($Action) {
        "m" {
             Write-User "Original files will be marked" TagAct
             break
        }
        "r" {
            Write-User "Original Files will be replaced" TagAct
            break
        }
    }

    if ($Trim -ne "00:00:00") {
        Write-User "Trimming to $Trim" TagInf
    }

    switch($Quit) {
        "p" { Write-User "System will remain on when complete" TagWrn }
        "s" { Write-User "System will shutdown when complete" TagWrn }
        "x" { Write-User "System will exit Powershell when complete" TagWrn }
    }
   
    $Files = @(Get-Content $List)
    
    $spaceBefore = 0
    $spaceAfter = 0
  
    for ($i=0; $i -lt $Files.count; $i++) {
        $filePath = $Files[$i]
        $fileName = Split-Path -Path $filePath -Leaf
        Write-User "Processing $($i+1) of $($Files.Count) '$($filePath)'" TagPrc

        $oldSize = [math]::Round((Get-Item -Path $filePath).Length / 1MB,2)
        Write-User "Original File Size: $oldSize MB" TagInf
        $spaceBefore += $oldSize
        
        #get video height
        $ffprobe_args = @(
            "-v", "error",
            "-show_streams",
            "-show_entries", "stream=height:format=duration",
            "-of", "json",
            "$($filePath)"
        )

        #get file info using ffprobe
        $ffprobe = (& ffprobe @ffprobe_args) | ConvertFrom-Json
        $fileHeight = [int]$ffprobe.streams[0].height
        $fileDuration = [double]$ffprobe.format.duration
                    
        #set new audio bitrate, if the original is less than 96k, retain the original, otherwise down to 96k
        $br = "96k"
        Write-User "Audio bitrate set to: $br" TagNtd

        #output file path
        $outFile = $ffmpegRoot + $fileName

        #if target height is less than the file height, set new height to target, otherwise retain original height
        if ($fileheight -gt $Height) {
            $newHeight = $Height
        } else {
            $newHeight = $fileHeight
        }
        #set the video bitrate based on the target height
        $bitRate = Get-Bitrate -height $newHeight
        $bv = "$([math]::Round($bitRate.lower / 1024))k"
        $mr = "$([math]::Round($bitRate.upper / 1024))k"
        Write-User "Video bitrate set to: $bv; Maximum:$mr" TagNtd

        #setup ffmpeg args
        $ffmpeg_args = @(
            "-i", "`"$($filePath)`"",
            "-filter:v", "fps=30",
            "-vsync", "cfr",
            "-ss", $Trim,
            "-vf", "scale=-2:$([string]$newHeight),setsar=1",
            "-maxrate", $mr,
            "-c:v", "h264_nvenc",
            "-b:v", $bv,
            "-c:a", "copy",
            "-b:a", $br,
            "-pix_fmt", "yuv420p",
            "-r", "30",
            "`"$outFile`""
        )
        #make it so
        Invoke-FFmpeg -FFmpeg_args $ffmpeg_args -Duration $fileDuration
    
        #update storage size info
        $newSize = [math]::Round((Get-Item -Path $outFile).Length / 1MB,2)
        Write-User "New File Size: $newSize MB" TagInf
        $spaceAfter += $newSize

        #execute action
        switch($Action) {
            "m" { #mark resized
                Rename-Item -Path "$filePath" -NewName "(RESIZED) $(Split-Path -Path $filePath -Leaf)"
                if($?) {
                    Write-User "Original file renamed"
                } else {
                    Write-User "Error renaming original file" TagErr    
                }
                break
            }
            "r" { #replace original
                Move-MP4 -inFile $filePath -outFile $outFile
            }
        }
    }

    Write-User "Resizing Complete" TagPrc
    Write-User "Total Size Before   : $spaceBefore MB" TagInf
    Write-User "Total Size After    : $spaceAfter MB" TagInf
    write-User "Total Size Reduction: $($spaceBefore - $spaceAfter) MB" TagInf  

    switch($Quit) {
        "p" {
            break
        }
        "s" {
            Write-User "Computer Will shutdown in 30 seconds." TagWrn
            Start-Sleep -Seconds 30
            Stop-Computer -ComputerName localhost
        }
        "x" { 
            Write-User "Exiting Powershell Session in five seconds." TagWrn
            Start-Sleep -Seconds 5
            Exit
        }  
    }
}

#module exports
Export-ModuleMember -Function Join-Media, Resize-MP4, Update-MediaList, Optimize-MP4, Convert-ToMP4

#inform the user that the module has been loaded and list the available functions
Write-Host "Roly's FFmpeg (v$($major).$($minor)) Tools Loaded" -ForegroundColor Green
Write-Host "Functions:" -ForegroundColor Cyan
Write-Host "    Join-Media -List <file> -Concat <file> -Output <file (no extension needed)>" -ForegroundColor Cyan
Write-Host "    Convert-ToMP4 -Path <path> -Recurse -Quit <p|s|x>" -ForegroundColor Cyan
Write-Host "    Optimize-MP4 -Outfile <file> -Path <path> -Height <height> -Recurse" -ForegroundColor Cyan
Write-Host "    Resize-MP4 -List <file> -Trim <time> -Height <height> -Action <m|r> -Quit <p|s|x>" -ForegroundColor Cyan
Write-Host ""
