# Payment Ownership and Commission System

## Overview

The Payment Ownership and Commission System is an automated solution that:

1. Assigns ownership of payments to agents based on their Promise-to-Pay (PTP) interactions
2. Calculates agent commissions based on configurable business rules
3. Provides full audit history of ownership changes and commission calculations

The system uses a rule-based approach that considers payment methods, payment amounts, and timing to determine ownership, along with multipliers for specific scenarios when calculating commissions.

## System Components

### Database Objects

#### Tables

**Core Tables:**
- `Incentives.dbo.PaymentMethod_Categories` - Defines payment method categories and their priorities
- `Incentives.dbo.PaymentMethod_Mappings` - Maps specific payment methods to categories
- `Incentives.dbo.Payment_Rules` - Defines rules for ownership assignment with scores
- `Incentives.dbo.Payment_Ownership` - Stores the ownership assignments
- `Incentives.dbo.Payment_Ownership_History` - Maintains audit history of all ownership changes
- `Incentives.dbo.Matter_FixedArrangement_Status` - Tracks matters with fixed arrangements
- `Incentives.dbo.Payment_Ownership_ErrorLog` - Records errors and diagnostic information

**Commission Tables:**
- `Incentives.dbo.Commission_Rules` - Defines commission calculation rules
- `BI_Transformation.dbo.Payment_Commission_Results` - Stores commission calculation results

#### Stored Procedures

- `BI_Transformation.dbo.SP_Assign_Payment_Ownership` - Assigns ownership based on business rules
- `BI_Transformation.dbo.SP_Calculate_Payment_Commission` - Calculates commissions for owned payments

#### Triggers

- `BI_Transformation.dbo.TR_Payment_Ownership` - Trigger on Fact_PTP that initiates ownership assignment

### Scheduled Jobs

- **Incentives_Payment_Commission_Results** - Runs daily at 07:30 to calculate commissions

## Business Rules

### Payment Ownership Rules

1. **Fixed Arrangement Requirement**
   - Payments are only eligible for ownership if the matter is in a fixed arrangement status or was in one within the last 14 days

2. **Payment Method Priority**
   - DebiCheck (highest priority)
   - NAEDO/Bank Debit Order
   - Electronic Payment
   - Card Payment
   - Other (lowest priority)

3. **Amount Criteria**
   - Payment must be at least 80% of promised amount
   - Higher amounts generally receive higher priority

4. **Special Rules**
   - Immediate Credit: Electronic payments (like OZOW) made on the same day as PTP receive priority
   - Payment Increase: Payments exceeding previous payments by 20% AND R200+ can override lower priority methods

5. **Settlement vs. Non-Settlement**
   - Settlement payments have their own rule set and generally higher priority

### Commission Calculation Rules

1. **Base Rates**
   - Base rates pulled from `BI_Static.dbo.Fact_Agent_Comm`
   - Client-specific rates supported

2. **Multipliers**
   - Activation (first payment): 50% increase
   - Debit Order: 50% increase
   - Combined: First payment by debit order receives 100% increase

3. **Capping**
   - Maximum commission: R2,000 per payment

## Process Flow

### Payment Ownership Assignment

1. A new PTP is created in Fact_PTP
2. Trigger fires and calls SP_Assign_Payment_Ownership
3. SP checks for eligible payments within 30 days of PTP date
4. Qualifying payments are ranked by rules
5. Ownership is assigned to the highest-ranking agent
6. Fact_Pmt_Grad.Ptp_Owner_User_ID is updated
7. Full audit history is maintained

### Commission Calculation

1. Daily job runs SP_Calculate_Payment_Commission
2. Pulls previous day's payments with ownership
3. Applies commission rules from Fact_Agent_Comm
4. Applies multipliers for first payments and debit orders
5. Caps commissions at R2,000
6. Stores results in Payment_Commission_Results

## Monitoring and Troubleshooting

### Error Logging

All errors are captured in `Incentives.dbo.Payment_Ownership_ErrorLog` with:
- Error messages and details
- Procedure and line where error occurred
- Timestamp
- Related PTPID or MatterID when available

### Diagnostic Tools

Several diagnostic tools are included for troubleshooting:

1. **SP_Debug_Payment_Ownership**
   - Detailed diagnostic procedure that traces all steps
   - Shows which conditions pass/fail for a given PTP

2. **Payment_Ownership_Test.sql**
   - Test script that creates test data and cleans up afterward
   - Validates end-to-end functionality

3. **Deep_Diagnostic.sql**
   - Quick diagnostic to identify specific match failures

## Development Notes

- Current deployment uses `zzz_Fact_Pmt_Grad_EvanTest` instead of `Fact_Pmt_Grad` for testing in production
- All tables include proper indexes for performance
- Fully qualified database references ensure correct cross-database operations

## Technical Details

### Collation Handling

The system includes `COLLATE DATABASE_DEFAULT` in key comparisons to prevent collation conflicts between databases.

### Transaction Safety

All procedures use:
- Proper transaction handling
- XACT_ABORT ON for automatic rollback on errors
- Error logging and cleanup to prevent orphaned records

## Future Enhancements

Potential enhancements for future versions:

1. Dashboard for commission tracking and ownership disputes
2. Manual override functionality with approval workflow
3. Extended rules for more complex scenarios
4. Historical reprocessing tool for rule changes

## Contact Information

For technical support or questions about this system, please contact:

**Evan Benn**  
Project Lead  
Email: [evan.benn@dalysoftware.com](mailto:evan.benn@dalysoftware.com)
