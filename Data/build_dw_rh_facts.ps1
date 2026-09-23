param(
    [string]$PackageTemplatePath = (Join-Path $PSScriptRoot 'Dimensions.dtsx'),
    [string]$TaskTemplatePath = (Join-Path $PSScriptRoot 'Facts.dtsx'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Facts.dtsx')
)

$ErrorActionPreference = 'Stop'

$DtsNamespace = 'www.microsoft.com/SqlServer/Dts'
$SourceOutputName = 'Sortie de source de fichier plat'
$ConversionComponentBase = 'Conversion de donn' + [char]0x00E9 + 'es'
$ConversionInputName = 'Entr' + [char]0x00E9 + 'e de conversion de donn' + [char]0x00E9 + 'es'
$ConversionOutputName = 'Sortie de conversion de donn' + [char]0x00E9 + 'es'
$SortInputName = 'Entr' + [char]0x00E9 + 'e de tri'
$SortOutputName = 'Sortie de tri'
$MergeLeftInputName = 'Entr' + [char]0x00E9 + 'e gauche de jointure de fusion'
$MergeRightInputName = 'Entr' + [char]0x00E9 + 'e droite de jointure de fusion'
$MergeOutputName = 'Sortie de jointure de fusion'
$DestinationInputName = 'Entr' + [char]0x00E9 + 'e de destination OLE DB'
$OleDbManagerRef = 'Package.ConnectionManagers[DW_RH]'
$FlatFileManagerRef = 'Package.ConnectionManagers[HRDataset_Clean]'

function New-GuidText {
    '{' + ([guid]::NewGuid().ToString().ToUpperInvariant()) + '}'
}

function Set-DtsAttr {
    param(
        [System.Xml.XmlElement]$Element,
        [string]$LocalName,
        [string]$Value
    )

    if ($Element.HasAttribute($LocalName, $DtsNamespace)) {
        [void]$Element.SetAttribute($LocalName, $DtsNamespace, $Value)
        return
    }

    $attr = $Element.Attributes.GetNamedItem("DTS:$LocalName")
    if ($null -ne $attr) {
        $attr.Value = $Value
        return
    }

    $prefix = if ($Element.Prefix) { $Element.Prefix } else { 'DTS' }
    $newAttr = $Element.OwnerDocument.CreateAttribute($prefix, $LocalName, $DtsNamespace)
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

    if ($Element.HasAttribute('DTSID', $DtsNamespace)) {
        Set-DtsAttr -Element $Element -LocalName 'DTSID' -Value (New-GuidText)
    }
}

function Update-OleDbProvider {
    param(
        [System.Xml.XmlDocument]$PackageDoc,
        [System.Xml.XmlNamespaceManager]$NamespaceManager
    )

    $connectionManagers = $PackageDoc.SelectNodes('/DTS:Executable/DTS:ConnectionManagers/DTS:ConnectionManager/DTS:ObjectData/DTS:ConnectionManager', $NamespaceManager)
    foreach ($connectionManager in $connectionManagers) {
        $connectionString = $connectionManager.GetAttribute('ConnectionString', $DtsNamespace)
        if ($connectionString -and $connectionString.Contains('Provider=SQLOLEDB.1')) {
            $updated = $connectionString.Replace('Provider=SQLOLEDB.1', 'Provider=MSOLEDBSQL.1')
            $connectionManager.SetAttribute('ConnectionString', $DtsNamespace, $updated)
        }
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
                    Remove-Attr -Element $Element -Name 'precision'
                    Remove-Attr -Element $Element -Name 'scale'
                }
                'str' {
                    Set-Attr -Element $Element -Name 'length' -Value ([string]$Column.Length)
                    Set-Attr -Element $Element -Name 'codePage' -Value '1252'
                    Remove-Attr -Element $Element -Name 'precision'
                    Remove-Attr -Element $Element -Name 'scale'
                }
                'numeric' {
                    Remove-Attr -Element $Element -Name 'length'
                    Remove-Attr -Element $Element -Name 'codePage'
                    Set-Attr -Element $Element -Name 'precision' -Value ([string]$Column.Precision)
                    Set-Attr -Element $Element -Name 'scale' -Value ([string]$Column.Scale)
                }
                default {
                    Remove-Attr -Element $Element -Name 'length'
                    Remove-Attr -Element $Element -Name 'codePage'
                    Remove-Attr -Element $Element -Name 'precision'
                    Remove-Attr -Element $Element -Name 'scale'
                }
            }
        }
        'cached' {
            Set-Attr -Element $Element -Name 'cachedDataType' -Value $Column.Type

            switch ($Column.Type) {
                'wstr' {
                    Set-Attr -Element $Element -Name 'cachedLength' -Value ([string]$Column.Length)
                    Remove-Attr -Element $Element -Name 'cachedCodepage'
                    Remove-Attr -Element $Element -Name 'cachedPrecision'
                    Remove-Attr -Element $Element -Name 'cachedScale'
                }
                'str' {
                    Set-Attr -Element $Element -Name 'cachedLength' -Value ([string]$Column.Length)
                    Set-Attr -Element $Element -Name 'cachedCodepage' -Value '1252'
                    Remove-Attr -Element $Element -Name 'cachedPrecision'
                    Remove-Attr -Element $Element -Name 'cachedScale'
                }
                'numeric' {
                    Remove-Attr -Element $Element -Name 'cachedLength'
                    Remove-Attr -Element $Element -Name 'cachedCodepage'
                    Set-Attr -Element $Element -Name 'cachedPrecision' -Value ([string]$Column.Precision)
                    Set-Attr -Element $Element -Name 'cachedScale' -Value ([string]$Column.Scale)
                }
                default {
                    Remove-Attr -Element $Element -Name 'cachedLength'
                    Remove-Attr -Element $Element -Name 'cachedCodepage'
                    Remove-Attr -Element $Element -Name 'cachedPrecision'
                    Remove-Attr -Element $Element -Name 'cachedScale'
                }
            }
        }
        default {
            throw "Unknown type mode: $Mode"
        }
    }
}

