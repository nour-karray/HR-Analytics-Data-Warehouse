param(
    [string]$PackagePath = (Join-Path $PSScriptRoot 'Dimensions.dtsx'),
    [string]$SortTemplatePath = (Join-Path $PSScriptRoot 'Dimensions.dtsx')
)

$ErrorActionPreference = 'Stop'

$ConversionComponentName = 'Conversion de donn' + [char]0x00E9 + 'es'
$ConversionOutputName = 'Sortie de conversion de donn' + [char]0x00E9 + 'es'
$LookupInputName = 'Entr' + [char]0x00E9 + 'e de recherche'
$DestinationInputName = 'Entr' + [char]0x00E9 + 'e de destination OLE DB'
$SortComponentName = 'Trier'
$SortInputName = 'Entr' + [char]0x00E9 + 'e de tri'
$SortOutputName = 'Sortie de tri'

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

function Set-TypeAttributes {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$Mode,
        [hashtable]$Column
    )

    switch ($Mode) {
        'data' {
            Set-Attr -Element $Element -Name 'dataType' -Value $Column.Type
            switch ($Column.Type) {
                'wstr' {
                    Set-Attr -Element $Element -Name 'length' -Value ([string]$Column.Length)
                    Remove-Attr -Element $Element -Name 'codePage'
                }
                'str' {
                    Set-Attr -Element $Element -Name 'length' -Value ([string]$Column.Length)
                    Set-Attr -Element $Element -Name 'codePage' -Value '1252'
                }
                default {
                    Remove-Attr -Element $Element -Name 'length'
                    Remove-Attr -Element $Element -Name 'codePage'
                }
            }

            Remove-Attr -Element $Element -Name 'precision'
            Remove-Attr -Element $Element -Name 'scale'
        }
        'cached' {
            Set-Attr -Element $Element -Name 'cachedDataType' -Value $Column.Type
            switch ($Column.Type) {
                'wstr' {
                    Set-Attr -Element $Element -Name 'cachedLength' -Value ([string]$Column.Length)
                    Remove-Attr -Element $Element -Name 'cachedCodepage'
                }
                'str' {
                    Set-Attr -Element $Element -Name 'cachedLength' -Value ([string]$Column.Length)
                    Set-Attr -Element $Element -Name 'cachedCodepage' -Value '1252'
                }
                default {
                    Remove-Attr -Element $Element -Name 'cachedLength'
                    Remove-Attr -Element $Element -Name 'cachedCodepage'
                }
            }

            Remove-Attr -Element $Element -Name 'cachedPrecision'
            Remove-Attr -Element $Element -Name 'cachedScale'
        }
        default {
            throw "Mode inconnu: $Mode"
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

function Update-ConversionOutputs {
    param(
        [System.Xml.XmlElement]$Task,
        [hashtable]$Config
    )

    $conversionComponent = $Task.SelectSingleNode(".//component[@componentClassID='Microsoft.DataConvert']")
    foreach ($column in $Config.Columns) {
        $outputColumn = $conversionComponent.SelectSingleNode("outputs/output[@name='$ConversionOutputName']/outputColumns/outputColumn[@name='$($column.Output)']")
        if ($null -eq $outputColumn) {
            continue
        }

        Set-TypeAttributes -Element $outputColumn -Mode 'data' -Column $column
    }
}

function Ensure-SortComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [hashtable]$Config,
        [System.Xml.XmlElement]$TemplateSort
    )

    $pipeline = $Task.SelectSingleNode('DTS:ObjectData/pipeline', $namespaceManager)
    $componentsNode = $pipeline.SelectSingleNode('components')
    $sortComponent = $Task.SelectSingleNode(".//component[@componentClassID='Microsoft.Sort']")

    if ($null -eq $sortComponent) {
        $sortComponent = [System.Xml.XmlElement]$pipeline.OwnerDocument.ImportNode($TemplateSort, $true)
        [void]$componentsNode.AppendChild($sortComponent)
    }

    Set-Attr -Element $sortComponent -Name 'refId' -Value "Package\$($Config.Name)\$SortComponentName"
    Set-Attr -Element $sortComponent -Name 'name' -Value $SortComponentName
    $sortComponent.SelectSingleNode("properties/property[@name='EliminateDuplicates']").InnerText = 'true'

    $inputNode = $sortComponent.SelectSingleNode('inputs/input[1]')
    Set-Attr -Element $inputNode -Name 'refId' -Value "Package\$($Config.Name)\$SortComponentName.Inputs[$SortInputName]"
    Set-Attr -Element $inputNode -Name 'name' -Value $SortInputName

    $outputNode = $sortComponent.SelectSingleNode('outputs/output[1]')
    Set-Attr -Element $outputNode -Name 'refId' -Value "Package\$($Config.Name)\$SortComponentName.Outputs[$SortOutputName]"
    Set-Attr -Element $outputNode -Name 'name' -Value $SortOutputName

    $inputColumnsParent = $inputNode.SelectSingleNode('inputColumns')
    $outputColumnsParent = $outputNode.SelectSingleNode('outputColumns')
    $templateInputColumn = $sortComponent.SelectSingleNode('inputs/input[1]/inputColumns/inputColumn').CloneNode($true)
    $templateOutputColumn = $sortComponent.SelectSingleNode('outputs/output[1]/outputColumns/outputColumn').CloneNode($true)

    Clear-Children -Node $inputColumnsParent
    Clear-Children -Node $outputColumnsParent

    foreach ($column in $Config.Columns) {
        $conversionLineage = "Package\$($Config.Name)\$ConversionComponentName.Outputs[$ConversionOutputName].Columns[$($column.Output)]"

        $newInput = $templateInputColumn.CloneNode($true)
        Set-Attr -Element $newInput -Name 'refId' -Value "Package\$($Config.Name)\$SortComponentName.Inputs[$SortInputName].Columns[$($column.Output)]"
        Set-Attr -Element $newInput -Name 'cachedName' -Value $column.Output
        Set-Attr -Element $newInput -Name 'lineageId' -Value $conversionLineage
        Set-TypeAttributes -Element $newInput -Mode 'cached' -Column $column
        $newInput.SelectSingleNode("properties/property[@name='NewComparisonFlags']").InnerText = '0'
        $newInput.SelectSingleNode("properties/property[@name='NewSortKeyPosition']").InnerText = [string]$column.SortKey
        [void]$inputColumnsParent.AppendChild($newInput)

        $newOutput = $templateOutputColumn.CloneNode($true)
        Set-Attr -Element $newOutput -Name 'refId' -Value "Package\$($Config.Name)\$SortComponentName.Outputs[$SortOutputName].Columns[$($column.Output)]"
        Set-Attr -Element $newOutput -Name 'lineageId' -Value "Package\$($Config.Name)\$SortComponentName.Outputs[$SortOutputName].Columns[$($column.Output)]"
        Set-Attr -Element $newOutput -Name 'name' -Value $column.Output
        Set-TypeAttributes -Element $newOutput -Mode 'data' -Column $column

        if ($column.SortKey -gt 0) {
            Set-Attr -Element $newOutput -Name 'sortKeyPosition' -Value ([string]$column.SortKey)
        } else {
            Remove-Attr -Element $newOutput -Name 'sortKeyPosition'
        }

        $newOutput.SelectSingleNode("properties/property[@name='SortColumnId']").InnerText = "#{$conversionLineage}"
        [void]$outputColumnsParent.AppendChild($newOutput)
    }
}

