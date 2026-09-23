using System.Globalization;
using HRAnalyticsDashboard.Data;
using HRAnalyticsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace HRAnalyticsDashboard.Services;

public class DashboardService
{
    private readonly SqlConnectionFactory _connectionFactory;

    public DashboardService(SqlConnectionFactory connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<KpiSummary> GetKpiSummaryAsync()
    {
        const string sql = @"
SELECT
    (SELECT COUNT(*) FROM dbo.DimEmployee) AS TotalEmployees,
    (SELECT ISNULL(SUM(Salary), 0) FROM dbo.FactEmploymentCompensation) AS TotalSalary,
    (SELECT ISNULL(AVG(CAST(Salary AS DECIMAL(18,2))), 0) FROM dbo.FactEmploymentCompensation) AS AverageSalary,
    (SELECT ISNULL(SUM(Absences), 0) FROM dbo.FactAttendancePerformance) AS TotalAbsences,
    (SELECT ISNULL(AVG(CAST(EmpSatisfaction AS DECIMAL(18,2))), 0) FROM dbo.FactAttendancePerformance) AS AverageSatisfaction,
    (SELECT ISNULL(AVG(CAST(EngagementSurvey AS DECIMAL(18,2))), 0) FROM dbo.FactAttendancePerformance) AS AverageEngagement,
    (SELECT ISNULL(SUM(TerminationFlag), 0) FROM dbo.FactEmploymentCompensation) AS TerminationCount,
    (SELECT ISNULL(AVG(CAST(Tenure AS DECIMAL(18,2))), 0) FROM dbo.FactEmploymentCompensation) AS AverageTenure;";

        using var connection = _connectionFactory.CreateConnection();
        await connection.OpenAsync();

        using var command = new SqlCommand(sql, connection);
        using var reader = await command.ExecuteReaderAsync();

        if (!await reader.ReadAsync())
        {
            return new KpiSummary();
        }

        return new KpiSummary
        {
            TotalEmployees = GetInt32(reader, "TotalEmployees"),
            TotalSalary = GetDecimal(reader, "TotalSalary"),
            AverageSalary = GetDecimal(reader, "AverageSalary"),
            TotalAbsences = GetInt32(reader, "TotalAbsences"),
            AverageSatisfaction = GetDecimal(reader, "AverageSatisfaction"),
            AverageEngagement = GetDecimal(reader, "AverageEngagement"),
            TerminationCount = GetInt32(reader, "TerminationCount"),
            AverageTenure = GetDecimal(reader, "AverageTenure")
        };
    }

    public async Task<List<DepartmentMetric>> GetEmployeesByDepartmentAsync()
    {
        const string sql = @"
SELECT d.Department, COUNT(DISTINCT f.EmpID) AS EmployeeCount
FROM dbo.FactAttendancePerformance f
JOIN (
    SELECT DeptID, MIN(Department) AS Department
    FROM dbo.DimDepartment
    GROUP BY DeptID
) d ON f.DeptID = d.DeptID
GROUP BY d.Department
ORDER BY EmployeeCount DESC, d.Department;";

        return await QueryAsync(sql, reader => new DepartmentMetric
        {
            Department = GetString(reader, "Department"),
            EmployeeCount = GetInt32(reader, "EmployeeCount")
        });
    }

    public async Task<List<DepartmentMetric>> GetSalaryByDepartmentAsync()
    {
        const string sql = @"
SELECT d.Department, ISNULL(SUM(f.Salary), 0) AS TotalSalary
FROM dbo.FactEmploymentCompensation f
JOIN (
    SELECT DeptID, MIN(Department) AS Department
    FROM dbo.DimDepartment
    GROUP BY DeptID
) d ON f.DeptID = d.DeptID
GROUP BY d.Department
ORDER BY TotalSalary DESC, d.Department;";

        return await QueryAsync(sql, reader => new DepartmentMetric
        {
            Department = GetString(reader, "Department"),
            TotalSalary = GetDecimal(reader, "TotalSalary")
        });
    }

    public async Task<List<DepartmentMetric>> GetAbsencesByDepartmentAsync()
    {
        const string sql = @"
SELECT d.Department, ISNULL(SUM(f.Absences), 0) AS TotalAbsences
FROM dbo.FactAttendancePerformance f
JOIN (
    SELECT DeptID, MIN(Department) AS Department
    FROM dbo.DimDepartment
    GROUP BY DeptID
) d ON f.DeptID = d.DeptID
GROUP BY d.Department
ORDER BY TotalAbsences DESC, d.Department;";

        return await QueryAsync(sql, reader => new DepartmentMetric
        {
            Department = GetString(reader, "Department"),
            TotalAbsences = GetInt32(reader, "TotalAbsences")
        });
    }

    public async Task<List<DepartmentMetric>> GetEngagementByDepartmentAsync()
    {
        const string sql = @"
SELECT d.Department, ISNULL(AVG(CAST(f.EngagementSurvey AS DECIMAL(18,2))), 0) AS AverageEngagement
FROM dbo.FactAttendancePerformance f
JOIN (
    SELECT DeptID, MIN(Department) AS Department
    FROM dbo.DimDepartment
    GROUP BY DeptID
) d ON f.DeptID = d.DeptID
GROUP BY d.Department
ORDER BY AverageEngagement DESC, d.Department;";

        return await QueryAsync(sql, reader => new DepartmentMetric
        {
            Department = GetString(reader, "Department"),
            AverageEngagement = GetDecimal(reader, "AverageEngagement")
        });
    }

    public async Task<List<PositionMetric>> GetAbsencesByPositionAsync()
    {
        const string sql = @"
SELECT p.Position,
       ISNULL(SUM(f.Absences), 0) AS TotalAbsences,
       ISNULL(AVG(CAST(f.DaysLateLast30 AS DECIMAL(18,2))), 0) AS AverageDaysLate,
       COUNT(DISTINCT f.EmpID) AS EmployeeCount
FROM dbo.FactAttendancePerformance f
JOIN (
    SELECT PositionID, MIN(Position) AS Position
    FROM dbo.DimPosition
    GROUP BY PositionID
) p ON f.PositionID = p.PositionID
GROUP BY p.Position
ORDER BY TotalAbsences DESC, p.Position;";

        return await QueryAsync(sql, reader => new PositionMetric
        {
            Position = GetString(reader, "Position"),
            TotalAbsences = GetInt32(reader, "TotalAbsences"),
            AverageDaysLate = GetDecimal(reader, "AverageDaysLate"),
            EmployeeCount = GetInt32(reader, "EmployeeCount")
        });
    }

    public async Task<List<ManagerMetric>> GetSatisfactionByManagerAsync()
    {
        const string sql = @"
SELECT m.ManagerName,
       ISNULL(AVG(CAST(f.EmpSatisfaction AS DECIMAL(18,2))), 0) AS AvgSatisfaction,
       ISNULL(AVG(CAST(f.EngagementSurvey AS DECIMAL(18,2))), 0) AS AvgEngagement,
       COUNT(DISTINCT f.EmpID) AS EmployeeCount
FROM dbo.FactAttendancePerformance f
JOIN (
    SELECT ManagerID, MIN(ManagerName) AS ManagerName
    FROM dbo.DimManager
    GROUP BY ManagerID
) m ON f.ManagerID = m.ManagerID
GROUP BY m.ManagerName
ORDER BY AvgSatisfaction DESC, m.ManagerName;";

        return await QueryAsync(sql, reader => new ManagerMetric
        {
            ManagerName = GetString(reader, "ManagerName"),
            AverageSatisfaction = GetDecimal(reader, "AvgSatisfaction"),
            AverageEngagement = GetDecimal(reader, "AvgEngagement"),
            EmployeeCount = GetInt32(reader, "EmployeeCount")
        });
    }

    public async Task<List<RecruitmentMetric>> GetEngagementByRecruitmentAsync()
    {
        const string sql = @"
SELECT r.RecruitmentSource,
       COUNT(DISTINCT f.EmpID) AS EmployeeCount,
       ISNULL(AVG(CAST(f.EngagementSurvey AS DECIMAL(18,2))), 0) AS AvgEngagement,
       ISNULL(AVG(CAST(f.EmpSatisfaction AS DECIMAL(18,2))), 0) AS AvgSatisfaction
FROM dbo.FactAttendancePerformance f
JOIN dbo.DimRecruitment r
    ON f.FromDiversityJobFairID = r.FromDiversityJobFairID
    AND f.RecruitmentSource = r.RecruitmentSource
GROUP BY r.RecruitmentSource
ORDER BY EmployeeCount DESC, r.RecruitmentSource;";

        return await QueryAsync(sql, reader => new RecruitmentMetric
        {
            RecruitmentSource = GetString(reader, "RecruitmentSource"),
            EmployeeCount = GetInt32(reader, "EmployeeCount"),
            AverageEngagement = GetDecimal(reader, "AvgEngagement"),
            AverageSatisfaction = GetDecimal(reader, "AvgSatisfaction")
        });
    }

    public async Task<List<PerformanceMetric>> GetProjectsByPerformanceAsync()
    {
        const string sql = @"
SELECT p.PerformanceScore,
       ISNULL(SUM(f.SpecialProjectsCount), 0) AS TotalProjects,
       ISNULL(AVG(CAST(f.EmpSatisfaction AS DECIMAL(18,2))), 0) AS AverageSatisfaction
FROM dbo.FactAttendancePerformance f
JOIN dbo.DimPerformance p
    ON f.PerfScoreID = p.PerfScoreID
    AND f.PerformanceScore = p.PerformanceScore
GROUP BY p.PerformanceScore
ORDER BY TotalProjects DESC, p.PerformanceScore;";

        return await QueryAsync(sql, reader => new PerformanceMetric
        {
            PerformanceScore = GetString(reader, "PerformanceScore"),
            TotalProjects = GetInt32(reader, "TotalProjects"),
            AverageSatisfaction = GetDecimal(reader, "AverageSatisfaction")
        });
    }

    public async Task<List<TurnoverMetric>> GetTurnoverByDepartmentAsync()
    {
        const string sql = @"
SELECT d.Department,
       ISNULL(SUM(f.TerminationFlag), 0) AS TerminationCount,
       ISNULL(AVG(CAST(f.Tenure AS DECIMAL(18,2))), 0) AS AverageTenure
FROM dbo.FactEmploymentCompensation f
JOIN (
    SELECT DeptID, MIN(Department) AS Department
    FROM dbo.DimDepartment
    GROUP BY DeptID
) d ON f.DeptID = d.DeptID
GROUP BY d.Department
ORDER BY TerminationCount DESC, d.Department;";

        return await QueryAsync(sql, reader => new TurnoverMetric
        {
            Department = GetString(reader, "Department"),
            TerminationCount = GetInt32(reader, "TerminationCount"),
            AverageTenure = GetDecimal(reader, "AverageTenure")
        });
    }

    public async Task<List<DetailedAnalysisRow>> GetDetailedAnalysisRowsAsync()
    {
        const string sql = @"
SELECT
    ec.EmpID,
    e.Employee_Name,
    d.Department,
    p.Position,
    m.ManagerName,
    ISNULL(r.RecruitmentSource, 'Unknown') AS RecruitmentSource,
    ISNULL(ps.PerformanceScore, 'Unknown') AS PerformanceScore,
    ISNULL(l.State, '') AS State,
    ISNULL(ec.Salary, 0) AS Salary,
    ISNULL(ap.Absences, 0) AS Absences,
    ISNULL(CAST(ap.EmpSatisfaction AS DECIMAL(18,2)), 0) AS EmpSatisfaction,
    ISNULL(CAST(ap.EngagementSurvey AS DECIMAL(18,2)), 0) AS EngagementSurvey,
    ISNULL(CAST(ec.Tenure AS DECIMAL(18,2)), 0) AS Tenure,
    ISNULL(ec.TerminationFlag, 0) AS TerminationFlag
FROM dbo.FactEmploymentCompensation ec
LEFT JOIN dbo.FactAttendancePerformance ap
    ON ec.EmpID = ap.EmpID
LEFT JOIN (
    SELECT EmpID, MIN(Employee_Name) AS Employee_Name
    FROM dbo.DimEmployee
    GROUP BY EmpID
) e ON ec.EmpID = e.EmpID
LEFT JOIN (
    SELECT DeptID, MIN(Department) AS Department
    FROM dbo.DimDepartment
    GROUP BY DeptID
) d ON ec.DeptID = d.DeptID
LEFT JOIN (
    SELECT PositionID, MIN(Position) AS Position
    FROM dbo.DimPosition
    GROUP BY PositionID
) p ON ec.PositionID = p.PositionID
LEFT JOIN (
    SELECT ManagerID, MIN(ManagerName) AS ManagerName
    FROM dbo.DimManager
    GROUP BY ManagerID
) m ON ec.ManagerID = m.ManagerID
LEFT JOIN dbo.DimRecruitment r
    ON ap.FromDiversityJobFairID = r.FromDiversityJobFairID
    AND ap.RecruitmentSource = r.RecruitmentSource
LEFT JOIN dbo.DimPerformance ps
    ON ap.PerfScoreID = ps.PerfScoreID
    AND ap.PerformanceScore = ps.PerformanceScore
LEFT JOIN (
    SELECT State, Zip
    FROM dbo.DimLocation
    GROUP BY State, Zip
) l ON ec.State = l.State AND ec.Zip = l.Zip
ORDER BY d.Department, p.Position, e.Employee_Name;";

        return await QueryAsync(sql, reader => new DetailedAnalysisRow
        {
            EmpId = GetInt32(reader, "EmpID"),
            EmployeeName = GetString(reader, "Employee_Name"),
            Department = GetString(reader, "Department"),
            Position = GetString(reader, "Position"),
            ManagerName = GetString(reader, "ManagerName"),
            RecruitmentSource = GetString(reader, "RecruitmentSource"),
            PerformanceScore = GetString(reader, "PerformanceScore"),
            State = GetString(reader, "State"),
            Salary = GetDecimal(reader, "Salary"),
            Absences = GetInt32(reader, "Absences"),
            EmpSatisfaction = GetDecimal(reader, "EmpSatisfaction"),
            EngagementSurvey = GetDecimal(reader, "EngagementSurvey"),
            Tenure = GetDecimal(reader, "Tenure"),
            TerminationFlag = GetInt32(reader, "TerminationFlag")
        });
    }

    private async Task<List<T>> QueryAsync<T>(string sql, Func<SqlDataReader, T> map)
    {
        var items = new List<T>();

        using var connection = _connectionFactory.CreateConnection();
        await connection.OpenAsync();

        using var command = new SqlCommand(sql, connection);
        using var reader = await command.ExecuteReaderAsync();

        while (await reader.ReadAsync())
        {
            items.Add(map(reader));
        }

        return items;
    }

    private static string GetString(SqlDataReader reader, string columnName)
    {
        var value = reader[columnName];
        return value == DBNull.Value ? string.Empty : Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty;
    }

    private static int GetInt32(SqlDataReader reader, string columnName)
    {
        var value = reader[columnName];
        return value == DBNull.Value ? 0 : Convert.ToInt32(value, CultureInfo.InvariantCulture);
    }

    private static decimal GetDecimal(SqlDataReader reader, string columnName)
    {
        var value = reader[columnName];
        return value == DBNull.Value ? 0m : Convert.ToDecimal(value, CultureInfo.InvariantCulture);
    }
}
