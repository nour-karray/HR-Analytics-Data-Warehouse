param(
    [string]$InputPath = (Join-Path $PSScriptRoot 'HRDataset.csv'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'HRDataset_Clean_Validated.csv'),
    [datetime]$ReferenceDate = [datetime]'2026-04-25'
)

$ErrorActionPreference = 'Stop'

$Headers = @(
    'Employee_Name',
    'EmpID',
    'MarriedID',
    'MaritalStatusID',
    'GenderID',
    'EmpStatusID',
    'DeptID',
    'PerfScoreID',
    'FromDiversityJobFairID',
    'Salary',
    'Termd',
    'PositionID',
    'Position',
    'State',
    'Zip',
    'DOB',
    'Sex',
    'MaritalDesc',
    'CitizenDesc',
    'HispanicLatino',
    'RaceDesc',
    'DateofHire',
    'DateofTermination',
    'TermReason',
    'EmploymentStatus',
    'Department',
    'ManagerName',
    'ManagerID',
    'RecruitmentSource',
    'PerformanceScore',
    'EngagementSurvey',
    'EmpSatisfaction',
    'SpecialProjectsCount',
    'LastPerformanceReview_Date',
    'DaysLateLast30',
    'Absences'
)

$DerivedHeaders = @(
    'Age',
    'AgeGroup',
    'Tenure',
    'TerminationFlag',
    'SalaryBand',
    'AbsenceLevel'
)

$TokenPattern = '"(?:[^"]|"")*"|\S+'
$Culture = [System.Globalization.CultureInfo]::InvariantCulture
$DobFormats = @('MM/dd/yy', 'M/d/yy')
$DateFormats = @('M/d/yyyy', 'MM/dd/yyyy')

$NumericPatterns = @{
    EmpID = '^\d+$'
    MarriedID = '^\d+$'
    MaritalStatusID = '^\d+$'
    GenderID = '^\d+$'
    EmpStatusID = '^\d+$'
    DeptID = '^\d+$'
    PerfScoreID = '^\d+$'
    FromDiversityJobFairID = '^\d+$'
    Salary = '^\d+$'
    Termd = '^\d+$'
    PositionID = '^\d+$'
    Zip = '^\d+$'
    ManagerID = '^\d+$'
    EngagementSurvey = '^\d+(?:\.\d+)?$'
    EmpSatisfaction = '^\d+$'
    SpecialProjectsCount = '^\d+$'
    DaysLateLast30 = '^\d+$'
    Absences = '^\d+$'
}

function Unquote-Token {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        $trimmed = $trimmed.Substring(1, $trimmed.Length - 2) -replace '""', '"'
    }

    return $trimmed.Trim()
}

function Parse-DateValue {
    param(
        [AllowNull()][string]$Value,
        [string[]]$Formats,
        [string]$ColumnName,
        [int]$LineNumber,
        [switch]$AllowBlank
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowBlank) {
            return $null
        }

        throw "Line ${LineNumber}: $ColumnName is empty."
    }

    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact(
        $Value,
        $Formats,
        $Culture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )

    if (-not $ok) {
        throw "Line ${LineNumber}: $ColumnName contains an invalid date '$Value'."
    }

    return $parsed.Date
}

function Get-FullYears {
    param(
        [datetime]$StartDate,
        [datetime]$EndDate
    )

    $years = $EndDate.Year - $StartDate.Year
    if ($EndDate.AddYears(-$years) -lt $StartDate) {
        $years--
    }

    return $years
}

function Get-AgeGroup {
    param([int]$Age)

    if ($Age -lt 30) { return '20-29' }
    if ($Age -lt 40) { return '30-39' }
    if ($Age -lt 50) { return '40-49' }
    return '50+'
}

function Get-SalaryBand {
    param([int]$Salary)

    if ($Salary -lt 50000) { return 'Low' }
    if ($Salary -lt 80000) { return 'Medium' }
    return 'High'
}

function Get-AbsenceLevel {
    param([int]$Absences)

    if ($Absences -le 5) { return 'Low' }
    if ($Absences -le 15) { return 'Medium' }
    return 'High'
}