function Update-LookupComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [hashtable]$Config
    )

    $lookupComponent = $Task.SelectSingleNode(".//component[@componentClassID='Microsoft.Lookup']")
    $lookupTable = "[dbo].[$($Config.Table)]"
    $joinColumns = @($Config.Columns | Where-Object { $_.Join })

    $predicate = ($joinColumns | ForEach-Object { "[refTable].[$($_.Target)] = ?" }) -join ' and '
    $parameterMap = ($joinColumns | ForEach-Object { "#{$("Package\$($Config.Name)\$SortComponentName.Outputs[$SortOutputName].Columns[$($_.Output)]")}" }) -join ';'

    $lookupComponent.SelectSingleNode("properties/property[@name='SqlCommand']").InnerText = "select * from $lookupTable"
    $lookupComponent.SelectSingleNode("properties/property[@name='SqlCommandParam']").InnerText = "select * from (select * from $lookupTable) [refTable]`r`nwhere $predicate"
    $lookupComponent.SelectSingleNode("properties/property[@name='ReferenceMetadataXml']").InnerText = (New-ReferenceMetadataXml -Config $Config)
    $lookupComponent.SelectSingleNode("properties/property[@name='ParameterMap']").InnerText = $parameterMap

    $inputParent = $lookupComponent.SelectSingleNode('inputs/input[1]/inputColumns')
    $templateInputColumn = $inputParent.SelectSingleNode('inputColumn').CloneNode($true)
    Clear-Children -Node $inputParent

    foreach ($column in $joinColumns) {
        $sortLineage = "Package\$($Config.Name)\$SortComponentName.Outputs[$SortOutputName].Columns[$($column.Output)]"
        $newInput = $templateInputColumn.CloneNode($true)

        Set-Attr -Element $newInput -Name 'refId' -Value "Package\$($Config.Name)\Recherche.Inputs[$LookupInputName].Columns[$($column.Output)]"
        Set-Attr -Element $newInput -Name 'cachedName' -Value $column.Output
        Set-Attr -Element $newInput -Name 'lineageId' -Value $sortLineage
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
        $sortLineage = "Package\$($Config.Name)\$SortComponentName.Outputs[$SortOutputName].Columns[$($column.Output)]"
        $externalRef = "Package\$($Config.Name)\Destination OLE DB.Inputs[$DestinationInputName].ExternalColumns[$($column.Target)]"

        $newInput = $templateInputColumn.CloneNode($true)
        Set-Attr -Element $newInput -Name 'refId' -Value "Package\$($Config.Name)\Destination OLE DB.Inputs[$DestinationInputName].Columns[$($column.Output)]"
        Set-Attr -Element $newInput -Name 'cachedName' -Value $column.Output
        Set-Attr -Element $newInput -Name 'externalMetadataColumnId' -Value $externalRef
        Set-Attr -Element $newInput -Name 'lineageId' -Value $sortLineage
        Set-TypeAttributes -Element $newInput -Mode 'cached' -Column $column
        [void]$inputColumnsParent.AppendChild($newInput)

        $externalColumn = $templateExternalMetadata.CloneNode($true)
        Set-Attr -Element $externalColumn -Name 'refId' -Value $externalRef
        Set-Attr -Element $externalColumn -Name 'name' -Value $column.Target
        Set-TypeAttributes -Element $externalColumn -Mode 'data' -Column $column
        [void]$externalMetadataParent.AppendChild($externalColumn)
    }
}

