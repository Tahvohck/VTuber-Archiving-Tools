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
# Prechecks/Warmup
$ScriptPath = (Get-Item $PSCommandPath).Directory.Fullname
Push-Location $ScriptPath
$state = @{
	LeadTime = $LeadTime
	SecondsBetweenRetries = $SecondsBetweenRetries
	Downloader = $null
	ConfigFileInfo = $null
}

$commFunc = gcm .\common-functions.ps1
if ($null -eq $commFunc) {
	Write-Host -Fore Red "Missing a required library file. Terminating."
	return
}
. $commFunc

$ytdl = gcm yt-dlp -ea SilentlyContinue
if ($null -eq $ytdl -or $ForceYTDL) {
	if (-not $ForceYTDL) {
		Write-Host -Fore Cyan "Could not find YT-DLP, falling back to YT-DL"
	}
	$ytdl = gcm youtube-dl -ea SilentlyContinue
}
if ($null -eq $ytdl) {
	Write-Host -Fore Red "YT-DL could not be found! Make sure it's on the PATH"
	return
}
$state.Downloader = $ytdl

$ConfigFileInfo = [IO.FileInfo][IO.Path]::Combine($pwd, $ConfigPath)
if (!$ConfigFileInfo.Exists){
	Write-Host -Fore Red "Couldn't find YT-DL config file $ConfigFileInfo"
	return
}
$state.ConfigFileInfo = $ConfigFileInfo


####################
# Job payload
$WaitAndGetVideo = {
	param($state, $Video)
	sleep 30
	# Wait for video to start

	# Begin downloading video

	# Done downloading video.
	return $Video.id
}


####################
# Channel checks
$channels = @(foreach ($CID in ($ChannelIDs | Get-Unique)) {
	$chanData = Get-APIRequest -Quiet "https://holodex.net/api/v2/channels/$CID"
	if (!$chanData.success) {
		if ($null -ne $chanData.data.Message) {
			Write-Host -Fore Red "$CID`: $($chanData.data.Message)"
		} else {
			Write-Host -Fore Red "$CID`: $($chanData.error.Message)"
		}
		continue
	}
	Write-Host "Found channel to monitor: $($chanData.data.name)"
	$chanData.data
})

if ($channels.Length -eq 0) {
	Write-Host -Fore Red "No valid channels to monitor. Double-check your ChannelIDs list."
	return
}


####################
# Main loop
Write-Host "Beginning to monitor. Press Q to quit."
$LastChannelCheckTime = [DateTime]::new(0)
$MonitoredVideos = @{}
$MaxMonitoredVideosBeforeCulling = $channels.Count * 4
$MonitoringJobs = @{}
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

	$MonitoringJobs | Where-Object{ $_.HasMoreData } | ForEach-Object{
		# This will allow the underlying script block to return any console output
		# while capturing actual returned values.
		$JobVideoID = Receive-Job $_
		# Unlinked if statements, sometimes the completion and the video ID return
		# don't happen on the same cycle. As it's the last statement in the script
		# block though, handling them on separate cycles is fine.
		if ($null -ne $JobVideoID) {
			$MonitoredVideos.Remove($JobVideoID)
		}
		if ($_.state -eq "Completed") {
			$MonitoringJobs.Remove($_)
			Remove-Job $_
		}
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
			$MonitoredVideos[$videoData.id] = $videoData
			Write-Debug "Inserted video: $($videoData.id)"
			Write-HostWithSpacedHeader $videoData.id (Truncate-String $videoData.Title ([Console]::WindowWidth - 30))
			Write-HostWithSpacedHeader "Starts" $videoData.start_scheduled.ToLocalTime()

			$Job = Start-Job $WaitAndGetVideo `
				-ArgumentList $state,$videoData `
				-InitializationScript {. .\common-functions.ps1} `
				-Name "$($channel.english_name)_$($videoData.id)"
			$MonitoringJobs[$Job] = $videoData.id
		}
	}
} while (!$UserQuit)
