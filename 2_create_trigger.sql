USE BI_Transformation
GO

CREATE OR ALTER TRIGGER TR_Payment_Ownership
ON [dbo].[Fact_PTP]
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Store PTPs in temp table
        SELECT 
            i.ID AS PTPID,
            i.IDX AS MatterID,
            i.[PTP DateTime] AS PTPDateTime,
            i.PaymentMethod,
            i.FirstPayment,
            i.MonthlyAmount,
            i.Settlement_Flag AS IsSettlement,
            i.UserID
        INTO #TempNewPTPs
        FROM inserted i;

        -- Process new PTPs
        EXEC SP_Assign_Payment_Ownership;
    END TRY
    BEGIN CATCH
        -- Log error details
        INSERT INTO Incentives.dbo.Payment_Ownership_ErrorLog (
            PTPID,
            MatterID,
            PaymentMethod,
            ErrorMessage,
            ErrorLine,
            ErrorNumber,
            ErrorProcedure,
            ErrorSeverity,
            ErrorState
        )
        SELECT 
            t.PTPID,
            t.MatterID,
            t.PaymentMethod,
            ERROR_MESSAGE(),
            ERROR_LINE(),
            ERROR_NUMBER(),
            ERROR_PROCEDURE(),
            ERROR_SEVERITY(),
            ERROR_STATE()
        FROM #TempNewPTPs t;

    END CATCH;

    -- Clean up temp table
    IF OBJECT_ID('tempdb..#TempNewPTPs') IS NOT NULL
        DROP TABLE #TempNewPTPs;
END;