function Get-ConversionDisposition {
    param([hashtable]$Column)

    if ($Column.ContainsKey('ConversionDisposition') -and $Column.ConversionDisposition) {
        return $Column.ConversionDisposition
    }

    return 'FailComponent'
}

function Get-ComponentByName {
    param(
        [System.Xml.XmlElement]$Task,
        [string]$ComponentName
    )

    foreach ($component in @($Task.SelectNodes('.//*[local-name()="component"]'))) {
        if ($component.GetAttribute('name') -eq $ComponentName) {
            return [System.Xml.XmlElement]$component
        }
    }

    return $null
}

function Get-OutputBase {
    param(
        [string]$TaskName,
        [string]$ComponentName
    )

    if ($ComponentName -like 'Source du fichier plat*') {
        return "Package\$TaskName\$ComponentName.Outputs[$SourceOutputName]"
    }

    if ($ComponentName -like 'Conversion de donn*') {
        return "Package\$TaskName\$ComponentName.Outputs[$ConversionOutputName]"
    }

    if ($ComponentName -like 'Trier*') {
        return "Package\$TaskName\$ComponentName.Outputs[$SortOutputName]"
    }

    if ($ComponentName -like 'Jointure de fusion*') {
        return "Package\$TaskName\$ComponentName.Outputs[$MergeOutputName]"
    }

    throw "Unknown component output base for: $ComponentName"
}

function New-ColumnIndex {
    param([hashtable]$Config)

    $index = @{}
    foreach ($branch in $Config.Branches) {
        foreach ($column in $branch.Columns) {
            $index[$column.Output] = $column
        }
    }

    return $index
}

function Set-ConnectionRefs {
    param(
        [System.Xml.XmlElement]$Task,
        [string]$TaskName
    )

    foreach ($sourceName in @('Source du fichier plat', 'Source du fichier plat 1', 'Source du fichier plat 2')) {
        $sourceComponent = Get-ComponentByName -Task $Task -ComponentName $sourceName
        $connection = [System.Xml.XmlElement]$sourceComponent.SelectSingleNode('connections/connection')
        Set-Attr -Element $connection -Name 'refId' -Value "Package\$TaskName\$sourceName.Connections[FlatFileConnection]"
        Set-Attr -Element $connection -Name 'connectionManagerID' -Value $FlatFileManagerRef
        Set-Attr -Element $connection -Name 'connectionManagerRefId' -Value $FlatFileManagerRef
        Set-Attr -Element $connection -Name 'name' -Value 'FlatFileConnection'
    }

    $destinationComponent = Get-ComponentByName -Task $Task -ComponentName 'Destination OLE DB'
    $destConnection = [System.Xml.XmlElement]$destinationComponent.SelectSingleNode('connections/connection')
    Set-Attr -Element $destConnection -Name 'refId' -Value "Package\$TaskName\Destination OLE DB.Connections[OleDbConnection]"
    Set-Attr -Element $destConnection -Name 'connectionManagerID' -Value $OleDbManagerRef
    Set-Attr -Element $destConnection -Name 'connectionManagerRefId' -Value $OleDbManagerRef
    Set-Attr -Element $destConnection -Name 'name' -Value 'OleDbConnection'
}

function Update-FlatFileSourceComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [string]$TaskName,
        [hashtable]$Branch
    )

    $component = Get-ComponentByName -Task $Task -ComponentName $Branch.SourceName
    $outputNode = [System.Xml.XmlElement]$component.SelectSingleNode('outputs/output[1]')
    $outputColumnsParent = $outputNode.SelectSingleNode('outputColumns')
    $externalMetadataParent = $outputNode.SelectSingleNode('externalMetadataColumns')

    $templateOutputColumn = [System.Xml.XmlElement]$outputColumnsParent.SelectSingleNode('outputColumn').CloneNode($true)
    $templateExternalColumn = [System.Xml.XmlElement]$externalMetadataParent.SelectSingleNode('externalMetadataColumn').CloneNode($true)

    Clear-Children -Node $outputColumnsParent
    Clear-Children -Node $externalMetadataParent

    foreach ($column in $Branch.Columns) {
        $baseRef = "Package\$TaskName\$($Branch.SourceName).Outputs[$SourceOutputName]"

        $outputColumn = [System.Xml.XmlElement]$templateOutputColumn.CloneNode($true)
        Set-Attr -Element $outputColumn -Name 'refId' -Value "$baseRef.Columns[$($column.Source)]"
        Set-Attr -Element $outputColumn -Name 'externalMetadataColumnId' -Value "$baseRef.ExternalColumns[$($column.Source)]"
        Set-Attr -Element $outputColumn -Name 'lineageId' -Value "$baseRef.Columns[$($column.Source)]"
        Set-Attr -Element $outputColumn -Name 'name' -Value $column.Source
        Set-Attr -Element $outputColumn -Name 'codePage' -Value '1252'
        Set-Attr -Element $outputColumn -Name 'dataType' -Value 'str'
        Set-Attr -Element $outputColumn -Name 'length' -Value '50'
        [void]$outputColumnsParent.AppendChild($outputColumn)

        $externalColumn = [System.Xml.XmlElement]$templateExternalColumn.CloneNode($true)
        Set-Attr -Element $externalColumn -Name 'refId' -Value "$baseRef.ExternalColumns[$($column.Source)]"
        Set-Attr -Element $externalColumn -Name 'name' -Value $column.Source
        Set-Attr -Element $externalColumn -Name 'codePage' -Value '1252'
        Set-Attr -Element $externalColumn -Name 'dataType' -Value 'str'
        Set-Attr -Element $externalColumn -Name 'length' -Value '50'
        [void]$externalMetadataParent.AppendChild($externalColumn)
    }
}