function Assert-NumericFields {
    param(
        [hashtable]$Record,
        [int]$LineNumber
    )

    foreach ($entry in $NumericPatterns.GetEnumerator()) {
        $columnName = $entry.Key
        $pattern = $entry.Value
        $value = [string]$Record[$columnName]

        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($columnName -eq 'ManagerID') {
                continue
            }

            throw "Line ${LineNumber}: $columnName is empty but should be numeric."
        }

        if ($value -notmatch $pattern) {
            throw "Line ${LineNumber}: $columnName contains an invalid numeric value '$value'."
        }
    }
}

function Parse-SourceLine {
    param(
        [string]$Line,
        [int]$LineNumber
    )

    $tokens = [regex]::Matches($Line, $TokenPattern) | ForEach-Object { $_.Value }

    if ($tokens.Count -lt 34 -or $tokens.Count -gt 36) {
        throw "Line ${LineNumber}: unexpected token count $($tokens.Count)."
    }

    $record = [ordered]@{}

    for ($index = 0; $index -le 21; $index++) {
        $record[$Headers[$index]] = Unquote-Token $tokens[$index]
    }

    $remainder = @($tokens[22..($tokens.Count - 1)])
    if ($remainder.Count -lt 12) {
        throw "Line ${LineNumber}: unable to rebuild the variable section."
    }

    $tail = @($remainder[($remainder.Count - 8)..($remainder.Count - 1)])
    $core = if ($remainder.Count -gt 8) { @($remainder[0..($remainder.Count - 9)]) } else { @() }

    $managerId = ''
    if ($core.Count -gt 0 -and $core[-1] -match '^\d+$') {
        $managerId = Unquote-Token $core[-1]
        $core = if ($core.Count -gt 1) { @($core[0..($core.Count - 2)]) } else { @() }
    }

    switch ($core.Count) {
        5 {
            $record['DateofTermination'] = Unquote-Token $core[0]
            $record['TermReason'] = Unquote-Token $core[1]
            $record['EmploymentStatus'] = Unquote-Token $core[2]
            $record['Department'] = Unquote-Token $core[3]
            $record['ManagerName'] = Unquote-Token $core[4]
        }
        4 {
            $record['DateofTermination'] = ''
            $record['TermReason'] = Unquote-Token $core[0]
            $record['EmploymentStatus'] = Unquote-Token $core[1]
            $record['Department'] = Unquote-Token $core[2]
            $record['ManagerName'] = Unquote-Token $core[3]
        }
        default {
            throw "Line ${LineNumber}: unexpected variable section size $($core.Count)."
        }
    }

    $record['ManagerID'] = $managerId
    $record['RecruitmentSource'] = Unquote-Token $tail[0]
    $record['PerformanceScore'] = Unquote-Token $tail[1]
    $record['EngagementSurvey'] = Unquote-Token $tail[2]
    $record['EmpSatisfaction'] = Unquote-Token $tail[3]
    $record['SpecialProjectsCount'] = Unquote-Token $tail[4]
    $record['LastPerformanceReview_Date'] = Unquote-Token $tail[5]
    $record['DaysLateLast30'] = Unquote-Token $tail[6]
    $record['Absences'] = Unquote-Token $tail[7]

    Assert-NumericFields -Record $record -LineNumber $LineNumber

    $dob = Parse-DateValue -Value $record['DOB'] -Formats $DobFormats -ColumnName 'DOB' -LineNumber $LineNumber
    $hireDate = Parse-DateValue -Value $record['DateofHire'] -Formats $DateFormats -ColumnName 'DateofHire' -LineNumber $LineNumber
    $terminationDate = Parse-DateValue -Value $record['DateofTermination'] -Formats $DateFormats -ColumnName 'DateofTermination' -LineNumber $LineNumber -AllowBlank
    $reviewDate = Parse-DateValue -Value $record['LastPerformanceReview_Date'] -Formats $DateFormats -ColumnName 'LastPerformanceReview_Date' -LineNumber $LineNumber

    $record['DOB'] = $dob.ToString('yyyy-MM-dd', $Culture)
    $record['DateofHire'] = $hireDate.ToString('yyyy-MM-dd', $Culture)
    $record['DateofTermination'] = if ($null -eq $terminationDate) { '' } else { $terminationDate.ToString('yyyy-MM-dd', $Culture) }
    $record['LastPerformanceReview_Date'] = $reviewDate.ToString('yyyy-MM-dd', $Culture)

    $salary = [int]$record['Salary']
    $termd = [int]$record['Termd']
    $absences = [int]$record['Absences']

    if ($termd -notin 0, 1) {
        throw "Line ${LineNumber}: Termd should be 0 or 1, received '$termd'."
    }

    if ($termd -eq 1 -and [string]::IsNullOrWhiteSpace($record['DateofTermination'])) {
        throw "Line ${LineNumber}: terminated employee is missing DateofTermination."
    }

    if ($termd -eq 0 -and -not [string]::IsNullOrWhiteSpace($record['DateofTermination'])) {
        throw "Line ${LineNumber}: active employee should not have DateofTermination."
    }

    if ($hireDate -lt $dob) {
        throw "Line ${LineNumber}: DateofHire is earlier than DOB."
    }

    $age = Get-FullYears -StartDate $dob -EndDate $ReferenceDate
    $tenureEndDate = if ($null -ne $terminationDate) { $terminationDate } else { $ReferenceDate }
    $tenure = Get-FullYears -StartDate $hireDate -EndDate $tenureEndDate

    if ($age -lt 0) {
        throw "Line ${LineNumber}: computed Age is negative."
    }

    if ($tenure -lt 0) {
        throw "Line ${LineNumber}: computed Tenure is negative."
    }

    $record['Age'] = [string]$age
    $record['AgeGroup'] = Get-AgeGroup -Age $age
    $record['Tenure'] = [string]$tenure
    $record['TerminationFlag'] = [string]$termd
    $record['SalaryBand'] = Get-SalaryBand -Salary $salary
    $record['AbsenceLevel'] = Get-AbsenceLevel -Absences $absences

    return [pscustomobject]$record
}

