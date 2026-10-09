# Voucher Security Controls

A voucher gives an approved applicant a policy-defined amount to spend with an eligible vendor.

Issuance checks the application.

Redemption checks the vendor, the applicant verification, the voucher state, and the amount.

## Issuing a voucher

`Application#assign_voucher!` ([VoucherManagement](../../app/models/concerns/voucher_management.rb)) is the only path that issues one. It checks the feature flag, then holds a lock on the application while it evaluates eligibility and creates the voucher, so two approvals racing cannot both pass the "no existing voucher" test.

Eligibility requires voucher fulfillment, an approved application, approved required proofs and disability certification, and no existing voucher. Normal entry points are the approval transition through [IssueInitialVoucherJob](../../app/jobs/issue_initial_voucher_job.rb) and the admin assignment action.

[Voucher](../../app/models/voucher.rb) calculates initial value from the constituent's disability flags and policy values. It generates a random 12-character code; the database also has a unique code index. Model validations keep initial and remaining values non-negative and remaining value no greater than the initial value.

## Redeeming a voucher

The [vendor portal controller](../../app/controllers/vendor_portal/vouchers_controller.rb) handles the screens and passes redemption to [Vouchers::RedemptionService](../../app/services/vouchers/redemption_service.rb).

| Check | Owner |
| --- | --- |
| Voucher feature enabled | Redemption service |
| Approved vendor with an attached, approved W9 | [Users::Vendor#can_process_vouchers?](../../app/models/users/vendor.rb), called by the service in production |
| Applicant DOB matches and voucher ID is verified in the session | [VoucherVerificationService](../../app/services/voucher_verification_service.rb); the redemption service requires the session result |
| Active voucher, positive amount within remaining value, and selected products | Redemption service |
| Active, unexpired voucher; amount within balance and at least the policy minimum | `Voucher#can_redeem?`, called by `redeem!` |
| Positive transaction amount within remaining value | [VoucherTransaction](../../app/models/voucher_transaction.rb) validation |

### Duplicate submissions

Each redemption form carries a `submission_id` the server mints when it renders the form; the redemption is stored with it under a unique index. `Voucher#redeem!` looks it up after taking the voucher row lock and before any spending check. A repeat with the same vendor, amount, and products returns the original redemption and records only a `voucher_redemption_replayed` event: no new row, balance change, or notice. A repeat with different details is refused as a conflict and the vendor gets a fresh form. A request without a submission ID is refused ("Reload the redemption form and try again."). Amounts are parsed strictly by [MoneyInput](../../app/services/money_input.rb): dollars with optional comma grouping and at most two decimal places.

`Voucher#redeem!` writes the transaction, product associations, and new balance in a database transaction. It is deliberately not the whole check: vendor eligibility and DOB verification live in the service above it, so a call that reaches the model directly spends voucher value without either.

### Verification limits

DOB verification reads the submitted date with [DateInputNormalizer](../../app/services/date_input_normalizer.rb), month first, compares it with the application owner's date of birth, and stores successful voucher IDs in `session[:verified_vouchers]`.

Failed checks are counted per voucher and vendor in [VoucherVerificationThrottle](../../app/models/voucher_verification_throttle.rb), not in the session, so reloading the form or signing out does not reset them. Reaching the `voucher_verification_max_attempts` policy (default 3, allowed 1–100) within 30 minutes of the first failure locks that vendor out of that voucher for 30 minutes; other vendors are unaffected. The lockout is checked before the date is compared, so a correct date during it is refused. Input that cannot be read as a date, and an owner with no date of birth on file, use no attempt. A success clears the count. Every attempt is audited with its attempt number.

Vendor eligibility has one rule, `Users::Vendor#can_process_vouchers?` (approved vendor with an approved W9), in every environment. The vendor portal checks it before any request that carries a voucher code (lookup, DOB verification, redemption) looks the code up, so an unapproved vendor gets the same answer for real and unknown codes, and the redemption service checks it again before writing.

## State, history, and messages

Vouchers have four states: `active`, `redeemed`, `expired`, and `cancelled`. Full redemption consumes the balance; expiry is calculated from issue time and the policy validity period. The model checks elapsed expiry during redemption even if status has not yet changed.

[CheckVoucherExpirationJob](../../app/jobs/check_voucher_expiration_job.rb) is the entry point for batch expiration processing. It warns each voucher once when it enters the expiring-soon window and expires vouchers past their validity period; the expired notice comes from the `Voucher` status callback, so every path to `expired` sends it once. Admin cancellation runs through [Admin::VouchersController](../../app/controllers/admin/vouchers_controller.rb) and `Voucher#cancel!`.

Issuance owns `voucher_assigned`, redemption owns `voucher_redeemed`, and the admin controller owns `voucher_cancelled` / `voucher_updated`. Model callbacks record status changes. [VoucherAuditLogBuilder](../../app/services/vouchers/voucher_audit_log_builder.rb) assembles the displayed history.

Assignment, redemption, and expiration messages use [VoucherNotificationsMailer](../../app/mailers/voucher_notifications_mailer.rb) directly; they do not create `NotificationService` records.

## After a purchase: fulfillment and packages

A completed redemption is a purchase the vendor can fulfill. [VoucherTransactions::FulfillmentService](../../app/services/voucher_transactions/fulfillment_service.rb) is the only writer of its fulfillment mode (shipping or local pickup) and its packages (tracking number, optional ship date and contents). It never changes the amount, vendor, status, or invoice.

| Check | Owner |
| --- | --- |
| The purchase belongs to the signed-in vendor; a package belongs to that purchase | Vendor portal lookups through `current_user.voucher_transactions`, then `purchase.shipments` in the service |
| Only completed redemptions are fulfilled | `VoucherTransaction#fulfillable?`, checked under the purchase row lock |
| A form built from an older state is refused | The purchase's `fulfillment_version` (mode and new packages) and each package's `lock_version` (corrections) |
| A tracking number is recorded once per purchase | Unique index on the normalized number per purchase |
| A vendor suspended after a sale can still record tracking for that sale (deliberate: the customer still needs it, and the vendor saw these details at redemption) | Vendor portal lookups are scoped to the vendor's own purchases; voucher processing approval is not required |
| Only the applicant of an unmanaged application, or its managing guardian, sees purchases | `VoucherTransaction.purchases_visible_to`, built on `Application.accessible_by` |

Recording or correcting a package sends no email, letter, or notification. The applicant (or the managing guardian) sees packages on the application page and dashboard, and staff see them, with the fulfillment history, on the admin voucher page. A recorded package means only that the vendor reported tracking: the copy says "tracking available" and labels any date as the vendor-reported ship date. It is not evidence of dispatch, delivery, or acceptance, which can bear on payment. Switching to local pickup keeps recorded packages as history.

## Where this flow goes wrong

Eligibility, balance changes, history, and messages are bundled into the owning methods on purpose; splitting any of them out is how a voucher gets issued twice, or spent without a matching transaction row. The failure modes worth having a test for are duplicate issuance, an ineligible vendor, a redemption with no DOB verification in session, a repeated or altered submission, an expired voucher, an amount over the remaining balance, and one under the policy minimum.

A transaction boundary is not by itself a concurrency argument — two redemptions of the same voucher can interleave inside one — so any change to balance handling needs that checked directly rather than inferred.

Examples:

- [Voucher model tests](../../test/models/voucher_test.rb) and [redemption tests](../../test/models/voucher_redemption_test.rb)
- [Issuance job tests](../../test/jobs/issue_initial_voucher_job_test.rb)
- [Vendor portal tests](../../test/controllers/vendor_portal/vouchers_controller_test.rb)
- [Redemption integration tests](../../test/integration/voucher_redemption_integration_test.rb)
