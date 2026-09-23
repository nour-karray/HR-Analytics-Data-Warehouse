param(
    [string]$TemplatePath = (Join-Path $PSScriptRoot 'Dimensions.dtsx'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Dimensions.dtsx')
)

$ErrorActionPreference = 'Stop'

$ConversionComponentName = 'Conversion de donn' + [char]0x00E9 + 'es'
$ConversionInputName = 'Entr' + [char]0x00E9 + 'e de conversion de donn' + [char]0x00E9 + 'es'
$ConversionOutputName = 'Sortie de conversion de donn' + [char]0x00E9 + 'es'
$LookupInputName = 'Entr' + [char]0x00E9 + 'e de recherche'
$DestinationInputName = 'Entr' + [char]0x00E9 + 'e de destination OLE DB'

function Update-OleDbProvider {
    param(
        [System.Xml.XmlDocument]$PackageDoc
    )

    $connectionManagers = $PackageDoc.SelectNodes('/DTS:Executable/DTS:ConnectionManagers/DTS:ConnectionManager/DTS:ObjectData/DTS:ConnectionManager', $namespaceManager)
    foreach ($connectionManager in $connectionManagers) {
        $connectionString = $connectionManager.GetAttribute('ConnectionString', 'www.microsoft.com/SqlServer/Dts')
        if ($connectionString -and $connectionString.Contains('Provider=SQLOLEDB.1')) {
            $updated = $connectionString.Replace('Provider=SQLOLEDB.1', 'Provider=MSOLEDBSQL.1')
            $connectionManager.SetAttribute('ConnectionString', 'www.microsoft.com/SqlServer/Dts', $updated)
        }
    }
}

function New-GuidText {
    '{' + ([guid]::NewGuid().ToString().ToUpperInvariant()) + '}'
}

function Set-DtsAttr {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$LocalName,
        [string]$Value
    )

    $ns = 'www.microsoft.com/SqlServer/Dts'
    if ($Element.HasAttribute($LocalName, $ns)) {
        [void]$Element.SetAttribute($LocalName, $ns, $Value)
        return
    }

    $attr = $Element.Attributes.GetNamedItem("DTS:$LocalName")
    if ($null -ne $attr) {
        $attr.Value = $Value
        return
    }

    $prefix = if ($Element.Prefix) { $Element.Prefix } else { 'DTS' }
    $newAttr = $Element.OwnerDocument.CreateAttribute($prefix, $LocalName, $ns)
    $newAttr.Value = $Value
    [void]$Element.Attributes.Append($newAttr)
}

function Set-Attr {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$Name,
        [string]$Value
    )

    [void]$Element.SetAttribute($Name, $Value)
}

function Remove-Attr {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$Name
    )

    if ($Element.HasAttribute($Name)) {
        $Element.RemoveAttribute($Name)
    }
}

function Clear-Children {
    param([System.Xml.XmlNode]$Node)

    while ($Node.HasChildNodes) {
        [void]$Node.RemoveChild($Node.FirstChild)
    }
}

function Replace-InNode {
    param(
        [System.Xml.XmlNode]$Node,
        [string]$OldValue,
        [string]$NewValue
    )

    if ($Node.NodeType -in [System.Xml.XmlNodeType]::Text, [System.Xml.XmlNodeType]::CDATA) {
        if ($Node.Value -and $Node.Value.Contains($OldValue)) {
            $Node.Value = $Node.Value.Replace($OldValue, $NewValue)
        }
    }

    if ($Node.Attributes) {
        foreach ($attribute in @($Node.Attributes)) {
            if ($attribute.Value -and $attribute.Value.Contains($OldValue)) {
                $attribute.Value = $attribute.Value.Replace($OldValue, $NewValue)
            }
        }
    }

    foreach ($child in @($Node.ChildNodes)) {
        Replace-InNode -Node $child -OldValue $OldValue -NewValue $NewValue
    }
}

