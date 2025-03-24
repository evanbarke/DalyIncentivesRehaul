CREATE TABLE [dbo].[PaymentMethod_Categories](
    [CategoryID] [int] IDENTITY(1,1) NOT NULL,
    [CategoryName] [varchar](50) NOT NULL,
    [IsDebitOrder] [bit] NOT NULL DEFAULT 0,
    [Priority] [int] NOT NULL,
    CONSTRAINT [PK_PaymentMethod_Categories] PRIMARY KEY ([CategoryID])
)
GO

CREATE TABLE [dbo].[PaymentMethod_Mappings](
    [PaymentMethod] [varchar](100) NOT NULL,
    [CategoryID] [int] NOT NULL,
    [IsActive] [bit] NOT NULL DEFAULT 1,
    [ModifiedDate] [datetime] NOT NULL DEFAULT GETDATE(),
    CONSTRAINT [PK_PaymentMethod_Mappings] PRIMARY KEY ([PaymentMethod])
)
GO

CREATE TABLE [dbo].[Payment_Rules](
    [RuleID] [int] IDENTITY(1,1) NOT NULL,
    [RuleName] [varchar](100) NOT NULL,
    [CategoryID] [int] NOT NULL,
    [MinAmount] [decimal](18,2) NULL,
    [MaxAmount] [decimal](18,2) NULL,
    [IsSettlement] [bit] NOT NULL DEFAULT 0,
    [RuleScore] [int] NOT NULL,
    [StartDate] [datetime] NOT NULL,
    [EndDate] [datetime] NULL,
    [IsActive] [bit] NOT NULL DEFAULT 1,
    CONSTRAINT [PK_Payment_Rules] PRIMARY KEY ([RuleID])
)
GO

CREATE TABLE [dbo].[Payment_Ownership](
    [OwnershipID] [int] IDENTITY(1,1) NOT NULL,
    [PaymentID] [int] NOT NULL,                    -- Fact_Pmt_Grad.DB_ID
    [MatterID] [int] NOT NULL,                     -- IDX
    [PTPID] [int] NOT NULL,                        -- Fact_PTP.ID
    [UserID] [int] NOT NULL,                       -- Owner
    [RuleID] [int] NOT NULL,                       -- Which rule applied
    [OwnershipDate] [datetime] NOT NULL DEFAULT GETDATE(),
    [PaymentAmount] [decimal](18,2) NOT NULL,
    [PaymentMethod] [varchar](100) NOT NULL,
    [IsSettlement] [bit] NOT NULL DEFAULT 0,
    [RuleScore] [int] NOT NULL,
    [ProcessVersion] [int] NOT NULL DEFAULT 1,      -- Increments when rules change
    [IsActive] [bit] NOT NULL DEFAULT 1,
    CONSTRAINT [PK_Payment_Ownership] PRIMARY KEY ([OwnershipID])
)
GO

-- First create error logging table
CREATE TABLE [Incentives].[dbo].[Payment_Ownership_ErrorLog](
    [ErrorLogID] [int] IDENTITY(1,1) NOT NULL,
    [ErrorDateTime] [datetime] NOT NULL DEFAULT GETDATE(),
    [PTPID] [int] NULL,
    [MatterID] [int] NULL,
    [PaymentMethod] [varchar](50) NULL,
    [ErrorMessage] [nvarchar](4000) NULL,
    [ErrorLine] [int] NULL,
    [ErrorNumber] [int] NULL,
    [ErrorProcedure] [nvarchar](128) NULL,
    [ErrorSeverity] [int] NULL,
    [ErrorState] [int] NULL,
    CONSTRAINT [PK_Payment_Ownership_ErrorLog] PRIMARY KEY CLUSTERED ([ErrorLogID] ASC)
)
GO


-- Initial category setup
INSERT INTO PaymentMethod_Categories (CategoryName, IsDebitOrder, Priority) VALUES
('DebiCheck', 1, 1),
('NAEDO/Bank Debit Order', 1, 2),
('Electronic Payment', 0, 3),
('Card Payment', 0, 4),
('Other', 0, 5);

-- Map payment methods to categories
INSERT INTO PaymentMethod_Mappings (PaymentMethod, CategoryID) VALUES
('DebiCheck Realtime Delayed', 1),
('DebiCheck Batched', 1),
('Bank Integrated Debit Order', 2),
('Debit Order', 2),
('Manual Debit Order', 2),
('Persal', 2),
('EFT', 3),
('MasterPass', 3),
('EasyPay', 3),
('Pay@', 3),
('Zapper', 3),
('OZOW', 3),
('Instant Link', 3),
('Direct Deposit', 3),
('Debit Card', 4),
('Credit Card', 4),
('Card', 4),
('Recurring card Payment', 4),
('RMS', 5),
('Eduloan', 5),
('Ziyabuya', 5);

-- Initial rules
INSERT INTO Payment_Rules (RuleName, CategoryID, MinAmount, MaxAmount, IsSettlement, RuleScore, StartDate) VALUES
('DebiCheck Settlement', 1, NULL, NULL, 1, 100, GETDATE()),
('NAEDO Settlement', 2, NULL, NULL, 1, 95, GETDATE()),
('Electronic Settlement', 3, NULL, NULL, 1, 90, GETDATE()),
('Card Settlement', 4, NULL, NULL, 1, 85, GETDATE()),
('DebiCheck Above R150', 1, 150, NULL, 0, 80, GETDATE()),
('NAEDO Above R150', 2, 150, NULL, 0, 75, GETDATE()),
('Electronic Above R150', 3, 150, NULL, 0, 70, GETDATE()),
('Card Above R150', 4, 150, NULL, 0, 65, GETDATE()),
('DebiCheck Below R150', 1, 0, 149.99, 0, 60, GETDATE()),
('NAEDO Below R150', 2, 0, 149.99, 0, 55, GETDATE()),
('Electronic Below R150', 3, 0, 149.99, 0, 50, GETDATE()),
('Card Below R150', 4, 0, 149.99, 0, 45, GETDATE()),
('Other Methods', 5, NULL, NULL, 0, 40, GETDATE());
