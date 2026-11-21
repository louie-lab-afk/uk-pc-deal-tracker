[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SeedBaseline,
    [switch]$TestAlert,
    [switch]$ShowSummary,
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure TLS 1.2 for HTTPS requests in Windows PowerShell 5.1 (harmless on PS 7)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $ScriptDir "config.json"
}
$LocalConfigPath = Join-Path $ScriptDir "config.local.json"
$DataDir   = Join-Path $ScriptDir "data"
$SeenFile  = Join-Path $DataDir "seen.json"
$HistFile  = Join-Path $DataDir "history.json"
$LogFile   = Join-Path $DataDir "tracker.log"

if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if ($DryRun -or $ShowSummary -or $SeedBaseline -or $TestAlert -or $VerbosePreference -eq "Continue" -or ($env:GITHUB_ACTIONS -eq "true")) {
        Write-Host $line
    }
}

function Trim-Log {
    param([int]$MaxLines = 500)
    if (Test-Path $LogFile) {
        $lines = @(Get-Content -Path $LogFile -Encoding UTF8)
        if ($lines.Count -gt $MaxLines) {
            $lines | Select-Object -Last $MaxLines | Set-Content -Path $LogFile -Encoding UTF8
        }
    }
}

function Get-XmlText {
    param($Node)
    if ($null -eq $Node) { return "" }
    if ($Node -is [string]) { return $Node.Trim() }
    if ($Node.PSObject.Properties['#cdata-section']) { return ([string]$Node.'#cdata-section').Trim() }
    if ($Node.PSObject.Properties['#text']) { return ([string]$Node.'#text').Trim() }
    if ($Node.PSObject.Properties['InnerText']) { return ([string]$Node.InnerText).Trim() }
    return ([string]$Node).Trim()
}

function Strip-Html {
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
    $txt = $Html -replace '<[^>]+>', ' '
    $txt = [System.Net.WebUtility]::HtmlDecode($txt)
    $txt = $txt -replace '\s+', ' '
    return $txt.Trim()
}

function Parse-GbpAmount {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -match '£\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)') {
        $numStr = $Matches[1] -replace ',', ''
        [double]$val = 0
        if ([double]::TryParse($numStr, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
            return $val
        }
    }
    return $null
}

function Parse-CapacityTB {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -match '(?i)\b([0-9]+(?:\.[0-9]+)?)\s*tb\b') {
        return [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Text -match '(?i)\b(1000|1024|2000|2048|4000|4096|8000|500|512|250|256)\s*gb\b') {
        $gb = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
        return [Math]::Round($gb / 1000.0, 2)
    }
    return $null
}

function Parse-RamCapacityGB {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    # Match kit syntax like 2x16GB, 2 x 32GB, 2 × 16GB
    if ($Text -match '(?i)\b([124])\s*[x×]\s*(8|16|24|32|48|64)\s*gb\b') {
        return ([int]$Matches[1] * [int]$Matches[2])
    }
    # Match reverse syntax like 16GB x2 or 16GB X 2
    if ($Text -match '(?i)\b(8|16|24|32|48|64)\s*gb\s*[x×]\s*([124])\b') {
        return ([int]$Matches[1] * [int]$Matches[2])
    }
    # Fallback to total GB
    if ($Text -match '(?i)\b(16|24|32|48|64|96|128|192|256)\s*gb\b') {
        return [int]$Matches[1]
    }
    return $null
}

function Fetch-Utf8Text {
    param([string]$Url, [int]$TimeoutSec = 15)
    $headers = @{
        "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) UKPCDealTracker/1.0"
        "Accept"          = "application/rss+xml, application/xml, text/xml;q=0.9, */*;q=0.8"
        "Accept-Language" = "en-GB,en;q=0.9"
    }
    $resp = Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing
    if ($resp.RawContentStream -is [System.IO.MemoryStream] -and $resp.RawContentStream.Length -gt 0) {
        $resp.RawContentStream.Position = 0
        $bytes = $resp.RawContentStream.ToArray()
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    return [string]$resp.Content
}

function Load-JsonHashtable {
    param([string]$Path)
    $ht = @{}
    if (-not (Test-Path $Path)) { return $ht }
    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $ht }
        $obj = $raw | ConvertFrom-Json
        if ($null -ne $obj) {
            foreach ($prop in $obj.PSObject.Properties) {
                $ht[$prop.Name] = $prop.Value
            }
        }
    } catch {
        Write-Log "Failed to load ${Path}: $($_.Exception.Message)" "WARN"
    }
    return $ht
}