function Refresh-DtsIds {
    param(
        [System.Xml.XmlElement]$Element,
        [System.Xml.XmlNamespaceManager]$NamespaceManager
    )

    foreach ($node in @($Element.SelectNodes('.//*[@DTS:DTSID]', $NamespaceManager))) {
        Set-DtsAttr -Element $node -LocalName 'DTSID' -Value (New-GuidText)
    }

    if ($Element.HasAttribute('DTSID', 'www.microsoft.com/SqlServer/Dts')) {
        Set-DtsAttr -Element $Element -LocalName 'DTSID' -Value (New-GuidText)
    }
}

function Set-TypeAttributes {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$Mode,
        [hashtable]$Column
    )

    switch ($Mode) {
        'data' {
            Set-Attr -Element $Element -Name 'dataType' -Value $Column.Type
            if ($Column.Type -eq 'wstr') {
                Set-Attr -Element $Element -Name 'length' -Value ([string]$Column.Length)
                Remove-Attr -Element $Element -Name 'codePage'
            } elseif ($Column.Type -eq 'str') {
                Set-Attr -Element $Element -Name 'length' -Value ([string]$Column.Length)
                Set-Attr -Element $Element -Name 'codePage' -Value '1252'
            } else {
                Remove-Attr -Element $Element -Name 'length'
                Remove-Attr -Element $Element -Name 'codePage'
            }

            Remove-Attr -Element $Element -Name 'precision'
            Remove-Attr -Element $Element -Name 'scale'
        }
        'cached' {
            Set-Attr -Element $Element -Name 'cachedDataType' -Value $Column.Type
            if ($Column.Type -eq 'wstr') {
                Set-Attr -Element $Element -Name 'cachedLength' -Value ([string]$Column.Length)
                Remove-Attr -Element $Element -Name 'cachedCodepage'
            } elseif ($Column.Type -eq 'str') {
                Set-Attr -Element $Element -Name 'cachedLength' -Value ([string]$Column.Length)
                Set-Attr -Element $Element -Name 'cachedCodepage' -Value '1252'
            } else {
                Remove-Attr -Element $Element -Name 'cachedLength'
                Remove-Attr -Element $Element -Name 'cachedCodepage'
            }
        }
        default {
            throw "Unknown type mode: $Mode"
        }
    }
}

function New-ReferenceMetadataXml {
    param([hashtable]$Config)

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(('<referenceColumn name="{0}" dataType="DT_I4" length="0" precision="0" scale="0" codePage="0"/>' -f $Config.Key))

    foreach ($column in $Config.Columns) {
        $length = if ($column.LookupType -eq 'DT_WSTR') { [string]$column.Length } else { '0' }
        $parts.Add(('<referenceColumn name="{0}" dataType="{1}" length="{2}" precision="0" scale="0" codePage="0"/>' -f $column.Target, $column.LookupType, $length))
    }

    '<referenceMetadata><referenceColumns>' + ($parts -join '') + '</referenceColumns></referenceMetadata>'
}

function Update-SourceComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [hashtable]$Config
    )

    $sourceComponent = $Task.SelectSingleNode(".//component[@componentClassID='Microsoft.FlatFileSource']")
    $sourceOutput = $sourceComponent.SelectSingleNode('outputs/output[1]')
    $outputColumnsParent = $sourceOutput.SelectSingleNode('outputColumns')
    $templateOutputColumn = $outputColumnsParent.SelectSingleNode('outputColumn').CloneNode($true)

    Clear-Children -Node $outputColumnsParent

    foreach ($column in $Config.Columns) {
        $newColumn = $templateOutputColumn.CloneNode($true)
        $baseRef = "Package\$($Config.Name)\Source du fichier plat.Outputs[Sortie de source de fichier plat]"

        Set-Attr -Element $newColumn -Name 'refId' -Value "$baseRef.Columns[$($column.Source)]"
        Set-Attr -Element $newColumn -Name 'externalMetadataColumnId' -Value "$baseRef.ExternalColumns[$($column.Source)]"
        Set-Attr -Element $newColumn -Name 'lineageId' -Value "$baseRef.Columns[$($column.Source)]"
        Set-Attr -Element $newColumn -Name 'name' -Value $column.Source
        Set-Attr -Element $newColumn -Name 'codePage' -Value '1252'
        Set-Attr -Element $newColumn -Name 'dataType' -Value 'str'
        Set-Attr -Element $newColumn -Name 'length' -Value '50'

        [void]$outputColumnsParent.AppendChild($newColumn)
    }
}

