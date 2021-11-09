Param(
	$FinalCurrency = "JPY",
	[switch]$ShowTopDonators,
	[switch]$ShowTopCurrencies,
	[switch]$Anonymize,
	[switch]$HideTopAmounts,
	$DonationDirectory,
	[ValidateRange(1, [Int]::MaxValue)]
	[int]$LeaderboardSize = 5,
	[ValidateRange(1, [Int]::MaxValue)]
	[int]$RegularDonatorThreshold = 10,
	[DateTime]$StartDate = [DateTime]::MinValue,
	[DateTime]$EndDate = [DateTime]::MaxValue,
	[ValidateRange(0,1)]
	[float]$EstimatedCompanyCut = -1,
	[switch]$KeepYTIDKeys,
	[switch]$TestConversion,
	[switch]$PassThru,
	$ExtraAltsMatrix
)
$ScriptPath = (Get-Item $PSCommandPath).Directory.Fullname
. "$ScriptPath/common-functions.ps1"

# Globals
$Conversions = @{}
$AggregateDonations = @{}
$AggregateCurrencies = @{}
$donation_list = [Collections.ArrayList]::new() 
$donators = [Collections.ArrayList]::new()
$regularDonators = [Collections.ArrayList]::new()

$FirstDonoDate = [DateTime]::MaxValue
$LastDonoDate = [DateTime]::MinValue
$TotalIncomeToDate = 0
$NumberOfStreams = 0
$NumberOfMonetizedStreams = 0
$ConversionREST = "https://free-currency-converter.herokuapp.com/list/convert?source={0}&destination={1}"
$FinalCurrency = $FinalCurrency.ToUpper()

$AltsMatrix = [collections.arraylist]@(
	@(	# Simulanze
		"UCDCHb-nyY8DXox9TIobHdSQ","UCM0Jyw5uzzq2bfIrALIimGg","UCw2kiianOn1uHm1rXiDOfOw","UC2vD9YRQsG6HI1ogconz9zw",
		"UCZPhNzwpn4GXw9yHBmzZIvQ"
	),
	@(	# Wall-E
		"UC1yTFaabaq5xARIKiRc-Gxg","UCvy_H0tph_D0s8WfyMOXrOw","UCLUbKlAUlLQSELFPjSOZ4aA"
	),
	@(	# Bucket
		"UCKPR6yTobtggJLU8x1Fd9Zg","UCbAYBuoexzkLjCSDXCmOlpw"
	),
	@(	# LC_Lapen
		"UC9RB4WfKOeqXVpqu-WW9xsw","UC-w49_y6xgAKbb2H9oEj3cw"
	),
	@(	# Lord Revan (High likelyhood alts only)
		"UCpVx-y2HTqen1d6pTIfzcDA","UCwKVhK4VC2AYqFgMOq-i2gg"
	),
	@(	# Takashi隆
		"UCjbfykBMumMtRGGLqs03tlQ","UC6FNWcOx1CWtvrgGVvEXjDQ","UCxhXozeebjyi3Rf4Bw2zpLA","UCb76m56_aJCpZBbaux87TsA"
	),
	@(	# Some dude on Botan's streams
		"UC_j2MhWR7RLDsM1FOZygV6g","UCqxApYhQx3FcH5QjjfzOI5w","UC7M3MYrlix9zfoIlmCItLCQ"
	)
)
if ($null -ne $ExtraAltsMatrix) {
	if ($ExtraAltsMatrix[0][0].GetType() -eq [char]) {
		Write-Host "Buffering EAM"
		$tmp = [Collections.ArrayList]::new()
		$tmp.Add(@($ExtraAltsMatrix)) | Out-Null
		$ExtraAltsMatrix = $tmp
	}
	if ($ExtraAltsMatrix[0][0].GetType() -ne [String] -or $ExtraAltsMatrix[0].Count -lt 2)  {
		Write-Host -Fore Red "ExtraAltsMatrix must be a matrix of YTID strings. Each inner array is a list of equivalent alts."
		Write-Host -Fore Red 'If you only have one list of alts, you can specify the matrix as @($AltArray,@())'
		Exit
	}
	foreach($altArray in $ExtraAltsMatrix) {
		if ($altArray.Count -eq 0) { continue } #Skip empties
		$AltsMatrix.Add($altArray) | Out-Null
	}
}

