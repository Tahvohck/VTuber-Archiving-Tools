$stream_URL = "https://youtu.be/8FuWq6kG_CE"
$stream_started = $false
$stream_ongoing = $false
$SliceSize = [timespan]::new(0,1,0).ToString('hh\:mm\:ss')
$PrestreamSleep = 30
$UserQuit = $null
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
	$manifest = youtube-dl -g $stream_URL
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

	Write-Host "Trying to download"
	ffmpeg -i $manifest `
		-segment_time $SliceSize `
		-segment_list "seg_$([datetime]::Now.ToString('MMMdd_HHmmss')).ffconcat" `
		-loglevel repeat+level+warning `
		-f segment -strftime 1 -c copy "output_%H%M%S.ts"
}