function Save-JsonObject {
    param($Object, [string]$Path)
    $json = $Object | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Send-DiscordAlert {
    param($Config, $Deal)
    $webhook = [string]$Config.alerts.discord_webhook_url
    if ([string]::IsNullOrWhiteSpace($webhook)) { return }

    $isMisprice = ($Deal.AlertTier -eq "MISPRICE")
    $color = if ($isMisprice) { 15158332 } else { 3066993 } # Red vs Green
    $prefix = if ($isMisprice) { "🚨 MISPRICE / INSANE DEAL" } else { "📉 30-DAY LOW / GREAT SALE" }

    $fields = @(
        @{ name = "Category"; value = $Deal.CategoryLabel; inline = $true }
        @{ name = "Price";    value = ("£{0:N2}" -f $Deal.Price); inline = $true }
        @{ name = "Merchant"; value = $(if ($Deal.Merchant) { $Deal.Merchant } else { $Deal.Source }); inline = $true }
    )
    if ($null -ne $Deal.OldPrice -and $Deal.OldPrice -gt $Deal.Price) {
        $fields += @{ name = "Was / Discount"; value = ("£{0:N2} (-{1:N0}%)" -f $Deal.OldPrice, $Deal.DiscountPct); inline = $true }
    } elseif ($null -ne $Deal.DiscountPct -and $Deal.DiscountPct -gt 0) {
        $fields += @{ name = "Discount"; value = ("-{0:N0}%" -f $Deal.DiscountPct); inline = $true }
    }
    if ($Deal.UnitMetric) {
        $fields += @{ name = "Unit Price"; value = $Deal.UnitMetric; inline = $true }
    }
    if ($null -ne $Deal.Prev30DayLow) {
        $fields += @{ name = "Prev 30-Day Low"; value = ("£{0:N2}" -f $Deal.Prev30DayLow); inline = $true }
    }
    $fields += @{ name = "Why Triggered"; value = ($Deal.Reasons -join " | "); inline = $false }

    $payload = @{
        username = "UK PC Deal Tracker"
        embeds   = @(
            @{
                title       = "$prefix`: $($Deal.Title.Substring(0, [Math]::Min(200, $Deal.Title.Length)))"
                url         = $Deal.Link
                color       = $color
                fields      = $fields
                footer      = @{ text = "Source: $($Deal.Source)" }
                timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        )
    }

    $json = $payload | ConvertTo-Json -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Uri $webhook -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 15 | Out-Null
}

function Send-NtfyAlert {
    param($Config, $Deal)
    $topic = [string]$Config.alerts.ntfy_topic
    if ([string]::IsNullOrWhiteSpace($topic)) { return }
    $server = ([string]$Config.alerts.ntfy_server).TrimEnd("/")
    $url = "$server/$topic"

    $isMisprice = ($Deal.AlertTier -eq "MISPRICE")
    $priority = if ($isMisprice) { "urgent" } else { "high" }
    $tags     = if ($isMisprice) { "rotating_light,fire,gb" } else { "chart_with_downwards_trend,gb" }
    $titleAscii = if ($isMisprice) {
        "MISPRICE: $($Deal.CategoryLabel) - GBP $([Math]::Round($Deal.Price, 2))"
    } else {
        "DEAL: $($Deal.CategoryLabel) - GBP $([Math]::Round($Deal.Price, 2))"
    }

    $bodyLines = @(
        $Deal.Title,
        ("Price: £{0:N2} @ {1}" -f $Deal.Price, $(if ($Deal.Merchant) { $Deal.Merchant } else { $Deal.Source }))
    )
    if ($null -ne $Deal.OldPrice -and $Deal.OldPrice -gt $Deal.Price) {
        $bodyLines += ("Was: £{0:N2} (-{1:N0}%)" -f $Deal.OldPrice, $Deal.DiscountPct)
    }
    if ($Deal.UnitMetric) { $bodyLines += "Unit: $($Deal.UnitMetric)" }
    if ($null -ne $Deal.Prev30DayLow) { $bodyLines += ("Prev 30-day low: £{0:N2}" -f $Deal.Prev30DayLow) }
    $bodyLines += "Reason: $($Deal.Reasons -join '; ')"
    $bodyLines += $Deal.Link

    $headers = @{
        "Title"    = $titleAscii
        "Priority" = $priority
        "Tags"     = $tags
        "Click"    = $Deal.Link
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyLines -join "`n"))
    Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $bytes -ContentType "text/plain; charset=utf-8" -TimeoutSec 15 | Out-Null
}

function Send-WindowsToast {
    param($Config, $Deal)
    if (-not $Config.alerts.windows_toast) { return }
    if ($env:OS -notlike "*Windows*") { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.BalloonTipIcon = if ($Deal.AlertTier -eq "MISPRICE") { "Warning" } else { "Info" }
        $notify.BalloonTipTitle = "$($Deal.AlertTier): $($Deal.CategoryLabel) (£$($Deal.Price))"
        $notify.BalloonTipText  = "$($Deal.Title) [$($Deal.Merchant)]"
        $notify.Visible = $true
        $notify.ShowBalloonTip(8000)
        Start-Sleep -Milliseconds 1500
        $notify.Dispose()
    } catch {
        Write-Log "Windows toast failed: $($_.Exception.Message)" "WARN"
    }
}

function Dispatch-Alert {
    param($Config, $Deal)
    $sentAny = $false
    if (-not [string]::IsNullOrWhiteSpace($Config.alerts.discord_webhook_url)) {
        try {
            Send-DiscordAlert -Config $Config -Deal $Deal
            $sentAny = $true
        } catch {
            Write-Log "Discord alert error: $($_.Exception.Message)" "ERROR"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Config.alerts.ntfy_topic)) {
        try {
            Send-NtfyAlert -Config $Config -Deal $Deal
            $sentAny = $true
        } catch {
            Write-Log "ntfy.sh alert error: $($_.Exception.Message)" "ERROR"
        }
    }
    if ($Config.alerts.windows_toast) {
        Send-WindowsToast -Config $Config -Deal $Deal
        $sentAny = $true
    }
    return $sentAny
}

function Parse-FeedItems {
    param($FeedConfig, [int]$TimeoutSec)
    $items = @()
    try {
        $xmlText = Fetch-Utf8Text -Url $FeedConfig.url -TimeoutSec $TimeoutSec
        [xml]$xml = $xmlText
    } catch {
        Write-Log "Feed '$($FeedConfig.name)' fetch/parse failed: $($_.Exception.Message)" "WARN"
        return @()
    }

    if ($null -eq $xml.rss -or $null -eq $xml.rss.channel -or $null -eq $xml.rss.channel.item) {
        return @()
    }

    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace("pepper", "http://www.pepper.com/rss")

    foreach ($node in @($xml.rss.channel.item)) {
        $title = Get-XmlText $node.title
        $link  = Get-XmlText $node.link
        $desc  = Strip-Html (Get-XmlText $node.description)
        $pub   = Get-XmlText $node.pubDate
        $guid  = Get-XmlText $node.guid
        if ([string]::IsNullOrWhiteSpace($guid)) { $guid = $link }

        $merchant = ""
        $price = $null
        $oldPrice = $null
        $discountPct = $null

        if ($FeedConfig.type -eq "hotukdeals") {
            $mNode = $node.SelectSingleNode("pepper:merchant", $ns)
            if ($null -ne $mNode) {
                $merchant = [System.Net.WebUtility]::HtmlDecode([string]$mNode.GetAttribute("name"))
                $price = Parse-GbpAmount ([string]$mNode.GetAttribute("price"))
            }
            if ($null -eq $price) { $price = Parse-GbpAmount $title }
            if ($null -eq $price) { $price = Parse-GbpAmount $desc }

            # Look for "was £X" or "RRP £X"
            $combined = "$title $desc"
            if ($combined -match '(?i)\b(?:was|rrp|usually|down from|previously)\s*£\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)') {
                $oldPrice = [double]::Parse(($Matches[1] -replace ',', ''), [System.Globalization.CultureInfo]::InvariantCulture)
            }
            if ($combined -match '(?i)\b([0-9]{1,2}(?:\.[0-9])?)\s*%\s*off\b') {
                $discountPct = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
            }
            if ($null -ne $price -and $null -ne $oldPrice -and $oldPrice -gt $price) {
                $calcPct = [Math]::Round((($oldPrice - $price) / $oldPrice) * 100.0, 1)
                if ($null -eq $discountPct -or $calcPct -gt $discountPct) {
                    $discountPct = $calcPct
                }
            }
        }
        elseif ($FeedConfig.type -eq "camelcamelcamel") {
            $merchant = "Amazon UK"
            # Format: "Product Name - down 87.55% (£21.10) to £3.00 from £24.10"
            if ($title -match 'down\s+([0-9]+(?:\.[0-9]+)?)%.*?\bto\s+£([0-9,]+(?:\.[0-9]+)?)\s+from\s+£([0-9,]+(?:\.[0-9]+)?)') {
                $discountPct = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
                $price       = [double]::Parse(($Matches[2] -replace ',', ''), [System.Globalization.CultureInfo]::InvariantCulture)
                $oldPrice    = [double]::Parse(($Matches[3] -replace ',', ''), [System.Globalization.CultureInfo]::InvariantCulture)
            } else {
                $price = Parse-GbpAmount $title
            }
        }

        # Canonical ID: prefer HUKD numeric deal ID if present so cross-feed duplicates collapse
        $canonicalId = $guid
        if ($link -match 'hotukdeals\.com/deals/.*-(\d+)(?:\?|$)') {
            $canonicalId = "hukd-$($Matches[1])"
        } elseif ($link -match 'camelcamelcamel\.com/product/([A-Z0-9]+)') {
            $canonicalId = "camel-$($Matches[1])"
        }

        $items += [PSCustomObject]@{
            Id              = $canonicalId
            Source          = $FeedConfig.name
            FeedType        = $FeedConfig.type
            DefaultCategory = $FeedConfig.default_category
            Title           = $title
            Description     = $desc
            Link            = $link
            Merchant        = $merchant
            Price           = $price
            OldPrice        = $oldPrice
            DiscountPct     = $discountPct
            PubDate         = $pub
        }
    }
    return $items
}

function Classify-Item {
    param($Item, $Config)
    # Order matters: check specific component types in priority order
    $order = @("nvme_ssd", "cpu", "gpu", "motherboard", "ddr5_ram")
    $titleOnly = $Item.Title
    $titleAndShortDesc = "$($Item.Title) $($Item.Description.Substring(0, [Math]::Min(250, $Item.Description.Length)))"

    foreach ($catKey in $order) {
        $cat = $Config.categories.$catKey
        if (-not $cat.enabled) { continue }

        # Exclude check runs on Title (and for PC/laptop words also short description)
        if (-not [string]::IsNullOrWhiteSpace($cat.exclude_regex)) {
            if ($titleOnly -match $cat.exclude_regex) { continue }
        }

        # Include check primarily on Title (and short desc only if feed defaulted to this category)
        $matched = ($titleOnly -match $cat.include_regex)
        if (-not $matched -and $Item.DefaultCategory -eq $catKey) {
            $matched = ($titleAndShortDesc -match $cat.include_regex)
        }
        if ($matched) {
            return $catKey
        }
    }
    return $null
}

function Evaluate-Deal {
    param($Item, [string]$CatKey, $Config, [hashtable]$History)

    $cat = $Config.categories.$CatKey
    if ($null -eq $Item.Price -or $Item.Price -lt [double]$cat.min_valid_price_gbp) {
        return $null
    }

    $textAll = "$($Item.Title) $($Item.Description)"
    $reasons = @()
    $isMisprice = $false
    $isSale = $false
    $unitMetric = ""
    $bucketKey = $CatKey
    $metricValue = [double]$Item.Price

    # 1. Global misprice keywords
    foreach ($kw in $Config.misprice_rules.keywords) {
        if ($textAll -match "(?i)\b$([Regex]::Escape($kw))\b") {
            $isMisprice = $true
            $reasons += "Keyword '$kw'"
            break
        }
    }

    # 2. Global discount percentage rules
    if ($null -ne $Item.DiscountPct) {
        if ($Item.DiscountPct -ge [double]$Config.misprice_rules.min_discount_percent_misprice) {
            $isMisprice = $true
            $reasons += ("-{0:N0}% off (misprice threshold)" -f $Item.DiscountPct)
        } elseif ($Item.DiscountPct -ge [double]$Config.misprice_rules.min_discount_percent_sale) {
            $isSale = $true
            $reasons += ("-{0:N0}% off" -f $Item.DiscountPct)
        }
    }

    # 3. Category-specific logic
    if ($CatKey -eq "nvme_ssd") {
        $capTB = Parse-CapacityTB $Item.Title
        if ($null -eq $capTB) { $capTB = Parse-CapacityTB $Item.Description }
        $maxCapTB = if ($cat.PSObject.Properties["max_capacity_tb"]) { [double]$cat.max_capacity_tb } else { 16.0 }
        if ($null -eq $capTB -or $capTB -lt [double]$cat.min_capacity_tb -or $capTB -gt $maxCapTB) {
            if (-not $isMisprice) { return $null }
        } else {
            $gbpPerTB = [Math]::Round($Item.Price / $capTB, 2)
            $unitMetric = ("£{0:N2}/TB ({1}TB)" -f $gbpPerTB, $capTB)
            $capBucket = if ($capTB -ge 4) { "4TB+" } elseif ($capTB -ge 2) { "2TB" } else { "1TB" }
            $bucketKey = "nvme_ssd:$capBucket"
            $metricValue = $gbpPerTB

            if ($capTB -ge 2.0) {
                if ($gbpPerTB -le [double]$cat.misprice_gbp_per_tb_2tb_plus) {
                    $isMisprice = $true
                    $reasons += ("2TB+ NVMe at £{0:N2}/TB (<= £{1}/TB)" -f $gbpPerTB, $cat.misprice_gbp_per_tb_2tb_plus)
                } elseif ($gbpPerTB -le [double]$cat.sale_gbp_per_tb_2tb_plus) {
                    $isSale = $true
                    $reasons += ("2TB+ NVMe at £{0:N2}/TB (<= £{1}/TB)" -f $gbpPerTB, $cat.sale_gbp_per_tb_2tb_plus)
                }
            } else {
                # 1TB: only alert if insane deal / misprice
                if ($gbpPerTB -le [double]$cat.misprice_gbp_per_tb_1tb) {
                    $isMisprice = $true
                    $reasons += ("Insane 1TB NVMe at £{0:N2}/TB (<= £{1}/TB)" -f $gbpPerTB, $cat.misprice_gbp_per_tb_1tb)
                }
            }
        }
    }
    elseif ($CatKey -eq "ddr5_ram") {
        $capGB = Parse-RamCapacityGB $Item.Title
        if ($null -eq $capGB) { $capGB = Parse-RamCapacityGB $Item.Description }
        if ($null -ne $capGB -and $capGB -ge [int]$cat.min_capacity_gb) {
            $gbpPerGB = [Math]::Round($Item.Price / $capGB, 2)
            $unitMetric = ("£{0:N2}/GB ({1}GB)" -f $gbpPerGB, $capGB)
            $bucketKey = "ddr5_ram:${capGB}GB"
            $metricValue = $gbpPerGB

            if ($gbpPerGB -le [double]$cat.misprice_gbp_per_gb) {
                $isMisprice = $true
                $reasons += ("DDR5 at £{0:N2}/GB (<= £{1}/GB)" -f $gbpPerGB, $cat.misprice_gbp_per_gb)
            } elseif ($gbpPerGB -le [double]$cat.sale_gbp_per_gb) {
                $isSale = $true
                $reasons += ("DDR5 at £{0:N2}/GB (<= £{1}/GB)" -f $gbpPerGB, $cat.sale_gbp_per_gb)
            }
        }
    }
    else {
        # GPU, CPU, Motherboard
        if ($cat.PSObject.Properties["misprice_max_price_gbp"] -and $Item.Price -le [double]$cat.misprice_max_price_gbp) {
            $isMisprice = $true
            $reasons += ("Price £{0:N2} <= misprice cap £{1}" -f $Item.Price, $cat.misprice_max_price_gbp)
        }
        if ($cat.PSObject.Properties["sale_max_price_gbp"] -and $Item.Price -le [double]$cat.sale_max_price_gbp) {
            $isSale = $true
            $reasons += ("Price £{0:N2} <= target £{1}" -f $Item.Price, $cat.sale_max_price_gbp)
        }
        if ($cat.PSObject.Properties["watched_models"] -and $null -ne $cat.watched_models) {
            # Match longest model name first so "rtx 5070 ti" wins over "rtx 5070"
            $modelProps = @($cat.watched_models.PSObject.Properties | Sort-Object { $_.Name.Length } -Descending)
            foreach ($mp in $modelProps) {
                $pattern = "(?i)\b" + ([Regex]::Escape($mp.Name) -replace '\\ ', '\s*') + "\b"
                if ($Item.Title -match $pattern) {
                    $bucketKey = "${CatKey}:$($mp.Name.ToLower())"
                    $targetPrice = [double]$mp.Value
                    if ($Item.Price -le ($targetPrice * 0.6)) {
                        $isMisprice = $true
                        $reasons += ("Watched '$($mp.Name)' at £{0:N2} (40%+ below £{1} target!)" -f $Item.Price, $targetPrice)
                    } elseif ($Item.Price -le $targetPrice) {
                        $isSale = $true
                        $reasons += ("Watched '$($mp.Name)' <= target £{0}" -f $targetPrice)
                    }
                    break
                }
            }
        }
    }

    # 4. Rolling 30-day low check from local history
    $prev30DayLow = $null
    $is30DayLow = $false
    if ($History.ContainsKey($bucketKey)) {
        $samples = @($History[$bucketKey] | Where-Object { $_.id -ne $Item.Id })
        if ($samples.Count -ge [int]$Config.general.min_history_samples_for_30d_low) {
            $minMetric = ($samples | Measure-Object -Property metric -Minimum).Minimum
            $minPriceEntry = $samples | Sort-Object metric | Select-Object -First 1
            $prev30DayLow = [double]$minPriceEntry.price
            if ($metricValue -lt [double]$minMetric) {
                $is30DayLow = $true
                # For 1TB NVMe, only promote 30-day low if it's a genuinely steep drop (15% below prev low)
                if ($bucketKey -eq "nvme_ssd:1TB") {
                    if ($metricValue -le ([double]$minMetric * 0.85)) {
                        $isSale = $true
                        $reasons += ("1TB NVMe 15%+ below 30-day low (£{0:N2}/TB)" -f $minMetric)
                    }
                } else {
                    $isSale = $true
                    $reasons += ("New 30-day low for $bucketKey (beat £{0:N2})" -f $prev30DayLow)
                }
            }
        }
    }

    $tier = "NONE"
    if ($isMisprice) { $tier = "MISPRICE" }
    elseif ($isSale) { $tier = "SALE" }

    return [PSCustomObject]@{
        Id            = $Item.Id
        Source        = $Item.Source
        Category      = $CatKey
        CategoryLabel = $cat.label
        BucketKey     = $bucketKey
        MetricValue   = $metricValue
        UnitMetric    = $unitMetric
        Title         = $Item.Title
        Merchant      = $Item.Merchant
        Price         = [double]$Item.Price
        OldPrice      = $Item.OldPrice
        DiscountPct   = $Item.DiscountPct
        Prev30DayLow  = $prev30DayLow
        Is30DayLow    = $is30DayLow
        AlertTier     = $tier
        Reasons       = $reasons
        Link          = $Item.Link
    }
}

# ==================== MAIN ====================

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at: $ConfigPath"
}
$Config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Merge optional untracked local secrets (config.local.json)
if (Test-Path $LocalConfigPath) {
    try {
        $localCfg = Get-Content -Path $LocalConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($localCfg.PSObject.Properties["ntfy_topic"] -and -not [string]::IsNullOrWhiteSpace($localCfg.ntfy_topic)) {
            $Config.alerts.ntfy_topic = [string]$localCfg.ntfy_topic
        }
        if ($localCfg.PSObject.Properties["ntfy_server"] -and -not [string]::IsNullOrWhiteSpace($localCfg.ntfy_server)) {
            $Config.alerts.ntfy_server = [string]$localCfg.ntfy_server
        }
        if ($localCfg.PSObject.Properties["discord_webhook_url"] -and -not [string]::IsNullOrWhiteSpace($localCfg.discord_webhook_url)) {
            $Config.alerts.discord_webhook_url = [string]$localCfg.discord_webhook_url
        }
    } catch {
        Write-Log "Failed to parse config.local.json: $($_.Exception.Message)" "WARN"
    }
}

