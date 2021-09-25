Param(
	[Parameter(mandatory=$true, Position=0)]
	[string[]]$channels,
	[switch]$Detailed,
	[switch]$PassThru,
	[DateTime]$StartDate = [DateTime]::MinValue,
	[DateTime]$EndDate = [DateTime]::MaxValue,
	[byte]$MaxThreads = 16
)

# Safety check that user understands what this will do.
$checkfile = "SDWarnAck"
if (!(Test-Path $checkfile)) {
	Write-Host -Fore Red "WARNING: This script downloads files to the current directory."
	Write-Host -Fore Red `
		"If this is not the directory you want to be in, hit ENTER and the script will exit. If it is, type 'yes' and"`
		"hit ENTER, and the script will never ask again for this directory."
	$UserInput = Read-Host "Do you understand"
	if ($UserInput.ToLower() -eq "yes") {
		New-Item -Type File $checkfile | out-null
	} else {
		exit
	}
}

# Setup
$ScriptPath = (Get-Item $PSCommandPath).Directory.Fullname
. "$ScriptPath/common-functions.ps1"
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
$RunspacePool.Open()
$Jobs = @()
$ConsoleJobs = @()


$ScriptblkDownloader = {
	param(
		$VideoID,
		$WorkingPath,
		[switch]$RecentVideo,
		[switch]$Detailed
	)
	Set-Location "$WorkingPath"
	$filename = "donations_$VideoID.json"
	if (Test-Path $filename) { return }
	if ($Detailed) {
		Write-Host "[$VideoID] Downloading new shame log"
	}

	# Download to temporary file, then minify
	python -m chat_downloader -q `
		--message_type paid_message,paid_sticker `
		-o "$filename" "youtu.be/$VideoID"

	if ((Test-Path "$filename") -and ((gi $filename).length -ne 0)) {
		mv $filename "$VideoID.tmp"
		gc "$VideoID.tmp" | python -c 'import json, sys;json.dump(json.load(sys.stdin), sys.stdout)' | Out-File "$filename"
		rm "$VideoID.tmp"
	} else {
		if (!$RecentVideo) { Write-Output "[]" | Out-File "$filename" }

		$DetailedString = "[$VideoID] No log available"
		if ($Detailed -and $RecentVideo) {
			Write-Host "$DetailedString, but video is recent. Not making a blank log."
		} elseif ($Detailed) { Write-Host $DetailedString }
	}
}

$ScriptblkLogger = {
	Param(
		$sender,
		[System.Management.Automation.DataAddedEventArgs]$eventArgs
	)
	$senderAsRecord = [Management.Automation.PSDataCollection[Management.Automation.InformationRecord]]$sender
	$newRecord = $senderAsRecord[$eventArgs.Index]
	if ($null -ne $newRecord) {
		$mData = $newRecord.MessageData
		Write-Host @mData
		$mData
	}
}

$videos_raw = [Collections.ArrayList]::new()
foreach($channel in $channels) {
	$vidCount = 0
	$videos_total = (Get-APIRequest "https://holodex.net/api/v2/channels/$channel").data.video_count
	$channelName  = (Get-APIRequest "https://holodex.net/api/v2/channels/$channel").data.name
	$offset = 0
	$PageSize = 100

	if ($Detailed) { Write-Host "Finding videos for $channelName" }

	while ($offset -lt [Math]::ceiling($videos_total/$PageSize)) {
		if ($Detailed) {
			Write-Host "Downloading page $($offset + 1)/$([Math]::ceiling($videos_total/$PageSize))"
		}
		$tmp = Get-APIRequest "https://holodex.net/api/v2/channels/$channel/videos" -Parameters @{
			limit = $PageSize
			offset = $offset * $PageSize
		}
		$tmp.data | %{
			$null = $videos_raw.Add($_)
			$vidCount += 1
		}
		$offset += 1
	}
	# This is disabled because the standard output would confuse the end user (more videos than expected)
	if ($Detailed -and $false) {
		Write-Host "Found $vidCount/$videos_total"
	}
}

# Get only videos we care about
$videos = $videos_raw | ?{
	$_.status -eq "past" -and
	$_.published_at.ToLocalTime() -gt $StartDate -and
	$_.published_at.ToLocalTime() -lt $EndDate
}
$videos = $videos | Sort-Object -Unique -Property ID | Sort-Object -Property published_at
Remove-Variable videos_raw

if ($PassThru) { $videos }
foreach($video in $videos) {
	$Powershell = [powershell]::Create()
	$Powershell.RunspacePool = $RunspacePool
	$null = $Powershell.AddScript($ScriptblkDownloader).AddParameters(@{
		VideoID = $video.ID
		WorkingPath = $pwd.Path
		Detailed = $Detailed
		RecentVideo = ([datetime]::now - $video.published_at.ToLocalTime()).TotalDays -lt 2
	})
	$Jobs += $Powershell.BeginInvoke()

	$ConsoleJobs += Register-ObjectEvent $Powershell.Streams.Information DataAdded -Action $ScriptblkLogger
}


# Wait for all jobs to be complete
while ($Jobs.IsCompleted -contains $false) {
	if ([Console]::KeyAvailable) {
		$key = [Console]::ReadKey($true)
		$UserQuit = $key.key -eq "Q"
		if ($UserQuit) {
			Write-Host "Exiting..."
			$RunspacePool.Close()
			$RunspacePool.Dispose()
			continue
		}
	}
	Start-sleep 1
}

$ConsoleJobs | Stop-Job -PassThru | Remove-Job
$RunspacePool.Close()
$RunspacePool.Dispose()