function Update-ConversionComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [string]$TaskName,
        [hashtable]$Branch
    )

    $component = Get-ComponentByName -Task $Task -ComponentName $Branch.ConversionName
    if ($null -eq $component) {
        throw "Conversion component not found: $($Branch.ConversionName)"
    }
    $inputParent = $component.SelectSingleNode('inputs/input[1]/inputColumns')
    $outputParent = $component.SelectSingleNode('outputs/output[1]/outputColumns')

    $templateInput = [System.Xml.XmlElement]$inputParent.SelectSingleNode('inputColumn').CloneNode($true)
    $templateOutput = [System.Xml.XmlElement]$outputParent.SelectSingleNode('outputColumn').CloneNode($true)

    Clear-Children -Node $inputParent
    Clear-Children -Node $outputParent

    foreach ($column in $Branch.Columns) {
        $sourceLineage = "Package\$TaskName\$($Branch.SourceName).Outputs[$SourceOutputName].Columns[$($column.Source)]"

        $inputColumn = [System.Xml.XmlElement]$templateInput.CloneNode($true)
        Set-Attr -Element $inputColumn -Name 'refId' -Value "Package\$TaskName\$($Branch.ConversionName).Inputs[$ConversionInputName].Columns[$($column.Source)]"
        Set-Attr -Element $inputColumn -Name 'cachedName' -Value $column.Source
        Set-Attr -Element $inputColumn -Name 'lineageId' -Value $sourceLineage
        Set-Attr -Element $inputColumn -Name 'cachedCodepage' -Value '1252'
        Set-Attr -Element $inputColumn -Name 'cachedDataType' -Value 'str'
        Set-Attr -Element $inputColumn -Name 'cachedLength' -Value '50'
        Remove-Attr -Element $inputColumn -Name 'cachedPrecision'
        Remove-Attr -Element $inputColumn -Name 'cachedScale'
        [void]$inputParent.AppendChild($inputColumn)

        $outputColumn = [System.Xml.XmlElement]$templateOutput.CloneNode($true)
        Set-Attr -Element $outputColumn -Name 'refId' -Value "Package\$TaskName\$($Branch.ConversionName).Outputs[$ConversionOutputName].Columns[$($column.Output)]"
        Set-Attr -Element $outputColumn -Name 'lineageId' -Value "Package\$TaskName\$($Branch.ConversionName).Outputs[$ConversionOutputName].Columns[$($column.Output)]"
        Set-Attr -Element $outputColumn -Name 'name' -Value $column.Output
        Set-TypeAttributes -Element $outputColumn -Mode 'data' -Column $column
        $disposition = Get-ConversionDisposition -Column $column
        Set-Attr -Element $outputColumn -Name 'errorRowDisposition' -Value $disposition
        Set-Attr -Element $outputColumn -Name 'truncationRowDisposition' -Value $disposition
        $sourceProperty = $outputColumn.SelectSingleNode("properties/property[@name='SourceInputColumnLineageID']")
        $sourceProperty.InnerText = "#{$sourceLineage}"
        [void]$outputParent.AppendChild($outputColumn)
    }
}

function Update-SortComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [string]$TaskName,
        [hashtable]$Branch
    )

    $component = Get-ComponentByName -Task $Task -ComponentName $Branch.SortName
    $inputNode = [System.Xml.XmlElement]$component.SelectSingleNode('inputs/input[1]')
    $outputNode = [System.Xml.XmlElement]$component.SelectSingleNode('outputs/output[1]')
    $inputParent = $inputNode.SelectSingleNode('inputColumns')
    $outputParent = $outputNode.SelectSingleNode('outputColumns')

    $templateInput = [System.Xml.XmlElement]$inputParent.SelectSingleNode('inputColumn').CloneNode($true)
    $templateOutput = [System.Xml.XmlElement]$outputParent.SelectSingleNode('outputColumn').CloneNode($true)

    Set-Attr -Element $inputNode -Name 'refId' -Value "Package\$TaskName\$($Branch.SortName).Inputs[$SortInputName]"
    Set-Attr -Element $outputNode -Name 'refId' -Value "Package\$TaskName\$($Branch.SortName).Outputs[$SortOutputName]"
    Set-Attr -Element $outputNode -Name 'isSorted' -Value 'true'

    Clear-Children -Node $inputParent
    Clear-Children -Node $outputParent

    foreach ($column in $Branch.Columns) {
        $conversionLineage = "Package\$TaskName\$($Branch.ConversionName).Outputs[$ConversionOutputName].Columns[$($column.Output)]"
        $sortLineage = "Package\$TaskName\$($Branch.SortName).Outputs[$SortOutputName].Columns[$($column.Output)]"
        $sortKeyPosition = if ($column.Output -eq $Branch.SortKey) { '1' } else { '0' }

        $inputColumn = [System.Xml.XmlElement]$templateInput.CloneNode($true)
        Set-Attr -Element $inputColumn -Name 'refId' -Value "Package\$TaskName\$($Branch.SortName).Inputs[$SortInputName].Columns[$($column.Output)]"
        Set-Attr -Element $inputColumn -Name 'cachedName' -Value $column.Output
        Set-Attr -Element $inputColumn -Name 'lineageId' -Value $conversionLineage
        Set-TypeAttributes -Element $inputColumn -Mode 'cached' -Column $column
        $inputColumn.SelectSingleNode("properties/property[@name='NewComparisonFlags']").InnerText = '0'
        $inputColumn.SelectSingleNode("properties/property[@name='NewSortKeyPosition']").InnerText = $sortKeyPosition
        [void]$inputParent.AppendChild($inputColumn)

        $outputColumn = [System.Xml.XmlElement]$templateOutput.CloneNode($true)
        Set-Attr -Element $outputColumn -Name 'refId' -Value $sortLineage
        Set-Attr -Element $outputColumn -Name 'lineageId' -Value $sortLineage
        Set-Attr -Element $outputColumn -Name 'name' -Value $column.Output
        Set-TypeAttributes -Element $outputColumn -Mode 'data' -Column $column
        if ($column.Output -eq $Branch.SortKey) {
            Set-Attr -Element $outputColumn -Name 'sortKeyPosition' -Value '1'
        }
        else {
            Remove-Attr -Element $outputColumn -Name 'sortKeyPosition'
        }

        $outputColumn.SelectSingleNode("properties/property[@name='SortColumnId']").InnerText = "#{$conversionLineage}"
        [void]$outputParent.AppendChild($outputColumn)
    }
}