# Environment variable overrides (used by GitHub Actions Secrets)
if (-not [string]::IsNullOrWhiteSpace($env:NTFY_TOPIC))          { $Config.alerts.ntfy_topic          = $env:NTFY_TOPIC.Trim() }
if (-not [string]::IsNullOrWhiteSpace($env:NTFY_SERVER))         { $Config.alerts.ntfy_server         = $env:NTFY_SERVER.Trim() }
if (-not [string]::IsNullOrWhiteSpace($env:DISCORD_WEBHOOK_URL)) { $Config.alerts.discord_webhook_url = $env:DISCORD_WEBHOOK_URL.Trim() }

if ($TestAlert) {
    $sample = [PSCustomObject]@{
        Id            = "test-alert"
        Source        = "SelfTest"
        Category      = "nvme_ssd"
        CategoryLabel = "NVMe M.2 SSD"
        UnitMetric    = "£24.99/TB (2TB)"
        Title         = "[TEST] WD Black SN850X 2TB NVMe M.2 SSD - Test Alert"
        Merchant      = "Amazon UK"
        Price         = 49.99
        OldPrice      = 179.99
        DiscountPct   = 72.2
        Prev30DayLow  = 149.99
        AlertTier     = "MISPRICE"
        Reasons       = @("Test alert triggered via -TestAlert")
        Link          = "https://www.hotukdeals.com/tag/ssd"
    }
    $ok = Dispatch-Alert -Config $Config -Deal $sample
    if ($ok) {
        Write-Host "Test alert dispatched successfully!" -ForegroundColor Green
    } else {
        Write-Host "No alert channels configured in config.json! Set 'discord_webhook_url' or 'ntfy_topic' (or 'windows_toast': true) and retry." -ForegroundColor Yellow
    }
    exit 0
}

