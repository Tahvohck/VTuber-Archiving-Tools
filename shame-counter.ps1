Param(
	$FinalCurrency = "JPY",
	[switch]$ShowTopDonators,
	[switch]$Anonymize,
	[switch]$HideTopAmounts,
	[DateTime]$StartDate = [DateTime]::MinValue,
	[DateTime]$EndDate = [DateTime]::MaxValue,
	[switch]$TestConversion,
	[switch]$PassThru
)
$ScriptPath = (Get-Item $PSCommandPath).Directory.Fullname
. "$ScriptPath/common-functions.ps1"

# Globals
$Conversions = @{}
$AggregateDonations = @{}
$donation_list = [Collections.ArrayList]::new() 
$donators = [Collections.ArrayList]::new()

$FirstDonoDate = [DateTime]::MaxValue
$LastDonoDate = [DateTime]::MinValue
$TotalIncomeToDate = 0
$NumberOfStreams = 0
$NumberOfMonetizedStreams = 0
$ConversionREST = "https://free-currency-converter.herokuapp.com/list/convert?source={0}&destination={1}"
$FinalCurrency = $FinalCurrency.ToUpper()

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
Write-Host -Fore Cyan "Reading Donations"
foreach ($log in (get-childItem *.json)) {
	$LogHasADono = $false
	$json = get-content $log | convertfrom-json
	foreach($message in $json) {
		$LogHasADono = $true
		$donation = @{
			donator =	$message.author.name
			currency =	$message.money.currency -replace "₱","PHP"
			amount =	$message.money.amount
			timestamp = [datetimeoffset]::FromUnixTimeMilliseconds($message.timestamp/1000).LocalDateTime
		}
		
		if ($donation.timestamp -lt $StartDate -or $donation.timestamp -gt $EndDate) { continue }

		# Do some fixups here for known alts
		$donator = "$($donation.donator)"
		if ($donator -like "*Simulanze*") {
			$donator = "Simulanze"
		} elseif ($donator -in @("John -R&D at ShikiDew Industries-","John")) {
			$donator = "Pang/John"
		} elseif ($donator -like "*LC_Lapen*") {
			$donator = "LC_Lapen"
		} elseif ($donator -like "*Meateor*") {
			$donator = "Meateor"
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
		$AggregateDonations[$donator].earliest = [DateTime]::MaxValue
		$AggregateDonations[$donator].last = [DateTime]::MinValue

		if (!$donators.Contains($donator)){ $null = $donators.add($donator) }
	}

	$AggregateDonations[$donator].money[$donation.currency] += $donation.amount
	$AggregateDonations[$donator].donations += 1
	if ($donation.timestamp -lt $AggregateDonations[$donator].earliest) {
		$AggregateDonations[$donator].earliest = $donation.timestamp
	}
	if ($donation.timestamp -gt $AggregateDonations[$donator].last) {
		$AggregateDonations[$donator].last = $donation.timestamp
	}
}

Write-Host -Fore Cyan "Doing conversions to $FinalCurrency"
foreach($donator in ($donators | sort -unique)) {
	if (!($donator -in $AggregateDonations.Keys)) { continue }
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
		$donator_stats["average"] = "{0:n2}" -f ($donator_stats["TOTAL"] / $donator_stats["donations"])
		$days = [Math]::Max(1, ($donator_stats["last"].Date -  $donator_stats["earliest"].Date).TotalDays)
		$donator_stats["PerDay"] = [Math]::Round($donator_stats["TOTAL"] / $days, 3)
		$TotalIncomeToDate += $yen
	}
	$AggregateDonations[$donator] = [pscustomobject]$donator_stats
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
Write-Host ("{0,10:n0}`tTotal days (since first dono)" -f $DonoDaysRange)
Write-Host ("{0,10:yyyy-MM-dd}`tFirst Dono" -f $FirstDonoDate.Date)
Write-Host ("{0,10:yyyy-MM-dd}`tLast Dono" -f $LastDonoDate.Date)

if ($ShowTopDonators) {
	$ShowHowMany = 5
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
		Write-Host ("$AllTimeAmountFormat`t$DonatorFormat" -f $_.Value.TOTAL,$FinalCurrency,$_.Key)
	}
	Write-Host -Fore Cyan "Top Donators (Average per donation, more than 10 donos):"
	$AggregateDonations.GetEnumerator() | Sort {[float]$_.Value.average} -Descending | Where-Object {
		$_.Value.donations -gt 10
	} | Select -First $ShowHowMany | %{
		Write-Host ("$AverageAmountFormat`t$DonatorFormat" -f $_.Value.average,$FinalCurrency,$_.Key)
	}
	Write-Host -Fore Cyan "Top Donators (Personal average 'per day', more than 10 donos):"
	$AggregateDonations.GetEnumerator() | Sort {$_.Value.PerDay} -Descending | Where-Object {
		$_.Value.donations -gt 10
	} | Select -First $ShowHowMany | %{
		Write-Host ("$AverageAmountFormat`t$DonatorFormat" -f $_.Value.PerDay,$FinalCurrency,$_.Key)
	}
}
if ($PassThru) {
	$AggregateDonations
	$donation_list
}