function Update-Paths {
    param(
        [System.Xml.XmlElement]$Task,
        [hashtable]$Config
    )

    $pathsNode = $Task.SelectSingleNode('DTS:ObjectData/pipeline/paths', $namespaceManager)
    $lookupInputId = "Package\$($Config.Name)\Recherche.Inputs[$LookupInputName]"
    $sortInputId = "Package\$($Config.Name)\$SortComponentName.Inputs[$SortInputName]"
    $sortOutputId = "Package\$($Config.Name)\$SortComponentName.Outputs[$SortOutputName]"
    $conversionOutputId = "Package\$($Config.Name)\$ConversionComponentName.Outputs[$ConversionOutputName]"

    $conversionPath = $pathsNode.SelectSingleNode("path[@startId='$conversionOutputId']")
    if ($null -eq $conversionPath) {
        throw "Chemin de sortie introuvable pour $($Config.Name)"
    }

    Set-Attr -Element $conversionPath -Name 'endId' -Value $sortInputId

    $sortPath = $pathsNode.SelectSingleNode("path[@startId='$sortOutputId']")
    if ($null -eq $sortPath) {
        $sortPath = $pathsNode.OwnerDocument.CreateElement('path')
        [void]$pathsNode.AppendChild($sortPath)
    }

    Set-Attr -Element $sortPath -Name 'refId' -Value "Package\$($Config.Name).Paths[$SortOutputName]"
    Set-Attr -Element $sortPath -Name 'name' -Value $SortOutputName
    Set-Attr -Element $sortPath -Name 'startId' -Value $sortOutputId
    Set-Attr -Element $sortPath -Name 'endId' -Value $lookupInputId
}