# Get exchange data
$ConversionsRaw = Invoke-RestMethod "http://free-currency-converter.herokuapp.com/list?source=$FinalCurrency"
if (!$ConversionsRaw.success) {
	Write-Host -Fore Red "Currency [$FinalCurrency] not supported by currency conversion API"
	Exit
} else {
	foreach($conversion in $ConversionsRaw.currency_values){
		$Conversions[$conversion.name] = 1 / $conversion.value
	}
}

# Set up and start stopwatch
$StopWatch = [Diagnostics.StopWatch]::New()
$StopWatch.Start()
# Read data files
try {
	if ($null -ne $DonationDirectory) {
		push-location $DonationDirectory -ea Stop
		Write-Host -Fore Cyan "Reading donations from $DonationDirectory"
		$logs = get-childItem donations*.json
		pop-location
	} else {
		Write-Host -Fore Cyan "Reading donations"
		$logs = get-childItem donations*.json
	}
} catch {
	Write-Host -Fore Red "Could not move to donation directory. Exiting."
	exit
}
foreach ($log in $logs) {
	$LogHasADono = $false
	$json = get-content $log | convertfrom-json
	foreach($message in $json) {
		$LogHasADono = $true
		$donation = @{
			donator =		$message.author.id
			donatorName =	$message.author.name
			currency =		$message.money.currency -replace "₱","PHP"
			amount =		$message.money.amount
			timestamp = [datetimeoffset]::FromUnixTimeMilliseconds($message.timestamp/1000).LocalDateTime
			USD_Equivalent = 0
		}
		$donation["USD_Equivalent"] = $donation.amount * $Conversions[$donation.currency] / $Conversions['USD']
		
		if ($donation.timestamp -lt $StartDate -or $donation.timestamp -gt $EndDate) { continue }
		if ($ShowTopCurrencies) {
			if ($donation.currency -notin $AggregateCurrencies.Keys) {
				$AggregateCurrencies[$donation.currency] = [pscustomobject]@{
					count = 1
					amount = 0
				}
			} else {
				$AggregateCurrencies[$donation.currency].count += 1
			}
		}

		# Do some fixups here for known alts
		$donator = "$($donation.donator)"
		foreach ($altList in $AltsMatrix) {
			# Alt found, don't need to keep looking, set current donator ID to first alt for proper combination
			if($donator -in $altList) { $donator = $altList[0]; break }
		}
		$donation.donator = $donator


		if (!$donators.Contains($donation.donator)) {
			$null = $donators.Add($donation.donator)
			#$AggregateDonations[$donation.donator] = @{}
		}
		$null = $donation_list.Add([pscustomobject]$donation)
		if ($donation.timestamp -gt $LastDonoDate) { $LastDonoDate = $donation.timestamp }
		if ($donation.timestamp -lt $FirstDonoDate) { $FirstDonoDate = $donation.timestamp }
	}
	$NumberOfStreams += 1
	if ($LogHasADono) {
		$NumberOfMonetizedStreams += 1
	}
}

$NumberOfDonations = $donation_list.Count
if ($NumberOfDonations -eq 0) {
	Write-Host -Fore Red "Couldn't find any donations between $StartDate and $EndDate"
	Exit
}


# Aggregate data
Write-Host -Fore Cyan ("Aggregating Donations ({0:n0} total, {1:n0} streams)" -f $NumberOfDonations,$NumberOfStreams)
foreach($donation in $donation_list) {
	$donator = "$($donation.donator)"

	if($null -eq $AggregateDonations[$donator]) {
		$AggregateDonations[$donator] = @{}
		$AggregateDonations[$donator]['money'] = @{}
		$AggregateDonations[$donator]['nameList'] = @{}
		$AggregateDonations[$donator].earliest = [DateTime]::MaxValue
		$AggregateDonations[$donator].last = [DateTime]::MinValue

		if (!$donators.Contains($donator)){ $null = $donators.add($donator) }
	}

	$AggregateDonations[$donator].money[$donation.currency] += $donation.amount
	$AggregateDonations[$donator].donations += 1
	$AggregateDonations[$donator].nameList[$donation.donatorName] += 1
	if ($donation.timestamp -lt $AggregateDonations[$donator].earliest) {
		$AggregateDonations[$donator].earliest = $donation.timestamp
	}
	if ($donation.timestamp -gt $AggregateDonations[$donator].last) {
		$AggregateDonations[$donator].last = $donation.timestamp
	}
}