function ConvertTo-CsvField {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $text = [string]$Value
    $escaped = $text -replace '"', '""'
    if ($text.IndexOfAny(@([char]',', [char]'"', [char]10, [char]13)) -ge 0) {
        return '"' + $escaped + '"'
    }

    return $escaped
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input file not found: $InputPath"
}

$sourceLines = Get-Content -LiteralPath $InputPath
if ($sourceLines.Count -lt 2) {
    throw 'The source file does not contain a header and data rows.'
}

$headerTokens = [regex]::Matches($sourceLines[0], $TokenPattern) | ForEach-Object { $_.Value }
if ($headerTokens.Count -ne $Headers.Count) {
    throw "Unexpected header width: $($headerTokens.Count) columns found."
}

$cleanRows = New-Object System.Collections.Generic.List[object]
for ($lineIndex = 1; $lineIndex -lt $sourceLines.Count; $lineIndex++) {
    if ([string]::IsNullOrWhiteSpace($sourceLines[$lineIndex])) {
        continue
    }

    $cleanRows.Add((Parse-SourceLine -Line $sourceLines[$lineIndex] -LineNumber ($lineIndex + 1)))
}

$managerIdByNameAndTermd = @{}
foreach ($group in ($cleanRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ManagerID) } | Group-Object { '{0}|{1}' -f $_.ManagerName, $_.Termd })) {
    $ids = $group.Group.ManagerID | Sort-Object -Unique
    if ($ids.Count -eq 1) {
        $managerIdByNameAndTermd[$group.Name] = $ids[0]
    }
}

$managerIdByName = @{}
foreach ($group in ($cleanRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ManagerID) } | Group-Object ManagerName)) {
    $ids = $group.Group.ManagerID | Sort-Object -Unique
    if ($ids.Count -eq 1) {
        $managerIdByName[$group.Name] = $ids[0]
    }
}

