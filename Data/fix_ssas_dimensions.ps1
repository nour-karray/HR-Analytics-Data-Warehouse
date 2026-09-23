param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath
)

$ErrorActionPreference = 'Stop'

$engineNs = 'http://schemas.microsoft.com/analysisservices/2003/engine'
$xsiNs = 'http://www.w3.org/2001/XMLSchema-instance'

$dsvPath = Join-Path $ProjectPath 'DW_RH_DSV.dsv'
if (-not (Test-Path -LiteralPath $dsvPath)) {
    throw "DSV introuvable: $dsvPath"
}

$dsvText = Get-Content -LiteralPath $dsvPath -Raw
$factMatch = [regex]::Match(
    $dsvText,
    '<xs:element name="dbo_FactAttendancePerformance"[\s\S]*?</xs:element>\s*<xs:element name="dbo_FactEmploymentCompensation"',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)

if (-not $factMatch.Success) {
    throw "Impossible de lire dbo_FactAttendancePerformance dans la DSV."
}

$factBlock = $factMatch.Value
$hasPerformanceKey = $factBlock.Contains('name="PerformanceKey"')
$hasRecruitmentKey = $factBlock.Contains('name="RecruitmentKey"')

$configs = @(
    @{
        File = 'Dim Employee.dim'
        AttributeId = 'Employee Key'
        AttributeName = 'EmpID'
        TableId = 'dbo_DimEmployee'
        KeyColumn = 'EmpID'
        KeyDataType = 'Integer'
        NameColumn = 'Employee_Name'
        NameDataType = 'WChar'
    }
    @{
        File = 'Dim Department.dim'
        AttributeId = 'Department Key'
        AttributeName = 'DeptID'
        TableId = 'dbo_DimDepartment'
        KeyColumn = 'DeptID'
        KeyDataType = 'Integer'
        NameColumn = 'Department'
        NameDataType = 'WChar'
    }
    @{
        File = 'Dim Position.dim'
        AttributeId = 'Position Key'
        AttributeName = 'PositionID'
        TableId = 'dbo_DimPosition'
        KeyColumn = 'PositionID'
        KeyDataType = 'Integer'
        NameColumn = 'Position'
        NameDataType = 'WChar'
    }
    @{
        File = 'Dim Manager.dim'
        AttributeId = 'Manager Key'
        AttributeName = 'ManagerID'
        TableId = 'dbo_DimManager'
        KeyColumn = 'ManagerID'
        KeyDataType = 'Integer'
        NameColumn = 'ManagerName'
        NameDataType = 'WChar'
    }
    @{
        File = 'Dim Date.dim'
        AttributeId = 'Date Key'
        AttributeName = 'FullDate'
        TableId = 'dbo_DimDate'
        KeyColumn = 'FullDate'
        KeyDataType = 'WChar'
        NameColumn = 'FullDate'
        NameDataType = 'WChar'
    }
    @{
        File = 'Dim Performance.dim'
        AttributeId = 'Performance Key'
        AttributeName = $(if ($hasPerformanceKey) { 'PerformanceKey' } else { 'PerfScoreID' })
        TableId = 'dbo_DimPerformance'
        KeyColumn = $(if ($hasPerformanceKey) { 'PerformanceKey' } else { 'PerfScoreID' })
        KeyDataType = 'Integer'
        NameColumn = 'PerformanceScore'
        NameDataType = 'WChar'
    }
    @{
        File = 'Dim Recruitment.dim'
        AttributeId = 'Recruitment Key'
        AttributeName = $(if ($hasRecruitmentKey) { 'RecruitmentKey' } else { 'FromDiversityJobFairID' })
        TableId = 'dbo_DimRecruitment'
        KeyColumn = $(if ($hasRecruitmentKey) { 'RecruitmentKey' } else { 'FromDiversityJobFairID' })
        KeyDataType = 'Integer'
        NameColumn = 'RecruitmentSource'
        NameDataType = 'WChar'
    }
)

function New-EngineElement {
    param(
        [xml]$Doc,
        [string]$Name
    )

    return $Doc.CreateElement($Name, $engineNs)
}

foreach ($config in $configs) {
    $filePath = Join-Path $ProjectPath $config.File
    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "Dimension introuvable: $filePath"
    }

    [xml]$doc = Get-Content -LiteralPath $filePath
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('a', $engineNs)
    $ns.AddNamespace('xsi', $xsiNs)

    $attribute = $doc.SelectSingleNode("/a:Dimension/a:Attributes/a:Attribute[a:ID='$($config.AttributeId)']", $ns)
    if ($null -eq $attribute) {
        throw "Attribut '$($config.AttributeId)' introuvable dans $($config.File)"
    }

    $nameNode = $attribute.SelectSingleNode("a:Name", $ns)
    $nameNode.InnerText = $config.AttributeName

    $keyColumn = $attribute.SelectSingleNode("a:KeyColumns/a:KeyColumn", $ns)
    $keyColumn.SelectSingleNode("a:DataType", $ns).InnerText = $config.KeyDataType

    $keySource = $keyColumn.SelectSingleNode("a:Source", $ns)
    $keySource.SelectSingleNode("a:TableID", $ns).InnerText = $config.TableId
    $keySource.SelectSingleNode("a:ColumnID", $ns).InnerText = $config.KeyColumn

    $existingNameColumn = $attribute.SelectSingleNode("a:NameColumn", $ns)
    if ($existingNameColumn -ne $null) {
        [void]$attribute.RemoveChild($existingNameColumn)
    }

    $nameColumn = New-EngineElement -Doc $doc -Name 'NameColumn'
    $dataType = New-EngineElement -Doc $doc -Name 'DataType'
    $dataType.InnerText = $config.NameDataType
    [void]$nameColumn.AppendChild($dataType)

    $source = New-EngineElement -Doc $doc -Name 'Source'
    $xsiType = $doc.CreateAttribute('xsi', 'type', $xsiNs)
    $xsiType.Value = 'ColumnBinding'
    [void]$source.Attributes.Append($xsiType)

    $tableId = New-EngineElement -Doc $doc -Name 'TableID'
    $tableId.InnerText = $config.TableId
    [void]$source.AppendChild($tableId)

    $columnId = New-EngineElement -Doc $doc -Name 'ColumnID'
    $columnId.InnerText = $config.NameColumn
    [void]$source.AppendChild($columnId)

    [void]$nameColumn.AppendChild($source)

    $keyColumnsNode = $attribute.SelectSingleNode("a:KeyColumns", $ns)
    $orderByNode = $attribute.SelectSingleNode("a:OrderBy", $ns)
    [void]$attribute.InsertAfter($nameColumn, $keyColumnsNode)

    if ($orderByNode -ne $null) {
        $orderByNode.InnerText = 'Key'
    }

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.OmitXmlDeclaration = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)

    $writer = [System.Xml.XmlWriter]::Create($filePath, $settings)
    try {
        $doc.Save($writer)
    }
    finally {
        $writer.Dispose()
    }

    [pscustomobject]@{
        File = $config.File
        KeyColumn = $config.KeyColumn
        NameColumn = $config.NameColumn
    }
}