Write-Host -Fore Cyan "Eliminating duplicate data that crept in"
$ADK = $AggregateDonations.Keys
$donators = $donators | sort -unique | ?{ $_ -in $ADK }
Write-Host -Fore Cyan "Doing conversions to $FinalCurrency"
foreach($donator in $donators) {
	$donator_stats = $AggregateDonations[$donator]
	foreach($currency in @($donator_stats.money.Keys)) {
		if ($currency -eq $FinalCurrency) {
			$yen = $donator_stats.money[$currency]
		} else {
			$yen = $donator_stats.money[$currency] * $Conversions[$currency]
			if ($TestConversion -and $donator -eq "Simulanze") {
				Write-Host ("Convert {0,10:n} {1} -> {2,10:n2} $FinalCurrency`t[{3,8:F3}]" -f 
					$donator_stats.money[$currency],
					$currency,
					$yen,
					$Conversions[$currency] )
			}
		}
		$donator_stats["TOTAL"] += [Math]::Round($yen, 3)
		$TotalIncomeToDate += $yen
		if ($ShowTopCurrencies) {
			$AggregateCurrencies[$currency].amount += $yen
		}
	}
}

Write-Host -Fore Cyan "Gathering metrics"
foreach($donator in $donators) {
	$donator_stats = $AggregateDonations[$donator]
	$donator_stats["average"] = "{0:n2}" -f ($donator_stats["TOTAL"] / $donator_stats["donations"])
	$days = [Math]::Max(1, ($donator_stats["last"].Date -  $donator_stats["earliest"].Date).TotalDays)
	$donator_stats["PerDayAmount"] = [Math]::Round($donator_stats["TOTAL"] / $days, 3)
	$donator_stats["PerDayCount"] = [Math]::Round($donator_stats["donations"] / $days, 3)
	$donator_stats["Name"] = $donator_stats.nameList.GetEnumerator() |
		Sort -Descending {$_.Value} |
		Select -First 1 -ExpandProperty Key
	if ($AggregateDonations[$donator].donations -ge $RegularDonatorThreshold) {
		# Don't need to do a presence check since we already filtered donators to uniques
		$regularDonators.Add($donator) | Out-Null
	}
	if ($KeepYTIDKeys) {
		$AggregateDonations[$donator] = [pscustomobject]$donator_stats
	} else {
		# Store the updated stats file and remove the YT ID key entry
		$AggregateDonations[$donator_stats.Name] = [pscustomobject]$donator_stats
		$AggregateDonations.Remove($donator)
	}
}