$imputedManagerIdCount = 0
foreach ($row in $cleanRows) {
    if (-not [string]::IsNullOrWhiteSpace($row.ManagerID)) {
        continue
    }

    $managerKey = '{0}|{1}' -f $row.ManagerName, $row.Termd
    if ($managerIdByNameAndTermd.ContainsKey($managerKey)) {
        $row.ManagerID = $managerIdByNameAndTermd[$managerKey]
        $imputedManagerIdCount++
        continue
    }

    if ($managerIdByName.ContainsKey($row.ManagerName)) {
        $row.ManagerID = $managerIdByName[$row.ManagerName]
        $imputedManagerIdCount++
    }
}

$expectedColumnCount = $Headers.Count + $DerivedHeaders.Count
if ($cleanRows.Count -ne 311) {
    throw "Unexpected row count after cleaning: $($cleanRows.Count)."
}

$empIds = $cleanRows | ForEach-Object { $_.EmpID }
if (($empIds | Sort-Object -Unique).Count -ne $cleanRows.Count) {
    throw 'EmpID values are not unique after cleaning.'
}

$activeCount = ($cleanRows | Where-Object { $_.Termd -eq '0' }).Count
$terminatedCount = ($cleanRows | Where-Object { $_.Termd -eq '1' }).Count
$terminationFlagMismatch = ($cleanRows | Where-Object { $_.Termd -ne $_.TerminationFlag }).Count
$activeWithTerminationDate = ($cleanRows | Where-Object { $_.Termd -eq '0' -and -not [string]::IsNullOrWhiteSpace($_.DateofTermination) }).Count
$terminatedWithoutTerminationDate = ($cleanRows | Where-Object { $_.Termd -eq '1' -and [string]::IsNullOrWhiteSpace($_.DateofTermination) }).Count
$missingManagerIdCount = ($cleanRows | Where-Object { [string]::IsNullOrWhiteSpace($_.ManagerID) }).Count
$negativeDerivedValues = ($cleanRows | Where-Object { [int]$_.Age -lt 0 -or [int]$_.Tenure -lt 0 }).Count

if ($activeCount -ne 207) {
    throw "Unexpected active row count: $activeCount."
}

if ($terminatedCount -ne 104) {
    throw "Unexpected terminated row count: $terminatedCount."
}

if ($terminationFlagMismatch -ne 0) {
    throw 'TerminationFlag does not match Termd for every row.'
}

if ($activeWithTerminationDate -ne 0) {
    throw 'Active employees should not have DateofTermination.'
}

if ($terminatedWithoutTerminationDate -ne 0) {
    throw 'Terminated employees should have DateofTermination.'
}

if ($missingManagerIdCount -ne 0) {
    throw "Unresolved blank ManagerID count: $missingManagerIdCount."
}

if ($negativeDerivedValues -ne 0) {
    throw 'Derived Age or Tenure contains negative values.'
}

$allHeaders = @($Headers + $DerivedHeaders)
$csvLines = New-Object System.Collections.Generic.List[string]
$headerLine = (($allHeaders | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
$csvLines.Add($headerLine)

foreach ($row in $cleanRows) {
    $values = foreach ($header in $allHeaders) {
        ConvertTo-CsvField $row.$header
    }

    $rowLine = (($values) -join ',')
    $csvLines.Add($rowLine)
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($OutputPath, $csvLines, $utf8NoBom)

[pscustomobject]@{
    OutputPath = $OutputPath
    Rows = $cleanRows.Count
    Columns = $expectedColumnCount
    ActiveRows = $activeCount
    TerminatedRows = $terminatedCount
    BlankDateofTermination = ($cleanRows | Where-Object { [string]::IsNullOrWhiteSpace($_.DateofTermination) }).Count
    BlankManagerID = $missingManagerIdCount
    ImputedManagerID = $imputedManagerIdCount
    ReferenceDate = $ReferenceDate.ToString('yyyy-MM-dd', $Culture)
} | Format-List
