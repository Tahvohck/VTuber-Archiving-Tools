<#
.SYNOPSIS
	A monitor daemon for automatically downloading livestreams from multiple channels at once.
.DESCRIPTION
	Monitors multiple channels and schedules downloads in the background. Designed to be run as a daemon program.
	Has some basic attempts to restart if a VOD has connection issues, but it's not aggressive: At least 120
	seconds of the VOD will be missing if the connection error is enough to disconnect the downloader.
	Requires the following: youtube-dl OR YT-DLP, 'common-functions.ps1'.
#>
param(
	# An array of channel IDs to search against. https://www.youtube.com/channel/<ChannelID>
	[Parameter(Mandatory=$true, Position=0)]
	[String[]]$ChannelIDs,
	# An optional array of regex filters to apply. Case insensitive.
	[Regex[]]$TitleRegex,

	# Include currently live videos in the search.
	[Switch]$IncludeOngoing,

	# When monitoring, the time in minutes to wait between checks.
	[int]$MonitorWaitTime = 60,
	# When waiting for a video to start, the threshold in minutes before actively checking if the video is live.
	[int]$LeadTime = 5,
	# When actively checking if the video is live, the time in seconds to wait between checks.
	[int]$SecondsBetweenRetries = 15,

	# An alternate youtube-dl config file to use.
	[string]$ConfigPath = "default.cfg",
	# Where to put the downloaded files.
	[string]$OutputPath = ".",
	# If both youtube-dl and YT-DLP are installed, force the use of youtube-dl.
	[Switch]$ForceYTDL,
	# When quitting, return any currently monitored videos to the pipeline.
	[Switch]$PassThru
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
	CommonFunctions = $null
	OutputLocation = $null
}

$commFunc = Get-Command .\common-functions.ps1
if ($null -eq $commFunc) {
	Write-Host -Fore Red "Missing a required library file. Terminating."
	return
}
. $commFunc
$state.CommonFunctions = $commFunc

$ytdl = Get-Command yt-dlp -ea SilentlyContinue
if ($null -eq $ytdl -or $ForceYTDL) {
	if (-not $ForceYTDL) {
		Write-Host -Fore Cyan "Could not find YT-DLP, falling back to YT-DL"
	}
	$ytdl = Get-Command youtube-dl -ea SilentlyContinue
}
if ($null -eq $ytdl) {
	Write-Host -Fore Red "YT-DL could not be found! Make sure it's on the PATH"
	return
}
$state.Downloader = $ytdl

# Do some complex bullshit just to get FQ and normalized URLs
$ConfigFileInfo = if ([IO.Path]::IsPathRooted($ConfigPath)) {
	[IO.FileInfo][IO.Path]::GetFullPath($ConfigPath).Normalize()
} else {
	$ConfigPath = [string]::Join([IO.path]::DirectorySeparatorChar, $pwd, $ConfigPath)
	[IO.FileInfo][IO.Path]::GetFullPath($ConfigPath).Normalize()
}
if (!$ConfigFileInfo.Exists){
	Write-Host -Fore Red "Couldn't find YT-DL config file $ConfigFileInfo"
	return
}
$state.ConfigFileInfo = $ConfigFileInfo

# Same as above, do some complex bullshit just to get FQ and normalized URLs
$OutputPathInfo = if ([IO.Path]::IsPathRooted($OutputPath)) {
	[IO.DirectoryInfo][IO.Path]::GetFullPath($OutputPath).Normalize()
} else {
	$OutputPath = [string]::Join([IO.path]::DirectorySeparatorChar, $pwd, $OutputPath)
	[IO.DirectoryInfo][IO.Path]::GetFullPath($OutputPath).Normalize()
}
if (!$OutputPathInfo.Exists){
	Write-Host -Fore Red "Output path [$OutputPathInfo] doesn't exist. Making it."
	New-Item -ItemType Directory $OutputPathInfo | Out-Null
}
$state.OutputLocation = $OutputPathInfo

if ($null -ne $TitleRegex){
	$TitleRegex = @( foreach($rgx in $TitleRegex){
		[regex]::new($rgx, [text.RegularExpressions.RegexOptions]::IgnoreCase)
	})
}


