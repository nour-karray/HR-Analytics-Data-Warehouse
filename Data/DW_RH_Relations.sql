USE DW_RH;
GO

/* 1. Aligner le type de Zip pour la relation Location */
IF EXISTS (
    SELECT 1
    FROM sys.columns c
    INNER JOIN sys.tables t ON c.object_id = t.object_id
    INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name = N'dbo'
      AND t.name = N'DimLocation'
      AND c.name = N'Zip'
      AND TYPE_NAME(c.user_type_id) <> N'nvarchar'
)
BEGIN
    ALTER TABLE dbo.DimLocation ALTER COLUMN Zip NVARCHAR(20) NULL;
END;
GO

/* 2. Supprimer les lignes sans cle metier dans les dimensions */
DELETE FROM dbo.DimEmployee WHERE EmpID IS NULL;
DELETE FROM dbo.DimDepartment WHERE DeptID IS NULL;
DELETE FROM dbo.DimPosition WHERE PositionID IS NULL;
DELETE FROM dbo.DimManager WHERE ManagerID IS NULL;
DELETE FROM dbo.DimRecruitment WHERE RecruitmentSource IS NULL OR FromDiversityJobFairID IS NULL;
DELETE FROM dbo.DimPerformance WHERE PerfScoreID IS NULL OR PerformanceScore IS NULL;
DELETE FROM dbo.DimDate WHERE FullDate IS NULL;
DELETE FROM dbo.DimLocation WHERE State IS NULL OR Zip IS NULL;
GO

/* 3. Dedupliquer les dimensions sur les cles metier */
;WITH x AS (
    SELECT EmployeeKey, ROW_NUMBER() OVER (PARTITION BY EmpID ORDER BY EmployeeKey) AS rn
    FROM dbo.DimEmployee
)
DELETE FROM x WHERE rn > 1;
GO

;WITH x AS (
    SELECT DepartmentKey, ROW_NUMBER() OVER (PARTITION BY DeptID ORDER BY DepartmentKey) AS rn
    FROM dbo.DimDepartment
)
DELETE FROM x WHERE rn > 1;
GO

;WITH x AS (
    SELECT PositionKey, ROW_NUMBER() OVER (PARTITION BY PositionID ORDER BY PositionKey) AS rn
    FROM dbo.DimPosition
)
DELETE FROM x WHERE rn > 1;
GO

;WITH x AS (
    SELECT ManagerKey, ROW_NUMBER() OVER (PARTITION BY ManagerID ORDER BY ManagerKey) AS rn
    FROM dbo.DimManager
)
DELETE FROM x WHERE rn > 1;
GO

;WITH x AS (
    SELECT RecruitmentKey, ROW_NUMBER() OVER (PARTITION BY RecruitmentSource, FromDiversityJobFairID ORDER BY RecruitmentKey) AS rn
    FROM dbo.DimRecruitment
)
DELETE FROM x WHERE rn > 1;
GO

;WITH x AS (
    SELECT PerformanceKey, ROW_NUMBER() OVER (PARTITION BY PerfScoreID, PerformanceScore ORDER BY PerformanceKey) AS rn
    FROM dbo.DimPerformance
)
DELETE FROM x WHERE rn > 1;
GO

;WITH x AS (
    SELECT DateKey, ROW_NUMBER() OVER (PARTITION BY FullDate ORDER BY DateKey) AS rn
    FROM dbo.DimDate
)
DELETE FROM x WHERE rn > 1;
GO

;WITH x AS (
    SELECT LocationKey, ROW_NUMBER() OVER (PARTITION BY State, Zip ORDER BY LocationKey) AS rn
    FROM dbo.DimLocation
)
DELETE FROM x WHERE rn > 1;
GO

/* 4. Nettoyer les anciennes contraintes qui ne correspondent plus au modele */
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimRecruitment_FromDiversityJobFairID')
    ALTER TABLE dbo.DimRecruitment DROP CONSTRAINT UQ_DimRecruitment_FromDiversityJobFairID;
GO

IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimPerformance_PerfScoreID')
    ALTER TABLE dbo.DimPerformance DROP CONSTRAINT UQ_DimPerformance_PerfScoreID;
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimPerformance', N'F') IS NOT NULL
    ALTER TABLE dbo.FactAttendancePerformance DROP CONSTRAINT FK_FactAttendancePerformance_DimPerformance;
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimRecruitment', N'F') IS NOT NULL
    ALTER TABLE dbo.FactAttendancePerformance DROP CONSTRAINT FK_FactAttendancePerformance_DimRecruitment;
