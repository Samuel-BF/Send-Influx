<#
.SYNOPSIS
Retrieves counter values and sends them to an InfluxDB server
.DESCRIPTION
This script loads counter from system counters (Get-Counter) or from .blg or .csv file from perfmon.exe.
Then it formats those counters and sends them to an InfluxDB server with a millisecond precision.
.PARAMETER URI
InfluxDB server address and parameters (typically http://host:8086/write?db=db_name&precision=ms)
.PARAMETER Table
InfluxDB table where to put data
.PARAMETER Counter
Counters to extract from blg file or csv file if specified, from system if not.
.PARAMETER CSVFile
.PARAMETER BLGFile
Load counter from these files (if no counter specified : load all counters from these files).
.EXAMPLE
Send-ToInflux -URI http://influx_server:8086/write?db=influxdata&precision=ms -Table Processor -Counter @("\Processor(*)\% Idle Time","\Processor(*)\% User Time")
.NOTES
Default time precision : milliseconds.
You should use telegraf instead of this script !
.LINK
Source : https://github.com/Samuel-BF/Send-Influx
Telegraf : https://github.com/influxdata/telegraf/tree/master/plugins/inputs/win_perf_counters
#>
 
[CmdletBinding()]param (
    [Parameter(Mandatory=$true)][URI]$URI,
    [Parameter(Mandatory=$true)][string]$Table,
    [Parameter(Mandatory=$false)][string[]]$Counter,
    [Parameter(Mandatory=$false)][string]$CSVFile,
    [Parameter(Mandatory=$false)][string]$BLGFile
)


function ConvertFrom-CounterPath {
<#
.SYNOPSIS
Converts a counter path (\\$computer\$counter($instance)\$objectname) into a tag string :
host=$computer,counters=$counter,instance=$instance,objectname=$objectname
.PARAMETER Path
Full path of the counter (including host name). 
#>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline=$true)][string]$Path)


    process {
        function Escape-ToInflux {
            param([string]$str)
            $str -replace ' ','\ ' -replace '=','\=' -replace ',','\,'
        }
        $parts = [regex]::match($Path, '\\\\([^\\]*)\\([^\\(]*)(\(([^,]+,)?([^)]*)\))?\\([^\\(]*)').Groups
    
        if($parts[5]) {
            "host="+(Escape-ToInflux $parts[1])+`
            ",counters="+(Escape-ToInflux $parts[2])+`
            ",instance="+(Escape-ToInflux $parts[5])+`
            ",objectname="+(Escape-ToInflux $parts[6])
        } else {
            "host="+(Escape-ToInflux $parts[1])+`
            ",counters="+(Escape-ToInflux $parts[2])+`
            ",objectname="+(Escape-ToInflux $parts[6])
        }
    }
}


function ConvertFrom-CSV {
    [CmdletBinding()]
    param (
       [Parameter(Mandatory=$true)][string]$File,
       [Parameter(Mandatory=$true)][string]$Table,
       [Parameter(Mandatory=$false)][string[]]$Counter
    )

    if($Counter) {
        $tmpFile = New-TemporaryFile
        relog.exe $File -c $Counter -f csv -o $tmpFile.FullName -y | Out-Null
        $File = $tmpFile
    }


    $CounterTags=(((gc $File -head 1) -split '","' | select -skip 1) -replace '"$','') | ConvertFrom-CounterPath
    Get-Content $File | select -skip 1 | foreach-object { 
        $cnt = (($_ -replace '"','') -split ',')
        $epoch = [datetime]'01/01/1970'
        $ts = [math]::round((New-TimeSpan -Start $epoch -End ([datetime] $cnt[0]).ToUniversalTime()).TotalMilliseconds)
        foreach ($index in 1..($cnt.Count-1)) {
            if(![string]::IsNullOrWhiteSpace($cnt[$index])) {
                $Table+',' + $CounterTags[$index-1]+' value=' + $cnt[$index] + ' ' + $ts
	    }
        }
    }
}

Function ConvertFrom-BLG {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string]$File,
        [Parameter(Mandatory=$true)][string]$Table,
        [Parameter(Mandatory=$false)][string[]]$Counter
    )
    $csvFile = New-TemporaryFile
    if($Counter) {
        relog.exe $File -c $Counter -f csv -o $csvFile.FullName -y | Out-Null
    } else {
        relog.exe $File -f csv -o $csvFile.FullName -y | Out-Null
    }
    ConvertFrom-CSV -File $csvFile -Table $Table
    Remove-Item $csvFile.FullName -Force
}


function ConvertFrom-Counter {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string[]]$Counter,
        [Parameter(Mandatory=$true)][string]$Table
    )
    
    $CounterResult = Get-Counter -Counter $Counter
    $ts=(Get-Date $CounterResult.Timestamp -UFormat '%s').Replace((Get-Culture).NumberFormat.NumberDecimalSeparator, '')
    $epoch = [datetime]'01/01/1970'
    $ts = [math]::round((New-TimeSpan -Start $epoch -End $CounterResult.Timestamp.ToUniversalTime()).TotalMilliseconds)
    ($CounterResult.CounterSamples | ForEach-Object {
        $Table + ',' + ($_.Path | ConvertFrom-CounterPath) + ' value=' + $_.CookedValue + ' ' + $ts
    })
}


if($CSVFile) {
    if($Counter) {
        $InfluxData = ConvertFrom-CSV -File $CSVFile -Table $Table -Counter $Counter
    } else {
        $InfluxData = ConvertFrom-CSV -File $CSVFile -Table $Table
    }
} elseif($BLGFile) {
    if($Counter) {
        $InfluxData = ConvertFrom-BLG -File $BLGFile -Table $Table -Counter $Counter
    } else {
        $InfluxData = ConvertFrom-BLG -File $BLGFile -Table $Table
    }
} elseif($Counter) {
    $InfluxData = ConvertFrom-Counter -Counter $Counter -Table $Table
} else {
    Write-Error -Message "No counter or counter sources specified" -Category InvalidArgument
    return
}

# For encoding reasons, it's impossible to pipe the body into Invoke-RestMethod, you have to use -Body parameter :
$Body = [System.Text.Encoding]::UTF8.GetBytes(($InfluxData) -join "`n")

$ServicePoint = [System.Net.ServicePointManager]::FindServicePoint($URI)
Invoke-RestMethod -Method Post -Uri "$URI" -Body $Body
$ServicePoint.CloseConnectionGroup("") | Out-Null

