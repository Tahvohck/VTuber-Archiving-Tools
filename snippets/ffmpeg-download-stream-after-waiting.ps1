param (
	# Stream URL
	[Parameter(Mandatory=1)]$StreamURL,
	# Time to wait between checks prior to stream starting
	[ValidateRange(1,600)]
	[float]$PrestreamSleep = 30,
	# Download streams into segments this big
	[timespan]$SliceSize = "0:1:0",
	$OutputPath = "."
)

$stream_started = $false
$stream_ongoing = $false
$SliceSizeString = $SliceSize.ToString('hh\:mm\:ss')
$UserQuit = $null

# Prepare output directory
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
Push-Location $OutputPathInfo

# Stream download loop
while ((!$stream_started -or $stream_ongoing) -and -not $UserQuit) {
	# Check if user hit any keys
	while ([Console]::KeyAvailable) {
		$key = [Console]::ReadKey($true)
		# User wants to quit if they hit Q
		$UserQuit = $key.key -eq "Q" -or $UserQuit
	}
	# If userquit, acknowledge the quit and skip the rest of the loop
	if ($UserQuit) {
		Write-Host "Exiting..."
		continue
	}
	$manifest = youtube-dl -g $StreamURL
	$YTDL_Success = $?

	# Stream is considered started once:
	# stream was not yet started AND youtube-dl successfully exited (got a manifest)
	if (!$stream_started) {
		$stream_started = $YTDL_Success
	}

	# If manifest download failed for any reason, skip the download step and try again.
	# If we haven't started yet, wait for a bit first.
	if (!$YTDL_Success) {
		if (!$stream_started) {
			#Write-Host "Stream not yet started. Waiting."
			start-sleep $PrestreamSleep
		} else {
			Write-Host "Failed to get manifest"
		}
		continue
	}

	# Stream is ongoing if:
	# Stream has started AND manifest is a string AND it contains the right words
    $stream_ongoing = $stream_started -and ($manifest -is [String]) -and ($manifest -like "*yt_live_broadcast*")
	if (!$stream_ongoing) {
		Write-Host "Stream done. Exiting."
		continue
	}

	Write-Host "Starting downloader."
	ffmpeg -i $manifest `
		-segment_time $SliceSizeString `
		-segment_list "seg_$([datetime]::Now.ToString('MMMdd_HHmmss')).ffconcat" `
		-loglevel repeat+level+warning `
		-f segment -strftime 1 -c copy "output_%b%d-%H%M%S.ts"
	Write-Host "Downloader exited."
}
Get-ChildItem "*.ffconcat"
Pop-Location