GO

IF COL_LENGTH(N'dbo.FactAttendancePerformance', N'RecruitmentSource') IS NULL
BEGIN
    ALTER TABLE dbo.FactAttendancePerformance
    ADD RecruitmentSource NVARCHAR(100) NULL;
END;
GO

IF COL_LENGTH(N'dbo.FactAttendancePerformance', N'PerformanceScore') IS NULL
BEGIN
    ALTER TABLE dbo.FactAttendancePerformance
    ADD PerformanceScore NVARCHAR(50) NULL;
END;
GO

/* 5. Creer les contraintes UNIQUE sur les colonnes parentes */
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimEmployee_EmpID')
    ALTER TABLE dbo.DimEmployee ADD CONSTRAINT UQ_DimEmployee_EmpID UNIQUE (EmpID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimDepartment_DeptID')
    ALTER TABLE dbo.DimDepartment ADD CONSTRAINT UQ_DimDepartment_DeptID UNIQUE (DeptID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimPosition_PositionID')
    ALTER TABLE dbo.DimPosition ADD CONSTRAINT UQ_DimPosition_PositionID UNIQUE (PositionID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimManager_ManagerID')
    ALTER TABLE dbo.DimManager ADD CONSTRAINT UQ_DimManager_ManagerID UNIQUE (ManagerID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimRecruitment_Source_JobFair')
    ALTER TABLE dbo.DimRecruitment ADD CONSTRAINT UQ_DimRecruitment_Source_JobFair UNIQUE (RecruitmentSource, FromDiversityJobFairID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimPerformance_PerfScore')
    ALTER TABLE dbo.DimPerformance ADD CONSTRAINT UQ_DimPerformance_PerfScore UNIQUE (PerfScoreID, PerformanceScore);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimDate_FullDate')
    ALTER TABLE dbo.DimDate ADD CONSTRAINT UQ_DimDate_FullDate UNIQUE (FullDate);
GO

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_DimLocation_State_Zip')
    ALTER TABLE dbo.DimLocation ADD CONSTRAINT UQ_DimLocation_State_Zip UNIQUE (State, Zip);
GO

/* 6. Creer et valider les relations avec la structure actuelle des faits.
   WITH CHECK refuse les donnees incoherentes et laisse les contraintes trusted. */
IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimEmployee', N'F') IS NULL
    ALTER TABLE dbo.FactAttendancePerformance WITH CHECK
    ADD CONSTRAINT FK_FactAttendancePerformance_DimEmployee
        FOREIGN KEY (EmpID) REFERENCES dbo.DimEmployee(EmpID);
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimDepartment', N'F') IS NULL
    ALTER TABLE dbo.FactAttendancePerformance WITH CHECK
    ADD CONSTRAINT FK_FactAttendancePerformance_DimDepartment
        FOREIGN KEY (DeptID) REFERENCES dbo.DimDepartment(DeptID);
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimPosition', N'F') IS NULL
    ALTER TABLE dbo.FactAttendancePerformance WITH CHECK
    ADD CONSTRAINT FK_FactAttendancePerformance_DimPosition
        FOREIGN KEY (PositionID) REFERENCES dbo.DimPosition(PositionID);
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimManager', N'F') IS NULL
    ALTER TABLE dbo.FactAttendancePerformance WITH CHECK
    ADD CONSTRAINT FK_FactAttendancePerformance_DimManager
        FOREIGN KEY (ManagerID) REFERENCES dbo.DimManager(ManagerID);
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimLocation', N'F') IS NULL
    ALTER TABLE dbo.FactAttendancePerformance WITH CHECK
    ADD CONSTRAINT FK_FactAttendancePerformance_DimLocation
        FOREIGN KEY (State, Zip) REFERENCES dbo.DimLocation(State, Zip);
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimDate_Hire', N'F') IS NULL
    ALTER TABLE dbo.FactAttendancePerformance WITH CHECK
    ADD CONSTRAINT FK_FactAttendancePerformance_DimDate_Hire
        FOREIGN KEY (DateofHire) REFERENCES dbo.DimDate(FullDate);
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimDate_Review', N'F') IS NULL
    ALTER TABLE dbo.FactAttendancePerformance WITH CHECK
    ADD CONSTRAINT FK_FactAttendancePerformance_DimDate_Review
        FOREIGN KEY (LastPerformanceReview_Date) REFERENCES dbo.DimDate(FullDate);
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimRecruitment', N'F') IS NULL
    ALTER TABLE dbo.FactAttendancePerformance WITH CHECK
    ADD CONSTRAINT FK_FactAttendancePerformance_DimRecruitment
        FOREIGN KEY (RecruitmentSource, FromDiversityJobFairID)
        REFERENCES dbo.DimRecruitment(RecruitmentSource, FromDiversityJobFairID);
GO

IF OBJECT_ID(N'dbo.FK_FactAttendancePerformance_DimPerformance', N'F') IS NULL
    ALTER TABLE dbo.FactAttendancePerformance WITH CHECK
    ADD CONSTRAINT FK_FactAttendancePerformance_DimPerformance
        FOREIGN KEY (PerfScoreID, PerformanceScore)
        REFERENCES dbo.DimPerformance(PerfScoreID, PerformanceScore);
GO

IF OBJECT_ID(N'dbo.FK_FactEmploymentCompensation_DimEmployee', N'F') IS NULL
    ALTER TABLE dbo.FactEmploymentCompensation WITH CHECK
    ADD CONSTRAINT FK_FactEmploymentCompensation_DimEmployee
        FOREIGN KEY (EmpID) REFERENCES dbo.DimEmployee(EmpID);
GO

IF OBJECT_ID(N'dbo.FK_FactEmploymentCompensation_DimDepartment', N'F') IS NULL
    ALTER TABLE dbo.FactEmploymentCompensation WITH CHECK
    ADD CONSTRAINT FK_FactEmploymentCompensation_DimDepartment
        FOREIGN KEY (DeptID) REFERENCES dbo.DimDepartment(DeptID);
GO

IF OBJECT_ID(N'dbo.FK_FactEmploymentCompensation_DimPosition', N'F') IS NULL
    ALTER TABLE dbo.FactEmploymentCompensation WITH CHECK
    ADD CONSTRAINT FK_FactEmploymentCompensation_DimPosition
        FOREIGN KEY (PositionID) REFERENCES dbo.DimPosition(PositionID);
GO

IF OBJECT_ID(N'dbo.FK_FactEmploymentCompensation_DimManager', N'F') IS NULL
    ALTER TABLE dbo.FactEmploymentCompensation WITH CHECK
    ADD CONSTRAINT FK_FactEmploymentCompensation_DimManager
        FOREIGN KEY (ManagerID) REFERENCES dbo.DimManager(ManagerID);
GO

IF OBJECT_ID(N'dbo.FK_FactEmploymentCompensation_DimLocation', N'F') IS NULL
    ALTER TABLE dbo.FactEmploymentCompensation WITH CHECK
    ADD CONSTRAINT FK_FactEmploymentCompensation_DimLocation
        FOREIGN KEY (State, Zip) REFERENCES dbo.DimLocation(State, Zip);
GO

IF OBJECT_ID(N'dbo.FK_FactEmploymentCompensation_DimDate_Hire', N'F') IS NULL
    ALTER TABLE dbo.FactEmploymentCompensation WITH CHECK
    ADD CONSTRAINT FK_FactEmploymentCompensation_DimDate_Hire
        FOREIGN KEY (DateofHire) REFERENCES dbo.DimDate(FullDate);
GO

IF OBJECT_ID(N'dbo.FK_FactEmploymentCompensation_DimDate_Termination', N'F') IS NULL
    ALTER TABLE dbo.FactEmploymentCompensation WITH CHECK
    ADD CONSTRAINT FK_FactEmploymentCompensation_DimDate_Termination
        FOREIGN KEY (DateofTermination) REFERENCES dbo.DimDate(FullDate);
GO

/* Revalider aussi les contraintes deja presentes afin qu'elles soient trusted. */
ALTER TABLE dbo.FactAttendancePerformance WITH CHECK CHECK CONSTRAINT ALL;
ALTER TABLE dbo.FactEmploymentCompensation WITH CHECK CHECK CONSTRAINT ALL;
GO

/*
Les FKs vers DimPerformance et DimRecruitment sont maintenant possibles car
FactAttendancePerformance contient aussi les colonnes texte manquantes :
- RecruitmentSource
- PerformanceScore
*/
