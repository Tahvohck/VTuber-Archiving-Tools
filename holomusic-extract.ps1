$BootPath = (Get-Item $PSCommandPath).Directory.Fullname
Push-Location $BootPath

$input = "holomusic"
$output = "$input-audio-only"
$skipped = 0
$processed = 0
$ffmpeg = gcm ffmpeg
$dwebp = gcm dwebp

if (!(test-path ./$output)) {
	Write-host -fore Cyan "Creating output directory"
	$null = mkdir $output
}

$FilesToProcess = gci -r $input | ?{ @(".mp4", ".mkv") -contains $_.extension }

$idx = 1
foreach($file in $FilesToProcess){
	$outfile = $file.name -replace $file.extension,".mp3"
	$outdir = $file.Directory.Fullname -replace $input,$output
	$cover = gci ([IO.path]::Combine($file.Directory.fullname, $file.BaseName + "*")) | ?{
		@(".webp", ".jpg", ".png") -contains $_.extension
	}	
	Write-Progress -Activity "Converting files" `
		-Status "$outfile" `
		-PercentComplete ($idx / $FilesToProcess.length * 100)
	$idx += 1
	
	if (!(test-path $outdir)) {
		$newdir = $outdir -replace [regex]::escape($BootPath + "\"),""
		Write-host -fore Cyan "[outdir] $newdir"
		$null = mkdir -force $outdir
	}
	if (![io.file]::exists("$outdir\$outfile")) {
		& $ffmpeg `
			-hide_banner -loglevel warning -nostats `
			-i "$($file.fullname)" `
			"$outdir/$outfile"
		$processed += 1
	} else {
		$skipped += 1
	}
	if ($cover -like "*.webp" -and $dwebp) {
		Push-Location $outdir
		if ([io.file]::exists("$outdir/$($cover.BaseName).png")) {
			pop-location
			continue
		}
		
		Write-host "[cover] Converting webp file $($cover.BaseName)"
		copy-item $cover "./tmp.webp"
		& $dwebp -quiet "./tmp.webp" -o "./tmp.png"
		
		mv tmp.png "$($cover.BaseName).png" -ea SilentlyContinue
		rm tmp.webp
		
		pop-location
	} elseif ($cover -ne $null) {
		copy-item $cover $outdir -ea SilentlyContinue
	}
}

Write-host -Fore Cyan "Finished. Processed/Skipped/Total $processed/$skipped/$($processed + $skipped)"