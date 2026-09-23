# HR Analytics BI & Data Warehouse

Projet pédagogique de Business Intelligence qui transforme des données RH CSV en entrepôt SQL Server, puis les présente dans un dashboard Blazor.

## Pipeline

CSV → nettoyage PowerShell → ETL SSIS → SQL Server DW_RH → dashboard Blazor

## Stack

- SQL Server et SSIS
- PowerShell
- C# / ASP.NET Core Blazor
- MudBlazor et ApexCharts

Le modèle comprend les faits FactAttendancePerformance et FactEmploymentCompensation, ainsi que les dimensions Employee, Department, Position, Manager, Recruitment, Performance, Location et Date.

Le dashboard calcule des KPI déterministes : effectifs, salaires, absences, satisfaction, engagement et turnover. Les « insights » sont des règles calculées à partir de ces KPI, pas des fonctionnalités d’IA.

## Configuration DW_RH

1. Créez la base SQL Server DW_RH et exécutez les scripts de Data/ dans l’ordre adapté à votre environnement.
2. Dans SSIS/SSDT, configurez la connexion OLE DB DW_RH vers votre instance SQL Server et le fichier plat HRDataset_Clean_Validated.csv vers Data/HRDataset_Clean_Validated.csv.
3. Exécutez le nettoyage si nécessaire :

   ~~~powershell
   ./Data/clean_hrdataset.ps1
   ~~~

Les scripts SSAS qui modifient un projet externe demandent explicitement son chemin avec -ProjectPath ; aucun chemin machine personnel n’est enregistré dans le dépôt.

## Lancer le dashboard

Copiez HRAnalyticsDashboard/appsettings.example.json vers une configuration locale non versionnée et renseignez ConnectionStrings:DW_RH, puis :

~~~powershell
cd HRAnalyticsDashboard
dotnet restore
dotnet run
~~~

## Limites

Les packages SSIS nécessitent SSDT/SSIS et SQL Server : ils ne sont pas exécutés dans la CI Linux. Le dashboard nécessite une base DW_RH alimentée pour afficher des données.