function Update-MergeJoinComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [string]$TaskName,
        [hashtable]$MergeConfig,
        [hashtable]$ColumnIndex
    )

    $component = Get-ComponentByName -Task $Task -ComponentName $MergeConfig.Name
    $leftInputNode = [System.Xml.XmlElement]$component.SelectSingleNode('inputs/input[1]')
    $rightInputNode = [System.Xml.XmlElement]$component.SelectSingleNode('inputs/input[2]')
    $outputNode = [System.Xml.XmlElement]$component.SelectSingleNode('outputs/output[1]')

    $leftParent = $leftInputNode.SelectSingleNode('inputColumns')
    $rightParent = $rightInputNode.SelectSingleNode('inputColumns')
    $outputParent = $outputNode.SelectSingleNode('outputColumns')

    $templateLeftInput = [System.Xml.XmlElement]$leftParent.SelectSingleNode('inputColumn').CloneNode($true)
    $templateRightInput = [System.Xml.XmlElement]$rightParent.SelectSingleNode('inputColumn').CloneNode($true)
    $templateOutput = [System.Xml.XmlElement]$outputParent.SelectSingleNode('outputColumn').CloneNode($true)

    $leftBase = Get-OutputBase -TaskName $TaskName -ComponentName $MergeConfig.LeftComponent
    $rightBase = Get-OutputBase -TaskName $TaskName -ComponentName $MergeConfig.RightComponent

    Set-Attr -Element $leftInputNode -Name 'refId' -Value "Package\$TaskName\$($MergeConfig.Name).Inputs[$MergeLeftInputName]"
    Set-Attr -Element $rightInputNode -Name 'refId' -Value "Package\$TaskName\$($MergeConfig.Name).Inputs[$MergeRightInputName]"
    Set-Attr -Element $outputNode -Name 'refId' -Value "Package\$TaskName\$($MergeConfig.Name).Outputs[$MergeOutputName]"
    Set-Attr -Element $outputNode -Name 'isSorted' -Value 'true'

    Clear-Children -Node $leftParent
    Clear-Children -Node $rightParent
    Clear-Children -Node $outputParent

    foreach ($columnName in $MergeConfig.LeftColumns) {
        $column = $ColumnIndex[$columnName]
        $lineage = "$leftBase.Columns[$columnName]"

        $inputColumn = [System.Xml.XmlElement]$templateLeftInput.CloneNode($true)
        Set-Attr -Element $inputColumn -Name 'refId' -Value "Package\$TaskName\$($MergeConfig.Name).Inputs[$MergeLeftInputName].Columns[$columnName]"
        Set-Attr -Element $inputColumn -Name 'cachedName' -Value $columnName
        Set-Attr -Element $inputColumn -Name 'lineageId' -Value $lineage
        Set-TypeAttributes -Element $inputColumn -Mode 'cached' -Column $column
        if ($columnName -eq $MergeConfig.LeftKey) {
            Set-Attr -Element $inputColumn -Name 'cachedSortKeyPosition' -Value '1'
        }
        else {
            Remove-Attr -Element $inputColumn -Name 'cachedSortKeyPosition'
        }
        [void]$leftParent.AppendChild($inputColumn)
    }

    foreach ($columnName in $MergeConfig.RightColumns) {
        $column = $ColumnIndex[$columnName]
        $lineage = "$rightBase.Columns[$columnName]"

        $inputColumn = [System.Xml.XmlElement]$templateRightInput.CloneNode($true)
        Set-Attr -Element $inputColumn -Name 'refId' -Value "Package\$TaskName\$($MergeConfig.Name).Inputs[$MergeRightInputName].Columns[$columnName]"
        Set-Attr -Element $inputColumn -Name 'cachedName' -Value $columnName
        Set-Attr -Element $inputColumn -Name 'lineageId' -Value $lineage
        Set-TypeAttributes -Element $inputColumn -Mode 'cached' -Column $column
        if ($columnName -eq $MergeConfig.RightKey) {
            Set-Attr -Element $inputColumn -Name 'cachedSortKeyPosition' -Value '1'
        }
        else {
            Remove-Attr -Element $inputColumn -Name 'cachedSortKeyPosition'
        }
        [void]$rightParent.AppendChild($inputColumn)
    }

    foreach ($outputSpec in $MergeConfig.OutputColumns) {
        $columnName = $outputSpec.Name
        $column = $ColumnIndex[$columnName]
        $inputName = if ($outputSpec.Side -eq 'Left') { $MergeLeftInputName } else { $MergeRightInputName }

        $outputColumn = [System.Xml.XmlElement]$templateOutput.CloneNode($true)
        Set-Attr -Element $outputColumn -Name 'refId' -Value "Package\$TaskName\$($MergeConfig.Name).Outputs[$MergeOutputName].Columns[$columnName]"
        Set-Attr -Element $outputColumn -Name 'lineageId' -Value "Package\$TaskName\$($MergeConfig.Name).Outputs[$MergeOutputName].Columns[$columnName]"
        Set-Attr -Element $outputColumn -Name 'name' -Value $columnName
        Set-TypeAttributes -Element $outputColumn -Mode 'data' -Column $column
        if (($outputSpec.Side -eq 'Left') -and ($columnName -eq $MergeConfig.LeftKey)) {
            Set-Attr -Element $outputColumn -Name 'sortKeyPosition' -Value '1'
        }
        else {
            Remove-Attr -Element $outputColumn -Name 'sortKeyPosition'
        }

        $outputColumn.SelectSingleNode("properties/property[@name='InputColumnID']").InnerText = "#{" + "Package\$TaskName\$($MergeConfig.Name).Inputs[$inputName].Columns[$columnName]" + "}"
        [void]$outputParent.AppendChild($outputColumn)
    }
}