$Seen    = Load-JsonHashtable -Path $SeenFile
$History = Load-JsonHashtable -Path $HistFile
$NowUtc  = (Get-Date).ToUniversalTime()
$Cutoff  = $NowUtc.AddDays(-[int]$Config.general.history_window_days)

# Prune old history entries (> 30 days)
foreach ($bk in @($History.Keys)) {
    $kept = @($History[$bk] | Where-Object {
        try { ([datetime]::Parse($_.ts).ToUniversalTime()) -ge $Cutoff } catch { $false }
    })
    if ($kept.Count -gt 0) { $History[$bk] = $kept } else { $History.Remove($bk) }
}

# Fetch all feeds & deduplicate by canonical ID across feeds
$AllItemsById = @{}
foreach ($feed in $Config.feeds) {
    $feedItems = @(Parse-FeedItems -FeedConfig $feed -TimeoutSec ([int]$Config.general.request_timeout_sec))
    foreach ($it in $feedItems) {
        if (-not $AllItemsById.ContainsKey($it.Id)) {
            $AllItemsById[$it.Id] = $it
        }
    }
}

Write-Log "Fetched $($AllItemsById.Count) unique items across $($Config.feeds.Count) feeds."

$MatchedDeals = @()
$AlertsSent   = 0
$MinTier      = ([string]$Config.alerts.min_alert_tier).ToUpper()

