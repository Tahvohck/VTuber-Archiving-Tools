param(
	# The channel ID to search against. https://www.youtube.com/channel/<ChannelID>
	[Parameter(Mandatory=$true, Position=0)]
	[String[]]$ChannelIDs,
	[Regex[]]$TitleRegex,

	# Include currently live videos in the search.
	[Switch]$IncludeOngoing,

	# When monitoring, the time in minutes to wait between checks.
	[int]$MonitorWaitTime = 60,
	# When waiting for a video to start, the threshold in minutes before actively checking if the video is live.
	[int]$LeadTime = 5,
	# When actively checking if the video is live, the time in seconds to wait between checks.
	[int]$SecondsBetweenRetries = 15,

	# An alternate youtube-dl config file to use. Must be a relative path.
	[string]$ConfigPath = "default.cfg",
	# If both youtube-dl and YT-DLP are installed, force the use of youtube-dl.
	[Switch]$ForceYTDL
)


####################
# Internal functions
function Monitor-Channel {
	param([String]$channel)
}

function WaitFor-Video {
	param([String]$videoID)
}

function Download-Video {
	param([String]$videoID)
}


####################
# Prechecks/Warmup
$ScriptPath = (Get-Item $PSCommandPath).Directory.Fullname
Push-Location $ScriptPath

$commFunc = gcm .\common-functions.ps1
if ($commFunc -eq $null) {
	Write-Host -Fore Red "Missing a required library file. Terminating."
	return
}
. $commFunc

$ytdl = gcm yt-dlp -ea SilentlyContinue
if ($ytdl -eq $null -or $ForceYTDL) {
	if (-not $ForceYTDL) {
		Write-Host -Fore Cyan "Could not find YT-DLP, falling back to YT-DL"
	}
	$ytdl = gcm youtube-dl -ea SilentlyContinue
}
if ($ytdl -eq $null) {
	Write-Host -Fore Red "YT-DL could not be found! Make sure it's on the PATH"
	return
}

$ConfigFileInfo = [IO.FileInfo][IO.Path]::Combine($pwd, $ConfigPath)
if (!$ConfigFileInfo.Exists){
	Write-Host -Fore Red "Couldn't find YT-DL config file $ConfigFileInfo"
	return
}

$channels = foreach ($CID in ($ChannelIDs | Get-Unique)) {
	$chanData = Get-APIRequest -Quiet "https://holodex.net/api/v2/channels/$CID"
	if (!$chanData.success) {
		if ($chanData.data.Message -ne $null) {
			Write-Host -Fore Red "$CID`: $($chanData.data.Message)"
		} else {
			Write-Host -Fore Red "$CID`: $($chanData.error.Message)"
		}
		continue
	}
	Write-Host "Found channel to monitor: $($chanData.data.name)"
	$chanData.data
}


####################
# Main loop
Write-Host "Beginning to monitor. Press Q to quit."
$LastChannelCheckTime = [DateTime]::new(0)
$MonitoredVideos = @{}
$MaxMonitoredVideosBeforeCulling = $channels.Count * 4
$MonitoringJobs = [Collections.ArrayList]::new()
Write-Debug "Capping monitored videos at $MaxMonitoredVideosBeforeCulling"
do {
	# Check if user requested quit
	if ([Console]::KeyAvailable) {
		$key = [Console]::ReadKey($true)
		$UserQuit = $key.key -eq "Q"
		if ($UserQuit) {
			Write-Host "Exiting..."
			continue
		}
	}

	$MonitoringJobs | ?{ $_.HasMoreData } | %{
		Receive-Job | Write-Host
	}

	# If it hasn't been enough time, skip this loop iteration
	if (([DateTime]::Now - $LastChannelCheckTime).TotalMinutes -lt $MonitorWaitTime) { continue }
	$LastChannelCheckTime = [DateTime]::Now
	Write-Debug "Checking $($channels.Count) channels at $LastChannelCheckTime"

	# Check channels
	foreach ($channel in $channels) {
		# Get all videos. Skip any failed requests. Extract data from wrapper
		$videoList = Get-APIRequest "https://holodex.net/api/v2/live" -Parameters @{
			status = "live,upcoming"
			channel_id = $channel.id
		} | Where-Object {
			# Only use requests that succeeded and remove live if not requested
			$_.success -and
			($IncludeOngoing -or $_.data.status -eq "upcoming")
		} | ForEach-Object {
			# Don't need the wrapper anymore, discard to data only
			$_.data
		} | Where-Object {
			# Remove videos we already know about, and filter on titles if requested
			!$MonitoredVideos.Contains($_.id) -and
			@($TitleRegex.Match($_.title).Success).Contains($True)
		}

		# skip if no videos
		if ($videoList.Count -eq 0) { continue }

		Write-Debug "Found $($videoList.Count) new video(s) for channel $($channel.name)"
		foreach ($videoData in $videoList) {
			if ($MonitoredVideos.Contains($videoData.id)) { continue }
			$MonitoredVideos[$videoData.id] = $videoData
			Write-Debug "Inserted video: $($videoData.id)"
			Write-HostWithSpacedHeader $videoData.id (Truncate-String $videoData.Title ([Console]::WindowWidth - 30))
			Write-HostWithSpacedHeader "Starts" $videoData.start_scheduled.ToLocalTime()
		}
	}
} while (!$UserQuit)