function Update-DestinationComponent {
    param(
        [System.Xml.XmlElement]$Task,
        [string]$TaskName,
        [hashtable]$Config,
        [hashtable]$ColumnIndex
    )

    $component = Get-ComponentByName -Task $Task -ComponentName 'Destination OLE DB'
    $component.SelectSingleNode("properties/property[@name='OpenRowset']").InnerText = "[dbo].[$($Config.Table)]"

    $inputNode = [System.Xml.XmlElement]$component.SelectSingleNode('inputs/input[1]')
    $inputParent = $inputNode.SelectSingleNode('inputColumns')
    $externalParent = $inputNode.SelectSingleNode('externalMetadataColumns')
    $templateInput = [System.Xml.XmlElement]$inputParent.SelectSingleNode('inputColumn').CloneNode($true)
    $templateExternal = [System.Xml.XmlElement]$externalParent.SelectSingleNode('externalMetadataColumn').CloneNode($true)

    Clear-Children -Node $inputParent
    Clear-Children -Node $externalParent

    $keyColumn = [System.Xml.XmlElement]$templateExternal.CloneNode($true)
    Set-Attr -Element $keyColumn -Name 'refId' -Value "Package\$TaskName\Destination OLE DB.Inputs[$DestinationInputName].ExternalColumns[$($Config.Key)]"
    Set-Attr -Element $keyColumn -Name 'name' -Value $Config.Key
    Set-Attr -Element $keyColumn -Name 'dataType' -Value 'i4'
    Remove-Attr -Element $keyColumn -Name 'length'
    Remove-Attr -Element $keyColumn -Name 'codePage'
    Remove-Attr -Element $keyColumn -Name 'precision'
    Remove-Attr -Element $keyColumn -Name 'scale'
    [void]$externalParent.AppendChild($keyColumn)

    foreach ($mapping in $Config.FinalColumns) {
        $column = $ColumnIndex[$mapping.Output]
        $mergeBase = Get-OutputBase -TaskName $TaskName -ComponentName $Config.Merge2.Name
        $lineage = "$mergeBase.Columns[$($mapping.Output)]"
        $externalRef = "Package\$TaskName\Destination OLE DB.Inputs[$DestinationInputName].ExternalColumns[$($mapping.Target)]"

        $inputColumn = [System.Xml.XmlElement]$templateInput.CloneNode($true)
        Set-Attr -Element $inputColumn -Name 'refId' -Value "Package\$TaskName\Destination OLE DB.Inputs[$DestinationInputName].Columns[$($mapping.Output)]"
        Set-Attr -Element $inputColumn -Name 'cachedName' -Value $mapping.Output
        Set-Attr -Element $inputColumn -Name 'externalMetadataColumnId' -Value $externalRef
        Set-Attr -Element $inputColumn -Name 'lineageId' -Value $lineage
        Set-TypeAttributes -Element $inputColumn -Mode 'cached' -Column $column
        [void]$inputParent.AppendChild($inputColumn)

        $externalColumn = [System.Xml.XmlElement]$templateExternal.CloneNode($true)
        Set-Attr -Element $externalColumn -Name 'refId' -Value $externalRef
        Set-Attr -Element $externalColumn -Name 'name' -Value $mapping.Target
        Set-TypeAttributes -Element $externalColumn -Mode 'data' -Column $column
        [void]$externalParent.AppendChild($externalColumn)
    }
}

function Update-Paths {
    param(
        [System.Xml.XmlElement]$Task,
        [string]$TaskName
    )

    $pipelineNode = $Task.SelectSingleNode('.//*[local-name()="pipeline"]')
    $pathsParent = $pipelineNode.SelectSingleNode('*[local-name()="paths"]')
    if ($null -eq $pathsParent) {
        $pathsParent = $Task.OwnerDocument.CreateElement('paths')
        [void]$pipelineNode.AppendChild($pathsParent)
    }

    Clear-Children -Node $pathsParent

    $pathSpecs = @(
        @{ Name = 'Sortie de source de fichier plat'; Start = 'Source du fichier plat'; End = $ConversionComponentBase; EndType = 'Conversion' }
        @{ Name = $ConversionOutputName; Start = $ConversionComponentBase; End = 'Trier'; EndType = 'Sort' }
        @{ Name = 'Sortie de source de fichier plat 1'; Start = 'Source du fichier plat 1'; End = "$ConversionComponentBase 1"; EndType = 'Conversion' }
        @{ Name = "$ConversionOutputName 1"; Start = "$ConversionComponentBase 1"; End = 'Trier 1'; EndType = 'Sort' }
        @{ Name = 'Sortie de source de fichier plat 2'; Start = 'Source du fichier plat 2'; End = "$ConversionComponentBase 2"; EndType = 'Conversion' }
        @{ Name = "$ConversionOutputName 2"; Start = "$ConversionComponentBase 2"; End = 'Trier 2'; EndType = 'Sort' }
        @{ Name = 'Sortie de tri'; Start = 'Trier'; End = 'Jointure de fusion'; EndType = 'MergeLeft' }
        @{ Name = 'Sortie de tri 1'; Start = 'Trier 1'; End = 'Jointure de fusion'; EndType = 'MergeRight' }
        @{ Name = 'Sortie de jointure de fusion'; Start = 'Jointure de fusion'; End = 'Jointure de fusion 1'; EndType = 'MergeLeft' }
        @{ Name = 'Sortie de tri 2'; Start = 'Trier 2'; End = 'Jointure de fusion 1'; EndType = 'MergeRight' }
        @{ Name = 'Sortie de jointure de fusion 1'; Start = 'Jointure de fusion 1'; End = 'Destination OLE DB'; EndType = 'Destination' }
    )

    foreach ($spec in $pathSpecs) {
        $path = $Task.OwnerDocument.CreateElement('path')
        Set-Attr -Element $path -Name 'refId' -Value "Package\$TaskName.Paths[$($spec.Name)]"
        Set-Attr -Element $path -Name 'name' -Value $spec.Name
        Set-Attr -Element $path -Name 'startId' -Value (Get-OutputBase -TaskName $TaskName -ComponentName $spec.Start)

        switch ($spec.EndType) {
            'Conversion' { $endId = "Package\$TaskName\$($spec.End).Inputs[$ConversionInputName]" }
            'Sort' { $endId = "Package\$TaskName\$($spec.End).Inputs[$SortInputName]" }
            'MergeLeft' { $endId = "Package\$TaskName\$($spec.End).Inputs[$MergeLeftInputName]" }
            'MergeRight' { $endId = "Package\$TaskName\$($spec.End).Inputs[$MergeRightInputName]" }
            'Destination' { $endId = "Package\$TaskName\$($spec.End).Inputs[$DestinationInputName]" }
            default { throw "Unknown path end type: $($spec.EndType)" }
        }

        Set-Attr -Element $path -Name 'endId' -Value $endId
        [void]$pathsParent.AppendChild($path)
    }
}

