$check = @{};

$donos | %{
	if ($aggr[$_.donator].donations -gt 1) {
		$tstamp = $_.timestamp.Date.ToString("yy\-MM\-dd")
		$wstamp = "{0:yyyy}W{1}" -f @(
			$_.timestamp.Date
			[System.Globalization.ISOWeek]::GetWeekOfYear($_.timestamp.Date)
		)

		if ($null -eq $check[$tstamp]) {$check[$tstamp] = @{}}
		if ($null -eq $check[$tstamp][$_.donator]) {
			$check[$tstamp][$_.donator] = [pscustomobject]@{
				Name = $_.donatorName
				ID = $_.donator
				TimeWindow = $tstamp
				amount = 0
			}
		}
		$check[$tstamp][$_.donator].amount += $_.USD_Equivalent
		
		if ($null -eq $check[$wstamp]) {$check[$wstamp] = @{}}
		if ($null -eq $check[$wstamp][$_.donator]) {
			$check[$wstamp][$_.donator] = [pscustomobject]@{
				Name = $_.donatorName
				ID = $_.donator
				TimeWindow = $wstamp
				amount = 0
			}
		}
		$check[$wstamp][$_.donator].amount += $_.USD_Equivalent
	}
};

$candidates = foreach($date in $check.GetEnumerator()) {
	$date.Value.GetEnumerator() | ?{
		$dailyLimit = $_.Value.amount -gt 450 #-and $_.Value.TimeWindow -like "*-*"
		$weeklyLimit = $_.Value.amount -gt 1500 -and $_.Value.TimeWindow -like "*W*"
		$dailyLimit -or $weeklyLimit
	} | %{
		[pscustomobject]$_.Value
	}
}

$ExcludeBits = @(
	"KFP","the","deadbeat","ch.","Lord","husband"
)
foreach($candidate in $candidates) {
	$nameBits = @($candidate.Name.Split(" ") | 
		?{$_ -notin $ExcludeBits } |
		?{$_.Length -gt 2 } | 
		%{ $esc = $_ -replace "\W",""; "*${esc}*"})
	$TimeWindowMatches = $check[$candidate.TimeWindow].GetEnumerator() | ?{
		$hasNameBit = $false
		foreach ($bit in $nameBits) {
			$hasNameBit = $hasNameBit -or ($_.Value.name -like $bit)
		}
		$IDsDiffer = $_.Value.ID -ne $candidate.ID
		$hasNameBit -and $IDsDiffer -and $_.Value.amount -gt 10
	} | Select-Object -ExpandProperty Value
	if ($TimeWindowMatches.count -gt 0) {
		Write-Host -fore Cyan ("Duplicate candidates for {0} {1} [{2}] [{3}]" -f @(
			$candidate.TimeWindow
			$candidate.Name
			[Math]::Round($candidate.amount,2)
			$candidate.ID
		))
		$TimeWindowMatches | ft -AutoSize ID,@{E={[math]::Round($_.amount)};N="USD_Equ"},Name
	}
}
$candidates = $candidates | sort -Unique Name
#$candidates | ft Name,ID