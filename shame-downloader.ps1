Param(
	[Parameter(mandatory=$true, Position=0)]
	[string[]]$channels,
	[switch]$Detailed,
	[byte]$MaxThreads = 16
)

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
		--message_type paid_message `
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


foreach($channel in $channels) {
	$videos_total = (Get-APIRequest "https://holodex.net/api/v2/channels/$channel").data.video_count
	$videos_raw = [Collections.ArrayList]::new()
	$offset = 0
	$PageSize = 100
	while ($offset -lt [Math]::ceiling($videos_total/$PageSize)) {
		$tmp = Get-APIRequest "https://holodex.net/api/v2/channels/$channel/videos" -Parameters @{
			limit = $PageSize
			offset = $offset
		}
		$tmp.data | %{ $null = $videos_raw.Add($_) }
		$offset += 1
	}
	$videos = $videos_raw | ?{ $_.status -eq "past" }
	$videos = $videos | Sort-Object -Unique -Property ID
	Remove-Variable videos_raw

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
}

# Wait for all jobs to be complete
while ($Jobs.IsCompleted -contains $false) {
	Start-sleep 1
}

$ConsoleJobs | Stop-Job -PassThru | Remove-Job
$RunspacePool.Close()
$RunspacePool.Dispose()