$factConfigs = @(
    @{
        Name = 'FactAttendancePerformance'
        Table = 'FactAttendancePerformance'
        Key = 'AttendancePerformanceKey'
        Branches = @(
            @{
                SourceName = 'Source du fichier plat'
                ConversionName = $ConversionComponentBase
                SortName = 'Trier'
                SortKey = 'NewEmpID'
                Columns = @(
                    @{ Source = 'EmpID'; Output = 'NewEmpID'; Type = 'i4' }
                    @{ Source = 'Absences'; Output = 'NewAbsences'; Type = 'i4' }
                    @{ Source = 'DaysLateLast30'; Output = 'NewDaysLateLast30'; Type = 'i4' }
                    @{ Source = 'EngagementSurvey'; Output = 'NewEngagementSurvey'; Type = 'numeric'; Precision = 5; Scale = 2 }
                    @{ Source = 'EmpSatisfaction'; Output = 'NewEmpSatisfaction'; Type = 'i4' }
                    @{ Source = 'SpecialProjectsCount'; Output = 'NewSpecialProjectsCount'; Type = 'i4' }
                )
            }
            @{
                SourceName = 'Source du fichier plat 1'
                ConversionName = "$ConversionComponentBase 1"
                SortName = 'Trier 1'
                SortKey = 'NewEmpID_1'
                Columns = @(
                    @{ Source = 'EmpID'; Output = 'NewEmpID_1'; Type = 'i4' }
                    @{ Source = 'DeptID'; Output = 'NewDeptID'; Type = 'i4' }
                    @{ Source = 'PositionID'; Output = 'NewPositionID'; Type = 'i4' }
                    @{ Source = 'ManagerID'; Output = 'NewManagerID'; Type = 'i4' }
                )
            }
            @{
                SourceName = 'Source du fichier plat 2'
                ConversionName = "$ConversionComponentBase 2"
                SortName = 'Trier 2'
                SortKey = 'NewEmpID_2'
                Columns = @(
                    @{ Source = 'EmpID'; Output = 'NewEmpID_2'; Type = 'i4' }
                    @{ Source = 'State'; Output = 'NewState'; Type = 'wstr'; Length = 10 }
                    @{ Source = 'Zip'; Output = 'NewZip'; Type = 'wstr'; Length = 20 }
                    @{ Source = 'RecruitmentSource'; Output = 'NewRecruitmentSource'; Type = 'wstr'; Length = 100 }
                    @{ Source = 'FromDiversityJobFairID'; Output = 'NewFromDiversityJobFairID'; Type = 'i4' }
                    @{ Source = 'PerfScoreID'; Output = 'NewPerfScoreID'; Type = 'i4' }
                    @{ Source = 'PerformanceScore'; Output = 'NewPerformanceScore'; Type = 'wstr'; Length = 50 }
                    @{ Source = 'DateofHire'; Output = 'NewDateofHire'; Type = 'dbDate' }
                    @{ Source = 'LastPerformanceReview_Date'; Output = 'NewLastPerformanceReviewDate'; Type = 'dbDate' }
                )
            }
        )
        Merge1 = @{
            Name = 'Jointure de fusion'
            LeftComponent = 'Trier'
            RightComponent = 'Trier 1'
            LeftKey = 'NewEmpID'
            RightKey = 'NewEmpID_1'
            LeftColumns = @('NewEmpID', 'NewAbsences', 'NewDaysLateLast30', 'NewEngagementSurvey', 'NewEmpSatisfaction', 'NewSpecialProjectsCount')
            RightColumns = @('NewEmpID_1', 'NewDeptID', 'NewPositionID', 'NewManagerID')
            OutputColumns = @(
                @{ Name = 'NewEmpID'; Side = 'Left' }
                @{ Name = 'NewAbsences'; Side = 'Left' }
                @{ Name = 'NewDaysLateLast30'; Side = 'Left' }
                @{ Name = 'NewEngagementSurvey'; Side = 'Left' }
                @{ Name = 'NewEmpSatisfaction'; Side = 'Left' }
                @{ Name = 'NewSpecialProjectsCount'; Side = 'Left' }
                @{ Name = 'NewDeptID'; Side = 'Right' }
                @{ Name = 'NewPositionID'; Side = 'Right' }
                @{ Name = 'NewManagerID'; Side = 'Right' }
            )
        }
        Merge2 = @{
            Name = 'Jointure de fusion 1'
            LeftComponent = 'Jointure de fusion'
            RightComponent = 'Trier 2'
            LeftKey = 'NewEmpID'
            RightKey = 'NewEmpID_2'
            LeftColumns = @('NewEmpID', 'NewAbsences', 'NewDaysLateLast30', 'NewEngagementSurvey', 'NewEmpSatisfaction', 'NewSpecialProjectsCount', 'NewDeptID', 'NewPositionID', 'NewManagerID')
            RightColumns = @('NewEmpID_2', 'NewState', 'NewZip', 'NewRecruitmentSource', 'NewFromDiversityJobFairID', 'NewPerfScoreID', 'NewPerformanceScore', 'NewDateofHire', 'NewLastPerformanceReviewDate')
            OutputColumns = @(
                @{ Name = 'NewEmpID'; Side = 'Left' }
                @{ Name = 'NewAbsences'; Side = 'Left' }
                @{ Name = 'NewDaysLateLast30'; Side = 'Left' }
                @{ Name = 'NewEngagementSurvey'; Side = 'Left' }
                @{ Name = 'NewEmpSatisfaction'; Side = 'Left' }
                @{ Name = 'NewSpecialProjectsCount'; Side = 'Left' }
                @{ Name = 'NewDeptID'; Side = 'Left' }
                @{ Name = 'NewPositionID'; Side = 'Left' }
                @{ Name = 'NewManagerID'; Side = 'Left' }
                @{ Name = 'NewState'; Side = 'Right' }
                @{ Name = 'NewZip'; Side = 'Right' }
                @{ Name = 'NewRecruitmentSource'; Side = 'Right' }
                @{ Name = 'NewFromDiversityJobFairID'; Side = 'Right' }
                @{ Name = 'NewPerfScoreID'; Side = 'Right' }
                @{ Name = 'NewPerformanceScore'; Side = 'Right' }
                @{ Name = 'NewDateofHire'; Side = 'Right' }
                @{ Name = 'NewLastPerformanceReviewDate'; Side = 'Right' }
            )
        }
        FinalColumns = @(
            @{ Output = 'NewEmpID'; Target = 'EmpID' }
            @{ Output = 'NewDeptID'; Target = 'DeptID' }
            @{ Output = 'NewPositionID'; Target = 'PositionID' }
            @{ Output = 'NewManagerID'; Target = 'ManagerID' }
            @{ Output = 'NewState'; Target = 'State' }
            @{ Output = 'NewZip'; Target = 'Zip' }
            @{ Output = 'NewRecruitmentSource'; Target = 'RecruitmentSource' }
            @{ Output = 'NewFromDiversityJobFairID'; Target = 'FromDiversityJobFairID' }
            @{ Output = 'NewPerfScoreID'; Target = 'PerfScoreID' }
            @{ Output = 'NewPerformanceScore'; Target = 'PerformanceScore' }
            @{ Output = 'NewDateofHire'; Target = 'DateofHire' }
            @{ Output = 'NewLastPerformanceReviewDate'; Target = 'LastPerformanceReview_Date' }
            @{ Output = 'NewAbsences'; Target = 'Absences' }
            @{ Output = 'NewDaysLateLast30'; Target = 'DaysLateLast30' }
            @{ Output = 'NewEngagementSurvey'; Target = 'EngagementSurvey' }
            @{ Output = 'NewEmpSatisfaction'; Target = 'EmpSatisfaction' }
            @{ Output = 'NewSpecialProjectsCount'; Target = 'SpecialProjectsCount' }
        )
    }
    @{
        Name = 'FactEmploymentCompensation'
        Table = 'FactEmploymentCompensation'
        Key = 'EmploymentCompensationKey'
        Branches = @(
            @{
                SourceName = 'Source du fichier plat'
                ConversionName = $ConversionComponentBase
                SortName = 'Trier'
                SortKey = 'NewEmpID'
                Columns = @(
                    @{ Source = 'EmpID'; Output = 'NewEmpID'; Type = 'i4' }
                    @{ Source = 'Salary'; Output = 'NewSalary'; Type = 'numeric'; Precision = 12; Scale = 2 }
                    @{ Source = 'Termd'; Output = 'NewTermd'; Type = 'i4' }
                    @{ Source = 'Tenure'; Output = 'NewTenure'; Type = 'i4' }
                    @{ Source = 'TerminationFlag'; Output = 'NewTerminationFlag'; Type = 'i4' }
                )
            }
            @{
                SourceName = 'Source du fichier plat 1'
                ConversionName = "$ConversionComponentBase 1"
                SortName = 'Trier 1'
                SortKey = 'NewEmpID_1'
                Columns = @(
                    @{ Source = 'EmpID'; Output = 'NewEmpID_1'; Type = 'i4' }
                    @{ Source = 'DeptID'; Output = 'NewDeptID'; Type = 'i4' }
                    @{ Source = 'PositionID'; Output = 'NewPositionID'; Type = 'i4' }
                    @{ Source = 'ManagerID'; Output = 'NewManagerID'; Type = 'i4' }
                )
            }
            @{
                SourceName = 'Source du fichier plat 2'
                ConversionName = "$ConversionComponentBase 2"
                SortName = 'Trier 2'
                SortKey = 'NewEmpID_2'
                Columns = @(
                    @{ Source = 'EmpID'; Output = 'NewEmpID_2'; Type = 'i4' }
                    @{ Source = 'State'; Output = 'NewState'; Type = 'wstr'; Length = 10 }
                    @{ Source = 'Zip'; Output = 'NewZip'; Type = 'wstr'; Length = 20 }
                    @{ Source = 'DateofHire'; Output = 'NewDateofHire'; Type = 'dbDate' }
                    @{ Source = 'DateofTermination'; Output = 'NewDateofTermination'; Type = 'dbDate'; ConversionDisposition = 'IgnoreFailure' }
                )
            }
        )
        Merge1 = @{
            Name = 'Jointure de fusion'
            LeftComponent = 'Trier'
            RightComponent = 'Trier 1'
            LeftKey = 'NewEmpID'
            RightKey = 'NewEmpID_1'
            LeftColumns = @('NewEmpID', 'NewSalary', 'NewTermd', 'NewTenure', 'NewTerminationFlag')
            RightColumns = @('NewEmpID_1', 'NewDeptID', 'NewPositionID', 'NewManagerID')
            OutputColumns = @(
                @{ Name = 'NewEmpID'; Side = 'Left' }
                @{ Name = 'NewSalary'; Side = 'Left' }
                @{ Name = 'NewTermd'; Side = 'Left' }
                @{ Name = 'NewTenure'; Side = 'Left' }
                @{ Name = 'NewTerminationFlag'; Side = 'Left' }
                @{ Name = 'NewDeptID'; Side = 'Right' }
                @{ Name = 'NewPositionID'; Side = 'Right' }
                @{ Name = 'NewManagerID'; Side = 'Right' }
            )
        }
        Merge2 = @{
            Name = 'Jointure de fusion 1'
            LeftComponent = 'Jointure de fusion'
            RightComponent = 'Trier 2'
            LeftKey = 'NewEmpID'
            RightKey = 'NewEmpID_2'
            LeftColumns = @('NewEmpID', 'NewSalary', 'NewTermd', 'NewTenure', 'NewTerminationFlag', 'NewDeptID', 'NewPositionID', 'NewManagerID')
            RightColumns = @('NewEmpID_2', 'NewState', 'NewZip', 'NewDateofHire', 'NewDateofTermination')
            OutputColumns = @(
                @{ Name = 'NewEmpID'; Side = 'Left' }
                @{ Name = 'NewSalary'; Side = 'Left' }
                @{ Name = 'NewTermd'; Side = 'Left' }
                @{ Name = 'NewTenure'; Side = 'Left' }
                @{ Name = 'NewTerminationFlag'; Side = 'Left' }
                @{ Name = 'NewDeptID'; Side = 'Left' }
                @{ Name = 'NewPositionID'; Side = 'Left' }
                @{ Name = 'NewManagerID'; Side = 'Left' }
                @{ Name = 'NewState'; Side = 'Right' }
                @{ Name = 'NewZip'; Side = 'Right' }
                @{ Name = 'NewDateofHire'; Side = 'Right' }
                @{ Name = 'NewDateofTermination'; Side = 'Right' }
            )
        }
        FinalColumns = @(
            @{ Output = 'NewEmpID'; Target = 'EmpID' }
            @{ Output = 'NewDeptID'; Target = 'DeptID' }
            @{ Output = 'NewPositionID'; Target = 'PositionID' }
            @{ Output = 'NewManagerID'; Target = 'ManagerID' }
            @{ Output = 'NewState'; Target = 'State' }
            @{ Output = 'NewZip'; Target = 'Zip' }
            @{ Output = 'NewDateofHire'; Target = 'DateofHire' }
            @{ Output = 'NewDateofTermination'; Target = 'DateofTermination' }
            @{ Output = 'NewSalary'; Target = 'Salary' }
            @{ Output = 'NewTermd'; Target = 'Termd' }
            @{ Output = 'NewTenure'; Target = 'Tenure' }
            @{ Output = 'NewTerminationFlag'; Target = 'TerminationFlag' }
        )
    }
)