function Update-ConversionComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [hashtable]$Config
    )

    $conversionComponent = $Task.SelectSingleNode(".//component[@componentClassID='Microsoft.DataConvert']")
    $inputParent = $conversionComponent.SelectSingleNode('inputs/input[1]/inputColumns')
    $outputParent = $conversionComponent.SelectSingleNode('outputs/output[1]/outputColumns')

    $templateInputColumn = $inputParent.SelectSingleNode('inputColumn').CloneNode($true)
    $templateOutputColumn = $outputParent.SelectSingleNode('outputColumn').CloneNode($true)

    Clear-Children -Node $inputParent
    Clear-Children -Node $outputParent

    foreach ($column in $Config.Columns) {
        $sourceLineage = "Package\$($Config.Name)\Source du fichier plat.Outputs[Sortie de source de fichier plat].Columns[$($column.Source)]"

        $newInput = $templateInputColumn.CloneNode($true)
        Set-Attr -Element $newInput -Name 'refId' -Value "Package\$($Config.Name)\$ConversionComponentName.Inputs[$ConversionInputName].Columns[$($column.Source)]"
        Set-Attr -Element $newInput -Name 'cachedName' -Value $column.Source
        Set-Attr -Element $newInput -Name 'lineageId' -Value $sourceLineage
        Set-Attr -Element $newInput -Name 'cachedCodepage' -Value '1252'
        Set-Attr -Element $newInput -Name 'cachedDataType' -Value 'str'
        Set-Attr -Element $newInput -Name 'cachedLength' -Value '50'
        [void]$inputParent.AppendChild($newInput)

        $newOutput = $templateOutputColumn.CloneNode($true)
        Set-Attr -Element $newOutput -Name 'refId' -Value "Package\$($Config.Name)\$ConversionComponentName.Outputs[$ConversionOutputName].Columns[$($column.Output)]"
        Set-Attr -Element $newOutput -Name 'lineageId' -Value "Package\$($Config.Name)\$ConversionComponentName.Outputs[$ConversionOutputName].Columns[$($column.Output)]"
        Set-Attr -Element $newOutput -Name 'name' -Value $column.Output
        Set-TypeAttributes -Element $newOutput -Mode 'data' -Column $column
        $conversionDisposition = if ($column.DropInvalidRows) { 'RedirectRow' } else { 'FailComponent' }
        Set-Attr -Element $newOutput -Name 'errorRowDisposition' -Value $conversionDisposition
        Set-Attr -Element $newOutput -Name 'truncationRowDisposition' -Value $conversionDisposition

        $sourceProperty = $newOutput.SelectSingleNode("properties/property[@name='SourceInputColumnLineageID']")
        $sourceProperty.InnerText = "#{$sourceLineage}"

        [void]$outputParent.AppendChild($newOutput)
    }
}

