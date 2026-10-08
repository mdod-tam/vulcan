# Invoice payment corrections

A recorded payment is final in the portal. The payment date, method, references, the purchases on the
invoice, and its total cannot be edited after approval or payment. When an invoice turns out to be
wrong, fix it in accounting and record the correction in the portal as a note. Do not edit the database.

## What can still change in the portal

| Invoice state | Allowed |
|---|---|
| Awaiting approval | Approve, or withdraw with a reason |
| Approved, awaiting payment | Record the payment, or withdraw with a reason |
| Paid | Correction notes only |
| Withdrawn | Correction notes only |

Withdrawing an invoice keeps it and its number, marks it Withdrawn, and releases its purchases so they
can be added to a later invoice. To keep a purchase off the next invoice (for example, while a possible
fraud is reviewed), withdraw the invoice first, then put that purchase on hold from its voucher page.
A held purchase is never invoiced until staff release the hold.

## Correcting a paid invoice

1. Resolve the error in the accounting system first: a reversal, an adjusting entry, a replacement
   payment, or a recovery from the vendor. Get the accounting reference for it (journal entry,
   reversal, or replacement check or EFT number).
2. Keep the evidence where accounting keeps payment records: the bank or check record, the GAD
   correspondence, and the approval for the correction.
3. In the portal, open the invoice and use **Add a correction note**. Enter the accounting reference and
   a short note that says what was wrong and what was done, for example
   "Paid twice by EFT; second deposit reversed, JE-2026-114".
4. The note appears in the invoice's history with your name and the time. The original payment details
   stay as recorded, so the history shows both what was recorded and how it was corrected.

If the vendor should be paid for purchases that were never invoiced, no correction is needed: they
appear under **Not yet invoiced** and go on the next invoice. Use **Invoice now** to bill them sooner.

## Historical invoices

Invoices paid before payment details were required may show "Not recorded" for the payment method or
recorder. Leave them as they are. If the real values are known from accounting records, add them as a
correction note with the accounting reference.