foreach ($item in $AllItemsById.Values) {
    $catKey = Classify-Item -Item $item -Config $Config
    if ($null -eq $catKey) { continue }

    $deal = Evaluate-Deal -Item $item -CatKey $catKey -Config $Config -History $History
    if ($null -eq $deal) { continue }

    $MatchedDeals += $deal

    # Update rolling 30-day history (unless DryRun)
    if (-not $DryRun) {
        if (-not $History.ContainsKey($deal.BucketKey)) {
            $History[$deal.BucketKey] = @()
        }
        $existingEntry = @($History[$deal.BucketKey] | Where-Object { $_.id -eq $deal.Id })
        if ($existingEntry.Count -eq 0) {
            $History[$deal.BucketKey] = @($History[$deal.BucketKey]) + @(
                [PSCustomObject]@{
                    id     = $deal.Id
                    price  = $deal.Price
                    metric = $deal.MetricValue
                    title  = $deal.Title
                    ts     = $NowUtc.ToString("o")
                }
            )
        }
    }

    # Decide if this deal qualifies for alerting
    $qualifies = $false
    if ($deal.AlertTier -eq "MISPRICE") {
        $qualifies = $true
    } elseif ($deal.AlertTier -eq "SALE" -and $MinTier -ne "MISPRICE") {
        $qualifies = $true
    }

    # Check deduplication (re-alert only if price dropped by >= realert_drop_percent)
    $alreadyAlerted = $false
    if ($Seen.ContainsKey($deal.Id)) {
        $prevPrice = [double]$Seen[$deal.Id].price
        $dropRatio = 1.0 - ([double]$Config.general.realert_drop_percent / 100.0)
        if ($deal.Price -gt ($prevPrice * $dropRatio)) {
            $alreadyAlerted = $true
        }
    }

    if ($SeedBaseline) {
        $Seen[$deal.Id] = [PSCustomObject]@{
            price = $deal.Price
            tier  = $deal.AlertTier
            ts    = $NowUtc.ToString("o")
        }
    }
    elseif ($qualifies -and -not $alreadyAlerted) {
        if ($DryRun) {
            Write-Host "[DRY-RUN ALERT - $($deal.AlertTier)] £$($deal.Price) | $($deal.CategoryLabel) | $($deal.Title)" -ForegroundColor $(if ($deal.AlertTier -eq "MISPRICE") { "Red" } else { "Green" })
            Write-Host "    Reasons: $($deal.Reasons -join '; ')" -ForegroundColor DarkGray
            Write-Host "    Link:    $($deal.Link)" -ForegroundColor DarkGray
        } else {
            $sent = Dispatch-Alert -Config $Config -Deal $deal
            Write-Log "ALERT [$($deal.AlertTier)] £$($deal.Price) ($($deal.CategoryLabel)) - $($deal.Title) | Reasons: $($deal.Reasons -join '; ') | Sent=$sent" "ALERT"
            $Seen[$deal.Id] = [PSCustomObject]@{
                price = $deal.Price
                tier  = $deal.AlertTier
                ts    = $NowUtc.ToString("o")
            }
            $AlertsSent++
        }
    }
}

