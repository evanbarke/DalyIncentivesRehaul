USE [BI_Transformation]
GO

-- Drop procedure if it exists
IF EXISTS (SELECT * FROM sys.procedures WHERE name = 'SP_Calculate_Payment_Commission')
    DROP PROCEDURE [dbo].[SP_Calculate_Payment_Commission]
GO

CREATE PROCEDURE [dbo].[SP_Calculate_Payment_Commission]
    @CycleDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    -- If no date provided, use yesterday
    IF @CycleDate IS NULL
        SET @CycleDate = DATEADD(DAY, -1, CAST(GETDATE() AS DATE));
    
    BEGIN TRY
        BEGIN TRANSACTION;
        
        -- Create a work table for commission calculation
        IF OBJECT_ID('tempdb..#PaymentCommission') IS NOT NULL
            DROP TABLE #PaymentCommission;
            
        CREATE TABLE #PaymentCommission (
            PaymentID INT,
            UserID INT,
            ClientID INT,
            PaymentDate DATETIME,
            PaymentAmount DECIMAL(18,2),
            CommissionableAmount DECIMAL(18,2),
            CategoryID INT,
            IsFirstPayment BIT,
            IsDebitOrder BIT,
            BaseCommissionRate DECIMAL(5,4),
            ActivationMultiplier DECIMAL(5,2),
            DebitOrderMultiplier DECIMAL(5,2),
            FinalCommissionRate DECIMAL(5,4),
            MaxCommission DECIMAL(18,2),
            Commission DECIMAL(18,2)
        );
        
        -- Populate work table with payments for the cycle date
        INSERT INTO #PaymentCommission (
            PaymentID, UserID, ClientID, PaymentDate, PaymentAmount, 
            CommissionableAmount, CategoryID, IsFirstPayment, IsDebitOrder
        )
        SELECT 
            p.DB_ID,
            p.Ptp_Owner_User_ID,
            p.ClientID,
            p.[DateTime],
            p.Amount,
            p.[Commissionable Amount],
            pmc.CategoryID,
            -- First payment flag based on matter payment history
            CASE WHEN NOT EXISTS (
                SELECT 1 FROM [BI_Transformation].[dbo].[Fact_Pmt_Grad] prev
                WHERE prev.IDX = p.IDX
                AND prev.[DateTime] < p.[DateTime]
            ) THEN 1 ELSE 0 END AS IsFirstPayment,
            -- Debit order flag
            pmc.IsDebitOrder
        FROM [BI_Transformation].[dbo].[Fact_Pmt_Grad] p
        INNER JOIN [Incentives].[dbo].[Payment_Ownership] po ON p.DB_ID = po.PaymentID
        INNER JOIN [Incentives].[dbo].[PaymentMethod_Mappings] pmm ON po.PaymentMethod = pmm.PaymentMethod
        INNER JOIN [Incentives].[dbo].[PaymentMethod_Categories] pmc ON pmm.CategoryID = pmc.CategoryID
        WHERE CAST(p.[DateTime] AS DATE) = @CycleDate
        AND p.Ptp_Owner_User_ID IS NOT NULL;
        
        -- Apply commission rules using static Fact_Agent_Comm for base rates
        UPDATE pc
        SET 
            BaseCommissionRate = fac.[Agent Comm],
            ActivationMultiplier = 1.5, -- 50% increase for activation
            DebitOrderMultiplier = 1.5, -- 50% increase for debit orders
            MaxCommission = 2000.00,    -- Cap at R2000
            FinalCommissionRate = fac.[Agent Comm] * 
                CASE WHEN pc.IsFirstPayment = 1 THEN 1.5 ELSE 1 END *
                CASE WHEN pc.IsDebitOrder = 1 THEN 1.5 ELSE 1 END,
            Commission = CASE 
                WHEN (pc.CommissionableAmount * fac.[Agent Comm] * 
                     CASE WHEN pc.IsFirstPayment = 1 THEN 1.5 ELSE 1 END *
                     CASE WHEN pc.IsDebitOrder = 1 THEN 1.5 ELSE 1 END) > 2000.00
                THEN 2000.00
                ELSE (pc.CommissionableAmount * fac.[Agent Comm] * 
                     CASE WHEN pc.IsFirstPayment = 1 THEN 1.5 ELSE 1 END *
                     CASE WHEN pc.IsDebitOrder = 1 THEN 1.5 ELSE 1 END)
            END
        FROM #PaymentCommission pc
        CROSS APPLY (
            -- Get the applicable commission rate from Fact_Agent_Comm
            SELECT TOP 1 fac.[Agent Comm]
            FROM [BI_Static].[dbo].[Fact_Agent_Comm] fac
            WHERE fac.ClientID = pc.ClientID
            AND @CycleDate BETWEEN fac.FromDate AND fac.ToDate
            ORDER BY fac.FromDate DESC
        ) fac;
        
        -- Insert calculated results into Payment_Commission_Results table
        INSERT INTO [BI_Transformation].[dbo].[Payment_Commission_Results] (
            PaymentID, UserID, ClientID, PaymentDate, PaymentAmount,
            CommissionableAmount, BaseRate, IsFirstPayment, IsDebitOrder, 
            ActivationMultiplier, DebitOrderMultiplier, FinalRate, Commission, 
            CalculatedDate
        )
        SELECT 
            PaymentID, UserID, ClientID, PaymentDate, PaymentAmount,
            CommissionableAmount, BaseCommissionRate, IsFirstPayment, IsDebitOrder,
            ActivationMultiplier, DebitOrderMultiplier, FinalCommissionRate, Commission,
            GETDATE()
        FROM #PaymentCommission;
        
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK;
        
        -- Log error to error table
        INSERT INTO [Incentives].[dbo].[Payment_Ownership_ErrorLog]
        (
            ErrorMessage,
            ErrorLine,
            ErrorNumber,
            ErrorProcedure,
            ErrorSeverity,
            ErrorState
        )
        VALUES
        (
            ERROR_MESSAGE(),
            ERROR_LINE(),
            ERROR_NUMBER(),
            ERROR_PROCEDURE(),
            ERROR_SEVERITY(),
            ERROR_STATE()
        );
        
        THROW;
    END CATCH;
    
    -- Clean up
    IF OBJECT_ID('tempdb..#PaymentCommission') IS NOT NULL
        DROP TABLE #PaymentCommission;
END;
GO