function Update-LookupComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [hashtable]$Config
    )

    $lookupComponent = $Task.SelectSingleNode(".//component[@componentClassID='Microsoft.Lookup']")
    $lookupTable = "[dbo].[$($Config.Table)]"
    $lookupComponent.SelectSingleNode("properties/property[@name='SqlCommand']").InnerText = "select * from $lookupTable"

    $predicate = ($Config.Columns | ForEach-Object { "[refTable].[$($_.Target)] = ?" }) -join ' and '
    $lookupComponent.SelectSingleNode("properties/property[@name='SqlCommandParam']").InnerText = "select * from (select * from $lookupTable) [refTable]`r`nwhere $predicate"
    $lookupComponent.SelectSingleNode("properties/property[@name='ReferenceMetadataXml']").InnerText = (New-ReferenceMetadataXml -Config $Config)
    $lookupComponent.SelectSingleNode("properties/property[@name='ParameterMap']").InnerText = (($Config.Columns | ForEach-Object { "#{$("Package\$($Config.Name)\$ConversionComponentName.Outputs[$ConversionOutputName].Columns[$($_.Output)]")}" }) -join ';')

    $inputParent = $lookupComponent.SelectSingleNode('inputs/input[1]/inputColumns')
    $templateInputColumn = $inputParent.SelectSingleNode('inputColumn').CloneNode($true)
    Clear-Children -Node $inputParent

    foreach ($column in $Config.Columns) {
        $newInput = $templateInputColumn.CloneNode($true)
        $lineage = "Package\$($Config.Name)\$ConversionComponentName.Outputs[$ConversionOutputName].Columns[$($column.Output)]"

        Set-Attr -Element $newInput -Name 'refId' -Value "Package\$($Config.Name)\Recherche.Inputs[$LookupInputName].Columns[$($column.Output)]"
        Set-Attr -Element $newInput -Name 'cachedName' -Value $column.Output
        Set-Attr -Element $newInput -Name 'lineageId' -Value $lineage
        Set-TypeAttributes -Element $newInput -Mode 'cached' -Column $column

        $newInput.SelectSingleNode("properties/property[@name='JoinToReferenceColumn']").InnerText = $column.Target
        $newInput.SelectSingleNode("properties/property[@name='CopyFromReferenceColumn']").InnerText = ''

        [void]$inputParent.AppendChild($newInput)
    }
}

function Update-DestinationComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [hashtable]$Config
    )

    $destinationComponent = $Task.SelectSingleNode(".//component[@componentClassID='Microsoft.OLEDBDestination']")
    $destinationComponent.SelectSingleNode("properties/property[@name='OpenRowset']").InnerText = "[dbo].[$($Config.Table)]"

    $inputNode = $destinationComponent.SelectSingleNode('inputs/input[1]')
    $inputColumnsParent = $inputNode.SelectSingleNode('inputColumns')
    $externalMetadataParent = $inputNode.SelectSingleNode('externalMetadataColumns')

    $templateInputColumn = $inputColumnsParent.SelectSingleNode('inputColumn').CloneNode($true)
    $templateExternalMetadata = $externalMetadataParent.SelectSingleNode('externalMetadataColumn').CloneNode($true)

    Clear-Children -Node $inputColumnsParent
    Clear-Children -Node $externalMetadataParent

    $keyColumn = $templateExternalMetadata.CloneNode($true)
    Set-Attr -Element $keyColumn -Name 'refId' -Value "Package\$($Config.Name)\Destination OLE DB.Inputs[$DestinationInputName].ExternalColumns[$($Config.Key)]"
    Set-Attr -Element $keyColumn -Name 'name' -Value $Config.Key
    Set-Attr -Element $keyColumn -Name 'dataType' -Value 'i4'
    Remove-Attr -Element $keyColumn -Name 'length'
    Remove-Attr -Element $keyColumn -Name 'codePage'
    [void]$externalMetadataParent.AppendChild($keyColumn)

    foreach ($column in $Config.Columns) {
        $newInput = $templateInputColumn.CloneNode($true)
        $lineage = "Package\$($Config.Name)\$ConversionComponentName.Outputs[$ConversionOutputName].Columns[$($column.Output)]"
        $externalRef = "Package\$($Config.Name)\Destination OLE DB.Inputs[$DestinationInputName].ExternalColumns[$($column.Target)]"

        Set-Attr -Element $newInput -Name 'refId' -Value "Package\$($Config.Name)\Destination OLE DB.Inputs[$DestinationInputName].Columns[$($column.Output)]"
        Set-Attr -Element $newInput -Name 'cachedName' -Value $column.Output
        Set-Attr -Element $newInput -Name 'externalMetadataColumnId' -Value $externalRef
        Set-Attr -Element $newInput -Name 'lineageId' -Value $lineage
        Set-TypeAttributes -Element $newInput -Mode 'cached' -Column $column
        [void]$inputColumnsParent.AppendChild($newInput)

        $externalColumn = $templateExternalMetadata.CloneNode($true)
        Set-Attr -Element $externalColumn -Name 'refId' -Value $externalRef
        Set-Attr -Element $externalColumn -Name 'name' -Value $column.Target
        Set-TypeAttributes -Element $externalColumn -Mode 'data' -Column $column
        [void]$externalMetadataParent.AppendChild($externalColumn)
    }
}

