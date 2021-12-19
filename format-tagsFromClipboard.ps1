<#
	.SYNOPSIS
		Take tags from Korotagger output format to a clean comment format
	.DESCRIPTION
		Take tags from clipboard in Korotagger output format and convert them into a format suitable for putting into
		a youtube comment. NOTE: By default each tag is prefixed with the timestamp in seconds and hh:mm:ss format
		for use in easy scrubbing when cleaning up exact timestamps. For example:

		INPUT:
		both of them feel bad at each other 51m48s
		OUTPUT:
		  3105	00:51:45	both of them feel bad at each other

		This can be disabled with the NoSecondsLeader switch.
#>
param(
	# Clamp all tags to the nearest interval of this size in seconds (uses Floor, so tags will always be early rather
	# than late)
	$bucketSize = 5,
	# offset for all tags (in seconds)
	$globalOffset = 0,
	# First line(s) of the tag comment, will be inserted ahead of the tags.
	$HeaderLine = "",
	# Do not prefix each line with a timestamp in seconds (for use in direct posting without pre-cleaning)
	[switch]$NoSecondsLeader,
	# Instead of putting tags back in the clipboard, send them to the console.
	[Alias("WriteToOutput")]
	[switch]$PassThru
)
$lines = Get-Clipboard
$tags = [Collections.ArrayList]::new()

$SplitRegex = [Regex]::new(
	"^(.*?) (?:(\d+)h)?(?:(\d+)m)?(\d+)s",
	[text.regularexpressions.regexoptions]::IgnoreCase
)

foreach ($line in $lines) {
	$null,$tag,$hour,$minute,$second = $SplitRegex.Matches($line).groups.value
	$time = [timespan]("{0}:{1}:{2}" -f @(
		$hour ? $hour : 0
		$minute ? $minute : 0
		$second
	))
	$clampedSeconds = [Math]::Floor(($time.TotalSeconds + $globalOffset) / $bucketSize) * $bucketSize
	$time = [timespan]::new(0,0,$clampedSeconds)
	$tags.Add([pscustomobject]@{time=$time; tag=$tag}) | out-null
}
$tagsClean = [Collections.ArrayList]::new()
if ("" -ne $HeaderLine) {
	$tagsClean.Add($HeaderLine) | out-null
}

$tags | sort time | %{
	if ($NoSecondsLeader) {
		$cleanLine = "{1}`t{2}" -f $_.time.TotalSeconds,$_.time,$_.tag
	} else {
		$cleanLine = "{0,6}`t{1}`t{2}" -f $_.time.TotalSeconds,$_.time,$_.tag
	}
	$tagsClean.add($cleanLine) | out-null
}

if ($PassThru) {
	Write-Output $tagsClean
} else {
	$tagsClean | set-clipboard
}