if (-not (Test-Path -LiteralPath $PackageTemplatePath)) {
    throw "Package template not found: $PackageTemplatePath"
}

if (-not (Test-Path -LiteralPath $TaskTemplatePath)) {
    throw "Task template not found: $TaskTemplatePath"
}

$packageDoc = New-Object System.Xml.XmlDocument
$packageDoc.PreserveWhitespace = $true
$packageDoc.Load($PackageTemplatePath)

$packageNs = New-Object System.Xml.XmlNamespaceManager($packageDoc.NameTable)
$packageNs.AddNamespace('DTS', $DtsNamespace)

Update-OleDbProvider -PackageDoc $packageDoc -NamespaceManager $packageNs

$taskTemplateDoc = New-Object System.Xml.XmlDocument
$taskTemplateDoc.PreserveWhitespace = $true
$taskTemplateDoc.Load($TaskTemplatePath)

$taskTemplateNs = New-Object System.Xml.XmlNamespaceManager($taskTemplateDoc.NameTable)
$taskTemplateNs.AddNamespace('DTS', $DtsNamespace)

$taskTemplate = [System.Xml.XmlElement]$taskTemplateDoc.SelectSingleNode("/DTS:Executable/DTS:Executables/DTS:Executable[@DTS:ObjectName='orders']", $taskTemplateNs)
if ($null -eq $taskTemplate) {
    throw 'Template task "orders" not found in Fait.dtsx.'
}