function Update-DesignerObjects {
    param(
        [System.Xml.XmlDocument]$DesignDoc,
        [hashtable[]]$Configs
    )

    $objects = $DesignDoc.SelectSingleNode('/Objects')
    $packageNode = $DesignDoc.SelectSingleNode('/Objects/Package[@design-time-name="Package"]')
    $graphLayout = $packageNode.SelectSingleNode('*[local-name()="LayoutInfo"]/*[local-name()="GraphLayout"]')
    $templateTaskHost = $DesignDoc.SelectSingleNode('/Objects/TaskHost[@design-time-name="Package\DimEmployee"]')
    $templateLookupMeta = $DesignDoc.SelectSingleNode('/Objects/PipelineComponentMetadata[@design-time-name="Package\DimEmployee\Recherche"]')
    $templateDestMeta = $DesignDoc.SelectSingleNode('/Objects/PipelineComponentMetadata[@design-time-name="Package\DimEmployee\Destination OLE DB"]')

    Clear-Children -Node $graphLayout

    foreach ($node in @($objects.SelectNodes('TaskHost | PipelineComponentMetadata'))) {
        [void]$objects.RemoveChild($node)
    }

    for ($i = 0; $i -lt $Configs.Count; $i++) {
        $config = $Configs[$i]
        $columnIndex = $i % 4
        $rowIndex = [math]::Floor($i / 4)
        $x = [int](80 + (240 * $columnIndex))
        $y = [int](40 + (100 * $rowIndex))
        $coords = @($x, $y)

        $nodeLayout = $DesignDoc.CreateElement('NodeLayout', $graphLayout.NamespaceURI)
        $nodeLayout.SetAttribute('Size', '170,41.6')
        $nodeLayout.SetAttribute('Id', "Package\$($config.Name)")
        $nodeLayout.SetAttribute('TopLeft', ('{0},{1}' -f $coords[0], $coords[1]))
        [void]$graphLayout.AppendChild($nodeLayout)

        $taskHost = $templateTaskHost.CloneNode($true)
        Replace-InNode -Node $taskHost -OldValue 'Package\DimEmployee' -NewValue ("Package\" + $config.Name)
        $taskHost.SetAttribute('design-time-name', "Package\$($config.Name)")
        [void]$objects.AppendChild($taskHost)

        $lookupMeta = $templateLookupMeta.CloneNode($true)
        Replace-InNode -Node $lookupMeta -OldValue 'Package\DimEmployee' -NewValue ("Package\" + $config.Name)
        $lookupMeta.SetAttribute('design-time-name', "Package\$($config.Name)\Recherche")
        $lookupMeta.SelectSingleNode('Properties/Property[Name="UsedTableName"]/Value').InnerText = "[dbo].[$($config.Table)]"
        [void]$objects.AppendChild($lookupMeta)

        $destMeta = $templateDestMeta.CloneNode($true)
        Replace-InNode -Node $destMeta -OldValue 'Package\DimEmployee' -NewValue ("Package\" + $config.Name)
        $destMeta.SetAttribute('design-time-name', "Package\$($config.Name)\Destination OLE DB")
        [void]$objects.AppendChild($destMeta)
    }

    $graphLayout.SetAttribute('Capacity', [string]$Configs.Count)
}

$dimensionConfigs = @(
    @{
        Name = 'DimEmployee'
        Table = 'DimEmployee'
        Key = 'EmployeeKey'
        Columns = @(
            @{ Source = 'EmpID'; Output = 'NewEmpID'; Target = 'EmpID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4' }
            @{ Source = 'Employee_Name'; Output = 'NewEmployee_Name'; Target = 'Employee_Name'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR' }
            @{ Source = 'Sex'; Output = 'NewSex'; Target = 'Sex'; Type = 'wstr'; Length = 10; LookupType = 'DT_WSTR' }
            @{ Source = 'MaritalDesc'; Output = 'NewMaritalDesc'; Target = 'MaritalDesc'; Type = 'wstr'; Length = 50; LookupType = 'DT_WSTR' }
            @{ Source = 'CitizenDesc'; Output = 'NewCitizenDesc'; Target = 'CitizenDesc'; Type = 'wstr'; Length = 50; LookupType = 'DT_WSTR' }
            @{ Source = 'HispanicLatino'; Output = 'NewHispanicLatino'; Target = 'HispanicLatino'; Type = 'wstr'; Length = 20; LookupType = 'DT_WSTR' }
            @{ Source = 'RaceDesc'; Output = 'NewRaceDesc'; Target = 'RaceDesc'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR' }
            @{ Source = 'DOB'; Output = 'NewDOB'; Target = 'DOB'; Type = 'dbDate'; Length = 0; LookupType = 'DT_DBDATE' }
            @{ Source = 'Age'; Output = 'NewAge'; Target = 'Age'; Type = 'i4'; Length = 0; LookupType = 'DT_I4' }
            @{ Source = 'AgeGroup'; Output = 'NewAgeGroup'; Target = 'AgeGroup'; Type = 'wstr'; Length = 20; LookupType = 'DT_WSTR' }
        )
    }
    @{
        Name = 'DimDepartment'
        Table = 'DimDepartment'
        Key = 'DepartmentKey'
        Columns = @(
            @{ Source = 'DeptID'; Output = 'NewDeptID'; Target = 'DeptID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4' }
            @{ Source = 'Department'; Output = 'NewDepartment'; Target = 'Department'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR' }
        )
    }
    @{
        Name = 'DimPosition'
        Table = 'DimPosition'
        Key = 'PositionKey'
        Columns = @(
            @{ Source = 'PositionID'; Output = 'NewPositionID'; Target = 'PositionID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4' }
            @{ Source = 'Position'; Output = 'NewPosition'; Target = 'Position'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR' }
        )
    }
    @{
        Name = 'DimManager'
        Table = 'DimManager'
        Key = 'ManagerKey'
        Columns = @(
            @{ Source = 'ManagerID'; Output = 'NewManagerID'; Target = 'ManagerID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4' }
            @{ Source = 'ManagerName'; Output = 'NewManagerName'; Target = 'ManagerName'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR' }
        )
    }
    @{
        Name = 'DimLocation'
        Table = 'DimLocation'
        Key = 'LocationKey'
        Columns = @(
            @{ Source = 'State'; Output = 'NewState'; Target = 'State'; Type = 'wstr'; Length = 10; LookupType = 'DT_WSTR' }
            @{ Source = 'Zip'; Output = 'NewZip'; Target = 'Zip'; Type = 'wstr'; Length = 20; LookupType = 'DT_WSTR' }
        )
    }
    @{
        Name = 'DimRecruitment'
        Table = 'DimRecruitment'
        Key = 'RecruitmentKey'
        Columns = @(
            @{ Source = 'RecruitmentSource'; Output = 'NewRecruitmentSource'; Target = 'RecruitmentSource'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR' }
            @{ Source = 'FromDiversityJobFairID'; Output = 'NewFromDiversityJobFairID'; Target = 'FromDiversityJobFairID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4' }
        )
    }
    @{
        Name = 'DimPerformance'
        Table = 'DimPerformance'
        Key = 'PerformanceKey'
        Columns = @(
            @{ Source = 'PerfScoreID'; Output = 'NewPerfScoreID'; Target = 'PerfScoreID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4' }
            @{ Source = 'PerformanceScore'; Output = 'NewPerformanceScore'; Target = 'PerformanceScore'; Type = 'wstr'; Length = 50; LookupType = 'DT_WSTR' }
        )
    }
    @{
        Name = 'DimDate'
        Table = 'DimDate'
        Key = 'DateKey'
        Columns = @(
            @{ Source = 'DateofHire'; Output = 'NewDateofHire'; Target = 'FullDate'; Type = 'dbDate'; Length = 0; LookupType = 'DT_DBDATE'; DropInvalidRows = $true }
        )
    }
)

if (-not (Test-Path -LiteralPath $TemplatePath)) {
    throw "Template package not found: $TemplatePath"
}

$packageDoc = New-Object System.Xml.XmlDocument
$packageDoc.PreserveWhitespace = $true
$packageDoc.Load($TemplatePath)

$namespaceManager = New-Object System.Xml.XmlNamespaceManager($packageDoc.NameTable)
$namespaceManager.AddNamespace('DTS', 'www.microsoft.com/SqlServer/Dts')

Update-OleDbProvider -PackageDoc $packageDoc

$templateTask = $packageDoc.SelectSingleNode("/DTS:Executable/DTS:Executables/DTS:Executable[@DTS:ObjectName='DimEmployee']", $namespaceManager)
if ($null -eq $templateTask) {
    throw 'Template DimEmployee task not found in package.'
}

$executablesNode = $packageDoc.SelectSingleNode('/DTS:Executable/DTS:Executables', $namespaceManager)
Clear-Children -Node $executablesNode

foreach ($config in $dimensionConfigs) {
    $taskClone = [System.Xml.XmlElement]$templateTask.CloneNode($true)
    Replace-InNode -Node $taskClone -OldValue 'Package\DimEmployee' -NewValue ("Package\" + $config.Name)
    Refresh-DtsIds -Element $taskClone -NamespaceManager $namespaceManager
    Set-DtsAttr -Element $taskClone -LocalName 'ObjectName' -Value $config.Name
    Set-DtsAttr -Element $taskClone -LocalName 'refId' -Value ("Package\" + $config.Name)
    Set-DtsAttr -Element $taskClone -LocalName 'CreationDate' -Value ((Get-Date).ToString('M/d/yyyy h:mm:ss tt'))

    Update-SourceComponent -Task $taskClone -Config $config
    Update-ConversionComponent -Task $taskClone -Config $config
    Update-LookupComponent -Task $taskClone -Config $config
    Update-DestinationComponent -Task $taskClone -Config $config

    [void]$executablesNode.AppendChild($taskClone)
}

Set-DtsAttr -Element $packageDoc.DocumentElement -LocalName 'VersionGUID' -Value (New-GuidText)
Set-DtsAttr -Element $packageDoc.DocumentElement -LocalName 'VersionBuild' -Value '12'

$designProperty = $packageDoc.SelectSingleNode('/DTS:Executable/DTS:DesignTimeProperties', $namespaceManager)
Clear-Children -Node $designProperty
[void]$designProperty.AppendChild($packageDoc.CreateCDataSection('<?xml version="1.0"?><Objects Version="8"></Objects>'))

$packageDoc.Save($OutputPath)

$normalizeScript = Join-Path $PSScriptRoot 'normalize_dimensions_with_sort.ps1'
if (Test-Path -LiteralPath $normalizeScript) {
    & $normalizeScript -PackagePath $OutputPath
}

$dimDateExpandScript = Join-Path $PSScriptRoot 'expand_dimdate_multi_dates.ps1'
if (Test-Path -LiteralPath $dimDateExpandScript) {
    & $dimDateExpandScript -PackagePath $OutputPath
}

[pscustomobject]@{
    OutputPath = $OutputPath
    Dimensions = $dimensionConfigs.Count
} | Format-List
