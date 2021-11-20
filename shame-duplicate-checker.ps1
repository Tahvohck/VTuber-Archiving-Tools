$check = @{};

$donos | %{
	if ($aggr[$_.donator].donations -gt 1) {
		$tstamp = $_.timestamp.Date.ToString("yy\-MM\-dd")

		if ($null -eq $check[$tstamp]) {$check[$tstamp] = @{}}
		if ($null -eq $check[$tstamp][$_.donator]) {
			$check[$tstamp][$_.donator] = [pscustomobject]@{
				Name = $_.donatorName
				ID = $_.donator
				date = $tstamp
				amount = 0
			}
		}
		$check[$tstamp][$_.donator].amount += $_.USD_Equivalent
	}
};

$dailyTotals = foreach($date in $check.GetEnumerator()) {
	$date.Value.GetEnumerator() | %{
		$_.Value.amount = [math]::Round($_.Value.amount)
		[pscustomobject]$_.Value
	}
}
$dailyTotals = $dailyTotals | sort date
$candidates = $dailyTotals | ?{ $_.amount -gt 450 } | sort Name
$ExcludeBits = @(
	"KFP","the","deadbeat","ch.","Lord","husband"
)

foreach($candidate in $candidates) {
	$nameBits = @($candidate.Name.Split(" ") | 
		?{$_ -notin $ExcludeBits } |
		?{$_.Length -gt 2 } | 
		%{ $esc = $_ -replace "\W",""; "*${esc}*"})
	$dailyMatches = $dailyTotals | ?{
		$hasNameBit = $false
		foreach ($bit in $nameBits) {
			$hasNameBit = $hasNameBit -or ($_.name -like $bit)
		}
		$dateMatch = $_.date -eq $candidate.date
		$IDsDiffer = $_.ID -ne $candidate.ID
		$dateMatch -and $hasNameBit -and $IDsDiffer
	}
	if ($dailyMatches.count -gt 0) {
		Write-Host -fore Cyan ("Duplicate candidates for {0} {1} [{2}] [{3}]" -f @(
			$candidate.date
			$candidate.Name
			$candidate.amount
			$candidate.ID
		))
		$dailyMatches | ft -AutoSize ID,@{E={$_.amount};N="USD_Equ"},Name
	}
}
$candidates = $candidates | sort -Unique Name
#$candidates | ft Name,ID