# Stop Stopwatch
$StopWatch.Stop()
# Display final info
Write-Host ("{0,10:mm\:ss} M:S`tTime taken to process data" -f $StopWatch.Elapsed)
Write-Host ("{0,10:n0} {1}`tTotal to date" -f $TotalIncomeToDate,$FinalCurrency)
Write-Host ("{0,10:n2} {1}`tAverage donation" -f ($TotalIncomeToDate / $NumberOfDonations),$FinalCurrency)
$DonoDaysRange = [Math]::Max(1, ($LastDonoDate - $FirstDonoDate).TotalDays)
Write-Host ("{0,10:n2} {1}`tPer stream" -f ($TotalIncomeToDate / $NumberOfStreams),$FinalCurrency)
Write-Host ("{0,10:n2} {1}`tPer monetized stream" -f ($TotalIncomeToDate / $NumberOfMonetizedStreams),$FinalCurrency)
Write-Host ("{0,10:n2} {1}`tPer day (since first dono)" -f ($TotalIncomeToDate / $DonoDaysRange),$FinalCurrency)
if ($EstimatedCompanyCut -ne -1) {
	$daily = ($TotalIncomeToDate / $DonoDaysRange)
	$lessYT = $daily * (1 - 0.3)
	$lessCompany = $lessYT * (1 - $EstimatedCompanyCut)
	$hourly = $lessCompany * 7 / 40
	Write-Host ("{0,10:n2} {1}`tEstimated hourly pay (less YT cut and company cut)" -f $hourly,$FinalCurrency)
}
Write-Host ("{0,10:n0}`tUnique Donators" -f $donators.Count)
Write-Host ("{0,10:n0}`tUnique Regular Donators (more than {1} donos)" -f ($regularDonators.Count,$RegularDonatorThreshold))
Write-Host ("{0,10:n2}`tAverage donations per donator" -f ($NumberOfDonations / $donators.Length))
Write-Host ("{0,10:yyyy-MM-dd}`tFirst Dono" -f $FirstDonoDate.Date)
Write-Host ("{0,10:yyyy-MM-dd}`tLast Dono" -f $LastDonoDate.Date)
Write-Host ("{0,10:n0}`tTotal days (since first dono)" -f $DonoDaysRange)

if ($ShowTopCurrencies) {
	$ShowHowMany = $LeaderboardSize
	Write-Host -Fore Cyan "Top Currencies (By count):"
	$AggregateCurrencies.GetEnumerator() | Sort {$_.Value.count} -Descending | Select -First $ShowHowMany | %{
		$PercentOfDonos = $_.Value.count / $NumberOfDonations * 100
		Write-Host ("{0,10:n3} %`t{1}" -f $PercentOfDonos,$_.Key)
	}
	Write-Host -Fore Cyan "Top Currencies (By amount):"
	$AggregateCurrencies.GetEnumerator() | Sort {$_.Value.amount} -Descending | Select -First $ShowHowMany | %{
		$PercentOfDonos = $_.Value.amount / $TotalIncomeToDate * 100
		Write-Host ("{0,10:n3} %`t{1}" -f $PercentOfDonos,$_.Key)
	}
}

if ($ShowTopDonators) {
	$ShowHowMany = $LeaderboardSize
	if ($Anonymize) {
		$DonatorFormat = "Hidden"
	} else {
		$DonatorFormat = "{2}"
	}
	if ($HideTopAmounts) {
		$AllTimeAmountFormat = " " * 6 + "???? {1}"
		$AverageAmountFormat = " " * 6 + "???? {1}"
	} else {
		$AllTimeAmountFormat = "{0,10:n0} {1}"
		$AverageAmountFormat = "{0,10:n2} {1}"
	}
	Write-Host -Fore Cyan "Top Donators (All-Time):"
	$AggregateDonations.GetEnumerator() | Sort {$_.Value.TOTAL} -Descending | Select -First $ShowHowMany | %{
		Write-Host ("$AllTimeAmountFormat`t$DonatorFormat" -f $_.Value.TOTAL,$FinalCurrency,$_.Value.Name)
	}
	Write-Host -Fore Cyan "Top Donators (Average per donation, more than $RegularDonatorThreshold donos):"
	$AggregateDonations.GetEnumerator() | Sort {[float]$_.Value.average} -Descending | Where-Object {
		$_.Value.donations -gt $RegularDonatorThreshold
	} | Select -First $ShowHowMany | %{
		Write-Host ("$AverageAmountFormat`t$DonatorFormat" -f $_.Value.average,$FinalCurrency,$_.Value.Name)
	}
	Write-Host -Fore Cyan "Top Donators (Personal average 'per day', more than $RegularDonatorThreshold donos):"
	$AggregateDonations.GetEnumerator() | Sort {$_.Value.PerDayAmount} -Descending | Where-Object {
		$_.Value.donations -gt $RegularDonatorThreshold
	} | Select -First $ShowHowMany | %{
		Write-Host ("$AverageAmountFormat`t$DonatorFormat" -f $_.Value.PerDayAmount,$FinalCurrency,$_.Value.Name)
	}
}
if ($PassThru) {
	$AggregateDonations
	$donation_list
}