####################
# Job payload
$WaitAndGetVideo = {
	param($state, $Video)
	. $state.CommonFunctions.Source
	Set-Location $state.OutputLocation
	# Reusable code blocks
	$CB_SetRecheckTime = { [Math]::Min(
		[float]$MaxRecheckTime,
		($Video.start_scheduled.ToLocalTime() - [DateTime]::Now).TotalMinutes / 2
	)}
	$CB_UpdateVideo = {
		$tmp = (Get-APIRequest "https://holodex.net/api/v2/videos/$($Video.ID)")
		if ($tmp.success) {
			$Video = $tmp.data
		} else {
			$EMessage = "Error occured while updating video {0}/{1}"
			Write-Notable ($EMessage -f $Video.Id,$Video.channel.name)
			$Video.status = $null
		}
		Remove-Variable tmp
	}
	# Local variables
	$MaxRecheckTime = 120		# Max recheck time is 2 hours
	$CurrentRecheckPeriod = . $CB_SetRecheckTime
	$LastVideoStartTime = $video.start_scheduled.ToLocalTime()
	$LastCheckTime = [DateTime]::Now

	# Wait for video to be close to starting
	do {
		# If the wait period is up, ask holodex to update us.
		if (([DateTime]::Now - $LastCheckTime).TotalMinutes -gt $CurrentRecheckPeriod) {
			. $CB_UpdateVideo
			# Check to see if the video start time changed
			if ($LastVideoStartTime -lt $Video.start_scheduled.ToLocalTime()) {
				$LastVideoStartTime = $video.start_scheduled.ToLocalTime()
				Write-Host ("Video $($Video.ID)/$($video.channel.name) was delayed." +
							"New start time is $LastVideoStartTime")
			}
			$CurrentRecheckPeriod = . $CB_SetRecheckTime
		}

		$TimeAfterRecheckPeriod = [DateTime]::Now.AddMinutes($CurrentRecheckPeriod)
		$TimeLeadTimeStarts = $LastVideoStartTime.AddMinutes(-$state.LeadTime)

		# If we're on the edge of the lead time wait the remaining time then exit this loop.
		if ($TimeAfterRecheckPeriod -gt $TimeLeadTimeStarts){
			if ([DateTime]::Now.AddSeconds(1) -lt $TimeLeadTimeStarts){
				Start-Sleep ($TimeLeadTimeStarts - [DateTime]::Now).TotalSeconds
			}
			$NotInLeadTime = $false
			continue
		}

		Start-Sleep $state.SecondsBetweenRetries
		$NotInLeadTime = [DateTime]::Now -lt $TimeLeadTimeStarts
	} while ($NotInLeadTime)

	# Begin downloading video
	Write-Notable "Video $($Video.ID)/$($video.channel.english_name) will be starting soon. Switching to hotmonitor."
	$stdout = @()
	$stderr = @()
	$StreamStarted = $false
	$StreamOngoing = $false
	$StreamUrl = "https://youtu.be/$($video.id)"
	Do {
		# Precheck the stream. Manifest file is a fairly reliable way to get the stream status.
		# Hide the error stream, since we don't care about it.
		($manifest = & $state.Downloader --get-URL $StreamUrl) 2>&1 | Out-Null
		$DownloaderSuccess = $?
		if (!$StreamStarted) {
			$StreamStarted = $DownloaderSuccess
		}

		# If manifest download failed for any reason, skip the download step and try again.
		# If we haven't started yet, wait for a bit first.
		if ($DownloaderSuccess) {
			if (!$StreamStarted){
				Start-Sleep $state.SecondsBetweenRetries
			} else {
				Write-Notable "Video [$($Video.ID)/$($video.channel.english_name)] is experiencing connection errors."
			}
			continue
		}

		# Stream is ongoing if:
		# Stream has started AND manifest is a string AND it contains the right words
		$StreamOngoing = $StreamStarted -and ($manifest -is [String]) -and ($manifest -like "*yt_live_broadcast*")
		if (!$StreamOngoing) {
			# Video is done, skip the following download block
			continue
		}

		# Run the downloader, capturing both stdout and stderr.
		$stderr += $(
			$stdout += & $state.Downloader --config-location "$($state.ConfigFileInfo)" $StreamUrl
		) 2>&1
	} while (!$StreamStarted -or $StreamOngoing)
	Write-Host "Video $($Video.ID)/$($video.channel.english_name) has finished downloading."

	# Done downloading video.
	return $Video.id
}


####################
# Channel checks
Write-Notable "Checking channels for validity..."
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
Write-Notable "Warmup done."
Write-Notable ("Monitoring {0} channels in total." -f $channels.Length)
Write-Notable "Checking for new videos every $MonitorWaitTime minutes"
Write-Notable "Transferring to downloader $LeadTime minutes before video is available"
Write-Notable "Output location: $($state.OutputLocation)"
Write-Notable "Downloader program config file: $($state.ConfigFileInfo)"
Write-Notable "Beginning to monitor. Press Q to quit."
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

	$MonitoringJobs.Keys | Where-Object{ $_.HasMoreData } | ForEach-Object{
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
		} | Where-Object { $_.success } | ForEach-Object { $_.data } | Where-Object {
			# Only use requests that succeeded, then discard the wrapper to data only. (lines above)
			# Include live videos if requested. Then remove videos we already know about, and filter
			# on titles if requested.
			($IncludeOngoing -or $_.status -eq "upcoming") -and
			!$MonitoredVideos.Contains($_.id) -and
			$(if ($null -ne $TitleRegex) {
				@($TitleRegex.Match($_.title).Success).Contains($True)
			} else {
				$true	# Pass if no regexes to check against
			})
		}

		# skip if no videos
		if ($videoList.Count -eq 0) { continue }

		Write-Debug "Found $($videoList.Count) new video(s) for channel $($channel.name)"
		foreach ($videoData in $videoList) {
			$videoData.start_scheduled = [DateTime]$videoData.start_scheduled
			$MonitoredVideos[$videoData.id] = $videoData
			Write-Debug "Inserted video: $($videoData.id)"
			Write-HostWithSpacedHeader $videoData.id (Truncate-String $videoData.Title ([Console]::WindowWidth - 30))
			Write-HostWithSpacedHeader "Starts" $videoData.start_scheduled.ToLocalTime()

			$Job = Start-Job $WaitAndGetVideo `
				-ArgumentList $state,$videoData `
				-Name "$($channel.english_name)_$($videoData.id)"
			$MonitoringJobs[$Job] = $videoData.id
		}
	}
} while (!$UserQuit)

$MonitoringJobs.Keys | Stop-Job -PassThru | Remove-Job

if ($PassThru) {
	Write-Notable "User requested videos be returned"
	@($MonitoredVideos.Values.GetEnumerator())
}
