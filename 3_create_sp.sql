USE BI_Transformation
GO

-- First, make sure we have the history table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Payment_Ownership_History' AND schema_id = SCHEMA_ID('Incentives.dbo'))
BEGIN
    CREATE TABLE [Incentives].[dbo].[Payment_Ownership_History](
        [HistoryID] [int] IDENTITY(1,1) NOT NULL,
        [PaymentOwnershipID] [int] NOT NULL,
        [Action] [varchar](50) NOT NULL,
        [PreviousUserID] [int] NULL,
        [NewUserID] [int] NOT NULL,
        [PreviousRuleScore] [int] NULL,
        [NewRuleScore] [int] NOT NULL,
        [Reason] [varchar](255) NOT NULL,
        [ModifiedBy] [int] NOT NULL,
        [ModifiedDate] [datetime] NOT NULL DEFAULT GETDATE(),
        CONSTRAINT [PK_Payment_Ownership_History] PRIMARY KEY CLUSTERED ([HistoryID] ASC)
    )
END
GO

-- Drop procedure if it exists
IF EXISTS (SELECT * FROM sys.procedures WHERE name = 'SP_Assign_Payment_Ownership')
    DROP PROCEDURE [dbo].[SP_Assign_Payment_Ownership]
GO

CREATE PROCEDURE [dbo].[SP_Assign_Payment_Ownership]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON; -- Important: Ensures transaction is automatically rolled back on error
    
    -- Check if temp table exists first
    IF NOT EXISTS (SELECT * FROM tempdb.sys.tables WHERE name like '#TempNewPTPs%')
    BEGIN
        -- Log error because temp table doesn't exist
        INSERT INTO [Incentives].[dbo].[Payment_Ownership_ErrorLog]
        (ErrorMessage, ErrorProcedure)
        VALUES
        ('Missing #TempNewPTPs table - trigger may have failed', 'SP_Assign_Payment_Ownership');
        RETURN;
    END
    
    -- Only start transaction if we actually have PTP data
    IF EXISTS (SELECT 1 FROM #TempNewPTPs)
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- Table variable to store priority credit flags for later use
            DECLARE @PriorityCredits TABLE (
                PaymentID INT PRIMARY KEY,
                HasPriorityCredit BIT NOT NULL
            );

            -- Get payments that match the new PTPs with fixed arrangement check
            WITH FixedArrangement AS (
                -- Get matters in fixed arrangement within last 14 days
                SELECT DISTINCT MatterID 
                FROM Incentives.dbo.Matter_FixedArrangement_Status
                WHERE IsActive = 1
                OR (EndDate IS NOT NULL AND EndDate >= DATEADD(DAY, -14, GETDATE()))
            ),
            PreviousPayments AS (
                -- Get previous payment amounts for comparison
                SELECT 
                    p.IDX AS MatterID,
                    MAX(p.Amount) AS PreviousAmount,
                    MAX(p.[DateTime]) AS PreviousDate
                FROM Fact_Pmt_Grad p
                INNER JOIN #TempNewPTPs t ON p.IDX = t.MatterID
                WHERE p.[DateTime] < t.PTPDateTime
                GROUP BY p.IDX
            ),
            MatchingPayments AS (
                SELECT 
                    p.DB_ID AS PaymentID,
                    p.IDX AS MatterID,
                    t.PTPID,
                    t.UserID,
                    p.[DateTime] AS PaymentDate,
                    p.Amount AS PaymentAmount,
                    t.PaymentMethod,
                    t.IsSettlement,
                    t.PTPDateTime,
                    mc.CategoryID,
                    mc.Priority,
                    mc.ImmediateCreditFlag,
                    r.RuleID,
                    r.RuleScore,
                    pp.PreviousAmount,
                    CASE 
                        -- Handle Ozow/immediate credit payments made same day as PTP
                        WHEN mc.ImmediateCreditFlag = 1 AND CAST(p.[DateTime] AS DATE) = CAST(t.PTPDateTime AS DATE) THEN 1
                        -- Check for sufficient payment increase over previous amount
                        WHEN pp.PreviousAmount IS NOT NULL 
                             AND p.Amount >= (pp.PreviousAmount * 1.2) 
                             AND (p.Amount - pp.PreviousAmount) >= 200 THEN 1
                        ELSE 0
                    END AS HasPriorityCredit
                FROM #TempNewPTPs t
                -- Check fixed arrangement status
                INNER JOIN FixedArrangement fa ON t.MatterID = fa.MatterID
                -- Find payments within 30 days after PTP date that match amount criteria
                INNER JOIN Fact_Pmt_Grad p ON 
                    p.IDX = t.MatterID
                    AND p.[DateTime] >= t.PTPDateTime
                    AND p.[DateTime] <= DATEADD(DAY, 30, t.PTPDateTime)
                    AND (
                        p.Amount >= t.FirstPayment * 0.8 
                        OR p.Amount >= t.MonthlyAmount * 0.8
                    )
                LEFT JOIN PreviousPayments pp ON p.IDX = pp.MatterID
                INNER JOIN Incentives.dbo.PaymentMethod_Mappings pm ON pm.PaymentMethod = t.PaymentMethod
                INNER JOIN Incentives.dbo.PaymentMethod_Categories mc ON mc.CategoryID = pm.CategoryID
                INNER JOIN Incentives.dbo.Payment_Rules r ON 
                    r.CategoryID = mc.CategoryID
                    AND r.IsActive = 1
                    AND (r.MinAmount IS NULL OR p.Amount >= r.MinAmount)
                    AND (r.MaxAmount IS NULL OR p.Amount <= r.MaxAmount)
                    AND r.IsSettlement = t.IsSettlement
            ),
            RankedPayments AS (
                SELECT *,
                    ROW_NUMBER() OVER (
                        PARTITION BY PaymentID 
                        ORDER BY 
                            HasPriorityCredit DESC, -- Give immediate credit priority
                            RuleScore DESC,         -- Then rule score
                            Priority ASC,           -- Then category priority
                            PaymentDate ASC         -- Then earliest PTP
                    ) as rn
                FROM MatchingPayments
            )
            
            -- Save priority credit info for later use
            INSERT INTO @PriorityCredits (PaymentID, HasPriorityCredit)
            SELECT PaymentID, HasPriorityCredit
            FROM RankedPayments
            WHERE rn = 1;

            -- Declare table for merge output
            DECLARE @MergeOutput TABLE (
                OwnershipID int,
                Action varchar(10),
                PreviousUserID int NULL,
                NewUserID int NOT NULL,
                PreviousRuleScore int NULL,
                NewRuleScore int NOT NULL
            );

            -- Merge to update/insert ownership records
            MERGE Incentives.dbo.Payment_Ownership AS target
            USING (
                SELECT 
                    PaymentID,
                    MatterID,
                    PTPID,
                    UserID,
                    RuleID,
                    PaymentDate as OwnershipDate,
                    PaymentAmount,
                    PaymentMethod,
                    IsSettlement,
                    RuleScore,
                    HasPriorityCredit
                FROM RankedPayments 
                WHERE rn = 1
            ) AS source
            ON target.PaymentID = source.PaymentID
            WHEN MATCHED AND (
                target.UserID != source.UserID OR
                target.RuleScore < source.RuleScore OR
                (source.HasPriorityCredit = 1 AND target.RuleScore <= source.RuleScore) OR
                target.RuleID != source.RuleID
            ) THEN
                UPDATE SET 
                    UserID = source.UserID,
                    RuleID = source.RuleID,
                    RuleScore = source.RuleScore,
                    ProcessVersion = target.ProcessVersion + 1,
                    OwnershipDate = source.OwnershipDate
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    PaymentID, MatterID, PTPID, UserID, RuleID,
                    OwnershipDate, PaymentAmount, PaymentMethod,
                    IsSettlement, RuleScore, ProcessVersion, IsActive
                )
                VALUES (
                    source.PaymentID, source.MatterID, source.PTPID, 
                    source.UserID, source.RuleID, source.OwnershipDate,
                    source.PaymentAmount, source.PaymentMethod,
                    source.IsSettlement, source.RuleScore, 1, 1
                )
            OUTPUT 
                inserted.OwnershipID,
                CASE
                    WHEN deleted.PaymentID IS NULL THEN 'INSERT'
                    ELSE 'UPDATE'
                END AS Action,
                deleted.UserID as PreviousUserID,
                inserted.UserID as NewUserID,
                deleted.RuleScore as PreviousRuleScore,
                inserted.RuleScore as NewRuleScore
            INTO @MergeOutput;

            -- Insert history records
            INSERT INTO Incentives.dbo.Payment_Ownership_History (
                PaymentOwnershipID,
                Action,
                PreviousUserID,
                NewUserID,
                PreviousRuleScore,
                NewRuleScore,
                Reason,
                ModifiedBy,
                ModifiedDate
            )
            SELECT 
                m.OwnershipID,
                m.Action,
                m.PreviousUserID,
                m.NewUserID,
                m.PreviousRuleScore,
                m.NewRuleScore,
                CASE 
                    WHEN m.Action = 'INSERT' THEN 'Initial ownership assignment'
                    WHEN EXISTS (
                        SELECT 1 FROM @PriorityCredits pc 
                        WHERE pc.HasPriorityCredit = 1 AND pc.PaymentID = 
                            (SELECT PaymentID FROM [Incentives].[dbo].[Payment_Ownership] WHERE OwnershipID = m.OwnershipID)
                    ) THEN 'Priority credit (immediate or payment increase)'
                    WHEN m.PreviousRuleScore < m.NewRuleScore THEN 'Higher priority payment method'
                    ELSE 'Ownership reassigned'
                END,
                m.NewUserID,
                GETDATE()
            FROM @MergeOutput m;

            -- Calculate commissionable amount and update Fact_Pmt_Grad
            UPDATE g
            SET 
                g.Ptp_Owner_User_ID = po.UserID,
                g.[Commissionable Amount] = CASE
                    -- Cap to amount due if payment > due and PTP > 30 days ago
                    WHEN g.Amount > dm.[Current Balance] 
                        AND DATEDIFF(DAY, po.OwnershipDate, g.[DateTime]) > 30
                        THEN dm.[Current Balance]
                    ELSE g.Amount
                END
            FROM Fact_Pmt_Grad g
            INNER JOIN Incentives.dbo.Payment_Ownership po ON po.PaymentID = g.DB_ID
            INNER JOIN DIM_MATTER dm ON g.IDX = dm.IDX
            WHERE EXISTS (
                SELECT 1 FROM #TempNewPTPs t 
                WHERE t.MatterID = g.IDX
            );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;
                
            -- Log the error
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
            
            -- Re-throw the error for caller awareness
            THROW;
        END CATCH;
    END
END;
GO