$dimensionConfigs = @(
    @{
        Name = 'DimDepartment'
        Table = 'DimDepartment'
        Key = 'DepartmentKey'
        Columns = @(
            @{ Output = 'NewDeptID'; Target = 'DeptID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4'; Join = $true; SortKey = 1 }
            @{ Output = 'NewDepartment'; Target = 'Department'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR'; Join = $false; SortKey = 0 }
        )
    }
    @{
        Name = 'DimPosition'
        Table = 'DimPosition'
        Key = 'PositionKey'
        Columns = @(
            @{ Output = 'NewPositionID'; Target = 'PositionID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4'; Join = $true; SortKey = 1 }
            @{ Output = 'NewPosition'; Target = 'Position'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR'; Join = $false; SortKey = 0 }
        )
    }
    @{
        Name = 'DimManager'
        Table = 'DimManager'
        Key = 'ManagerKey'
        Columns = @(
            @{ Output = 'NewManagerID'; Target = 'ManagerID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4'; Join = $true; SortKey = 1 }
            @{ Output = 'NewManagerName'; Target = 'ManagerName'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR'; Join = $false; SortKey = 0 }
        )
    }
    @{
        Name = 'DimLocation'
        Table = 'DimLocation'
        Key = 'LocationKey'
        Columns = @(
            @{ Output = 'NewState'; Target = 'State'; Type = 'wstr'; Length = 10; LookupType = 'DT_WSTR'; Join = $true; SortKey = 1 }
            @{ Output = 'NewZip'; Target = 'Zip'; Type = 'wstr'; Length = 20; LookupType = 'DT_WSTR'; Join = $true; SortKey = 2 }
        )
    }
    @{
        Name = 'DimRecruitment'
        Table = 'DimRecruitment'
        Key = 'RecruitmentKey'
        Columns = @(
            @{ Output = 'NewRecruitmentSource'; Target = 'RecruitmentSource'; Type = 'wstr'; Length = 100; LookupType = 'DT_WSTR'; Join = $true; SortKey = 1 }
            @{ Output = 'NewFromDiversityJobFairID'; Target = 'FromDiversityJobFairID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4'; Join = $true; SortKey = 2 }
        )
    }
    @{
        Name = 'DimPerformance'
        Table = 'DimPerformance'
        Key = 'PerformanceKey'
        Columns = @(
            @{ Output = 'NewPerfScoreID'; Target = 'PerfScoreID'; Type = 'i4'; Length = 0; LookupType = 'DT_I4'; Join = $true; SortKey = 1 }
            @{ Output = 'NewPerformanceScore'; Target = 'PerformanceScore'; Type = 'wstr'; Length = 50; LookupType = 'DT_WSTR'; Join = $true; SortKey = 2 }
        )
    }
)

if (-not (Test-Path -LiteralPath $PackagePath)) {
    throw "Package introuvable : $PackagePath"
}

$packageDoc = New-Object System.Xml.XmlDocument
$packageDoc.PreserveWhitespace = $true
$packageDoc.Load($PackagePath)

$script:namespaceManager = New-Object System.Xml.XmlNamespaceManager($packageDoc.NameTable)
$namespaceManager.AddNamespace('DTS', 'www.microsoft.com/SqlServer/Dts')

$templateSort = $packageDoc.SelectSingleNode("/DTS:Executable/DTS:Executables/DTS:Executable[@DTS:ObjectName='DimDate']/DTS:ObjectData/pipeline/components/component[@componentClassID='Microsoft.Sort']", $namespaceManager)
if ($null -eq $templateSort) {
    if (-not (Test-Path -LiteralPath $SortTemplatePath)) {
        throw "Template de tri introuvable, et le fichier de secours est absent : $SortTemplatePath"
    }

    $templateDoc = New-Object System.Xml.XmlDocument
    $templateDoc.PreserveWhitespace = $true
    $templateDoc.Load($SortTemplatePath)

    $templateNs = New-Object System.Xml.XmlNamespaceManager($templateDoc.NameTable)
    $templateNs.AddNamespace('DTS', 'www.microsoft.com/SqlServer/Dts')

    $templateSort = $templateDoc.SelectSingleNode("/DTS:Executable/DTS:Executables/DTS:Executable[@DTS:ObjectName='DimDate']/DTS:ObjectData/pipeline/components/component[@componentClassID='Microsoft.Sort']", $templateNs)
    if ($null -eq $templateSort) {
        $templateSort = $templateDoc.SelectSingleNode("//component[@componentClassID='Microsoft.Sort']")
    }
    if ($null -eq $templateSort) {
        throw "Template de tri introuvable dans le fichier de secours : $SortTemplatePath"
    }
}

foreach ($config in $dimensionConfigs) {
    $task = $packageDoc.SelectSingleNode("/DTS:Executable/DTS:Executables/DTS:Executable[@DTS:ObjectName='$($config.Name)']", $namespaceManager)
    if ($null -eq $task) {
        throw "Tâche introuvable : $($config.Name)"
    }

    Update-ConversionOutputs -Task $task -Config $config
    Ensure-SortComponent -Task $task -Config $config -TemplateSort $templateSort
    Update-LookupComponent -Task $task -Config $config
    Update-DestinationComponent -Task $task -Config $config
    Update-Paths -Task $task -Config $config
}

$designProperty = $packageDoc.SelectSingleNode('/DTS:Executable/DTS:DesignTimeProperties', $namespaceManager)
Clear-Children -Node $designProperty
[void]$designProperty.AppendChild($packageDoc.CreateCDataSection('<?xml version="1.0"?><Objects Version="8"></Objects>'))

$packageDoc.Save($PackagePath)

[pscustomobject]@{
    PackagePath = $PackagePath
    NormalizedDimensions = ($dimensionConfigs | ForEach-Object { $_.Name }) -join ', '
    DimLocationZipType = 'DT_WSTR -> NVARCHAR(20)'
} | Format-List
