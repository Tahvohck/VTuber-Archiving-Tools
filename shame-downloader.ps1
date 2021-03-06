Param(
	[Parameter(mandatory=$true, Position=0)]
	[string[]]$channels,
	[switch]$Detailed,
	[switch]$PassThru,
	[switch]$UsePyPy,
	[switch]$UseSubDirectoriesForChannels,
	[DateTime]$StartDate = [DateTime]::MinValue,
	[DateTime]$EndDate = [DateTime]::MaxValue,
	[byte]$MaxThreads = 8
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
$Holodex = "https://holodex.net/api/v2"

if ($UsePyPy) {
	$python = get-command pypy3 -ea SilentlyContinue
} else {
	$python = get-command python -ea SilentlyContinue
}
if ($null -eq $python) {
	Write-Host -Fore Red "Unable to find python. Make sure Python is installed and on the PATH"
	Write-Host -Fore Red "In addition, make sure the chat-downloader module is installed."
	exit
}


$ScriptblkDownloader = {
	param(
		$VideoID,
		$WorkingPath,
		$python,
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
	& $python -m chat_downloader -q `
		--message_type paid_message,paid_sticker `
		--inactivity_timeout 300 `
		-o "$filename" "youtu.be/$VideoID"

	if ((Test-Path "$filename") -and ((gi $filename).length -ne 0)) {
		mv $filename "$VideoID.tmp"
		$json = gc "$VideoID.tmp" | ConvertFrom-Json
		$RemovePropList = @(
			'*_colour'
			'time_text'
			'time_in_seconds'
			'action_type'
			'emotes'
			'sticker_images'
			'message'
		)
		$filtered = $json | Select * -ExcludeProperty $RemovePropList | %{
			$_.author = ($_.author | select * -ExcludeProperty images,*colour)
			$_.money = ($_.money | select amount,currency)
			$_
		}
		$filtered | ConvertTo-Json -Depth 10 -Compress | Out-File "$filename"
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
$videosTotalParam = @{
	paginated = $true
	limit = 0
}
foreach($channel in $channels) {
	$vidCount = 0
	$videos_total = (Get-APIRequest "$holodex/channels/$channel/videos" -Parameters $videosTotalParam).data.total
	$channelName  = (Get-APIRequest "$holodex/channels/$channel").data.name
	$offset = 0
	$PageSize = 100

	if ($Detailed) { Write-Host "Finding videos for $channelName" }

	while ($offset -lt [Math]::ceiling($videos_total/$PageSize)) {
		if ($Detailed) {
			Write-Host "Downloading page $($offset + 1)/$([Math]::ceiling($videos_total/$PageSize))"
		}
		$tmp = Get-APIRequest "$holodex/channels/$channel/videos" -Parameters @{
			limit = $PageSize
			offset = $offset * $PageSize
		}
		$tmp.data | %{
			$null = $videos_raw.Add($_)
			$vidCount += 1
		}
		$offset += 1
	}
	if ($Detailed) {
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
	$BlockParam = @{
		VideoID = $video.ID
		WorkingPath = $pwd.Path
		Detailed = $Detailed
		RecentVideo = ([datetime]::now - $video.published_at.ToLocalTime()).TotalDays -lt 2
		python = $python
	}
	if ($UseSubDirectoriesForChannels){
		$BlockParam.WorkingPath += "/$($video.channel.english_name)"
		if (!(Test-Path $BlockParam.WorkingPath)) {
			Write-Notable "Making new directory $($BlockParam.WorkingPath)"
			New-Item -ItemType "Directory" -path $BlockParam.WorkingPath | Out-Null
		}
	}
	$null = $Powershell.AddScript($ScriptblkDownloader).AddParameters($BlockParam)
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