if (-not $DryRun) {
    # Keep seen cache tidy (prune entries older than 60 days)
    $seenCutoff = $NowUtc.AddDays(-60)
    foreach ($sid in @($Seen.Keys)) {
        try {
            if (([datetime]::Parse($Seen[$sid].ts).ToUniversalTime()) -lt $seenCutoff) {
                $Seen.Remove($sid)
            }
        } catch {}
    }
    Save-JsonObject -Object $Seen    -Path $SeenFile
    Save-JsonObject -Object $History -Path $HistFile
}

if ($ShowSummary -or $DryRun -or $SeedBaseline) {
    Write-Host ""
    Write-Host "=== Matched UK PC Component Deals ($($MatchedDeals.Count) found) ===" -ForegroundColor Cyan
    $MatchedDeals |
        Sort-Object Category, Price |
        Select-Object `
            @{Name="Tier";     Expression={$_.AlertTier}},
            @{Name="Category"; Expression={$_.Category}},
            @{Name="Price";    Expression={"£{0:N2}" -f $_.Price}},
            @{Name="Unit";     Expression={$_.UnitMetric}},
            @{Name="Store";    Expression={$_.Merchant}},
            @{Name="Title";    Expression={if ($_.Title.Length -gt 65) { $_.Title.Substring(0,62) + "..." } else { $_.Title }}} |
        Format-Table -AutoSize
}

Write-Log "Run complete. Matched=$($MatchedDeals.Count), AlertsSent=$AlertsSent, DryRun=$DryRun, SeedBaseline=$SeedBaseline"
Trim-Log -MaxLines ([int]$Config.general.max_log_lines)