$executablesNode = $packageDoc.SelectSingleNode('/DTS:Executable/DTS:Executables', $packageNs)
Clear-Children -Node $executablesNode

foreach ($config in $factConfigs) {
    $taskClone = [System.Xml.XmlElement]$packageDoc.ImportNode($taskTemplate, $true)
    Replace-InNode -Node $taskClone -OldValue 'Package\orders' -NewValue ("Package\" + $config.Name)
    Refresh-DtsIds -Element $taskClone -NamespaceManager $packageNs
    Set-DtsAttr -Element $taskClone -LocalName 'ObjectName' -Value $config.Name
    Set-DtsAttr -Element $taskClone -LocalName 'refId' -Value ("Package\" + $config.Name)
    Set-DtsAttr -Element $taskClone -LocalName 'CreationDate' -Value ((Get-Date).ToString('M/d/yyyy h:mm:ss tt'))

    Set-ConnectionRefs -Task $taskClone -TaskName $config.Name

    foreach ($branch in $config.Branches) {
        Update-FlatFileSourceComponent -Task $taskClone -TaskName $config.Name -Branch $branch
        Update-ConversionComponent -Task $taskClone -TaskName $config.Name -Branch $branch
        Update-SortComponent -Task $taskClone -TaskName $config.Name -Branch $branch
    }

    $columnIndex = New-ColumnIndex -Config $config
    Update-MergeJoinComponent -Task $taskClone -TaskName $config.Name -MergeConfig $config.Merge1 -ColumnIndex $columnIndex
    Update-MergeJoinComponent -Task $taskClone -TaskName $config.Name -MergeConfig $config.Merge2 -ColumnIndex $columnIndex
    Update-DestinationComponent -Task $taskClone -TaskName $config.Name -Config $config -ColumnIndex $columnIndex
    Update-Paths -Task $taskClone -TaskName $config.Name

    [void]$executablesNode.AppendChild($taskClone)
}

Set-DtsAttr -Element $packageDoc.DocumentElement -LocalName 'ObjectName' -Value 'Facts'
Set-DtsAttr -Element $packageDoc.DocumentElement -LocalName 'DTSID' -Value (New-GuidText)
Set-DtsAttr -Element $packageDoc.DocumentElement -LocalName 'VersionGUID' -Value (New-GuidText)
Set-DtsAttr -Element $packageDoc.DocumentElement -LocalName 'VersionBuild' -Value '2'

$designProperty = $packageDoc.SelectSingleNode('/DTS:Executable/DTS:DesignTimeProperties', $packageNs)
$minimalDesignXml = '<?xml version="1.0"?><Objects Version="8"></Objects>'
Clear-Children -Node $designProperty
[void]$designProperty.AppendChild($packageDoc.CreateCDataSection($minimalDesignXml))

$packageDoc.Save($OutputPath)

[pscustomobject]@{
    OutputPath = $OutputPath
    Facts = $factConfigs.Count
    Method = '3 sources / 3 conversions / 3 tris / 2 merge join / destination'
} | Format-List
