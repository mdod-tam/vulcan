# Voucher Security Controls

A voucher gives an approved applicant a policy-defined amount to spend with an eligible vendor.

Issuance checks the application.

Redemption checks the vendor, the applicant verification, the voucher state, and the amount.

## Issuing a voucher

[Vouchers::IssuanceService](../../app/services/vouchers/issuance_service.rb) is the only path that issues one. It checks the feature flag — a configuration switch — first. It then holds a database lock on the application while it evaluates eligibility and creates the voucher. Two approvals racing cannot both pass the "no existing voucher" test.

Eligibility requires voucher fulfillment, an approved application, approved required proofs and disability certification, and no existing voucher. Normal entry points are the approval transition through [IssueInitialVoucherJob](../../app/jobs/issue_initial_voucher_job.rb) and the admin assignment action.

[Voucher](../../app/models/voucher.rb) calculates the initial value from the constituent's disability flags and policy values. It generates a random 12-character code. The database also has a unique index on the code. Model validations keep the initial and remaining values non-negative and keep the remaining value no greater than the initial value.

## Redeeming a voucher

The [vendor portal controller](../../app/controllers/vendor_portal/vouchers_controller.rb) handles the screens. It passes redemption to [Vouchers::RedemptionService](../../app/services/vouchers/redemption_service.rb).

| Check | Owner |
| --- | --- |
| Voucher feature enabled | Redemption service |
| Approved vendor with an attached, approved W9 | [Users::Vendor#can_process_vouchers?](../../app/models/users/vendor.rb), called by the service |
| Applicant DOB (date of birth) matches and voucher ID is verified in the session | [VoucherVerificationService](../../app/services/voucher_verification_service.rb); the redemption service requires the session result |
| Positive amount, selected products, and submission ID | Redemption service |
| Active, unexpired voucher; amount within balance and at least the policy minimum | `Voucher#can_redeem?`, called by `redeem!` |
| Positive transaction amount within remaining value | [VoucherTransaction](../../app/models/voucher_transaction.rb) validation |

### Duplicate submissions

Each redemption form carries a `submission_id` the server mints when it renders the form. The redemption is stored with it under a unique index. `Voucher#redeem!` looks the ID up after taking the voucher row lock and before any spending check. A repeat with the same vendor, amount, and products returns the original redemption and records only a `voucher_redemption_replayed` event. There is no new row, balance change, or notice. A repeat with different details is refused as a conflict, and the vendor gets a fresh form. A request without a submission ID is refused ("Reload the redemption form and try again."). Amounts are parsed strictly by [MoneyInput](../../app/services/money_input.rb): dollars with optional comma grouping and at most two decimal places.

The vendor portal redeems through `Vouchers::RedemptionService`, which checks vendor eligibility and DOB verification in the session. `Voucher#redeem!` then locks the voucher and writes the purchase, product associations, and remaining balance in one database transaction.

Calling `Voucher#redeem!` directly bypasses the service's vendor eligibility and DOB verification checks. Application callers must use `Vouchers::RedemptionService`. Keep the spending writes together inside `Voucher#redeem!` under its row lock and transaction.

### Verification limits

DOB verification reads the submitted date with [DateInputNormalizer](../../app/services/date_input_normalizer.rb), month first. It compares the date with the application owner's date of birth and stores successful voucher IDs in `session[:verified_vouchers]`. The redemption service requires this session record before redemption.

Failed checks are counted per voucher and vendor in [VoucherVerificationThrottle](../../app/models/voucher_verification_throttle.rb), not in the session. Reloading the form or signing out therefore does not reset the count. Reaching the `voucher_verification_max_attempts` policy (default 3, allowed 1–100) within 30 minutes of the first failure locks that vendor out of that voucher for 30 minutes. Other vendors are unaffected. The lockout is checked before the date is compared, so a correct date during the lockout is refused. Input that cannot be read as a date, and an owner with no date of birth on file, use no attempt. A success clears the count. Every attempt is audited with its attempt number.

Vendor eligibility has one rule, `Users::Vendor#can_process_vouchers?` (approved vendor with an approved W9), in every environment. The vendor portal checks it before any request that carries a voucher code — lookup, DOB verification, redemption — looks the code up. An unapproved vendor therefore gets the same answer for real and unknown codes. The redemption service checks the rule again before writing.

## State, history, and messages

Vouchers have four states: `active`, `redeemed`, `expired`, and `cancelled`. Full redemption consumes the balance. Expiry is calculated from issue time and the policy validity period. The model checks elapsed expiry during redemption even if the status has not yet changed.

[CheckVoucherExpirationJob](../../app/jobs/check_voucher_expiration_job.rb) is the entry point for batch expiration processing. It warns each voucher once when it enters the expiring-soon window. It expires vouchers past their validity period. [Vouchers::ExpirationProcessorService](../../app/services/vouchers/expiration_processor_service.rb) is the only code that writes `expired` and the only sender of the expired notice, so a voucher is notified once when it expires. Writing the status elsewhere sends nothing. Admin cancellation runs through [Admin::VouchersController](../../app/controllers/admin/vouchers_controller.rb) and `Voucher#cancel!`.

Issuance owns `voucher_assigned`, redemption owns `voucher_redeemed`, and the admin controller owns `voucher_cancelled` and `voucher_updated`. Model callbacks record status changes. [VoucherAuditLogBuilder](../../app/services/vouchers/voucher_audit_log_builder.rb) assembles the displayed history.

Assignment, redemption, and expiration messages use [VoucherNotificationsMailer](../../app/mailers/voucher_notifications_mailer.rb).

## After a purchase: fulfillment and packages

A completed redemption is a purchase the vendor can fulfill. [VoucherTransactions::FulfillmentService](../../app/services/voucher_transactions/fulfillment_service.rb) is the only writer of its fulfillment mode (shipping or local pickup) and its packages (tracking number, optional ship date, and contents). It never changes the amount, vendor, status, or invoice.

| Check | Owner |
| --- | --- |
| The purchase belongs to the signed-in vendor, and a package belongs to that purchase | Vendor portal lookups through `current_user.voucher_transactions`, then `purchase.shipments` in the service |
| Only completed redemptions are fulfilled | `VoucherTransaction#fulfillable?`, checked under the purchase row lock |
| A form built from an older state is refused | The purchase's `fulfillment_version` (mode and new packages) and each package's `lock_version` — a counter that detects corrections built from older data |
| A tracking number is recorded once per purchase | Unique index on the normalized number per purchase |
| A vendor suspended after a sale can still record tracking for that sale (deliberate: the customer still needs it, and the vendor saw these details at redemption) | Vendor portal lookups are scoped to the vendor's own purchases; voucher processing approval is not required |
| Only the applicant of an unmanaged application, or its managing guardian, sees purchases | `VoucherTransaction.purchases_visible_to`, built on `Application.accessible_by` |

Recording or correcting a package sends no email, letter, or notification. The applicant — or the managing guardian — sees packages on the application page and dashboard. Staff see them, with the fulfillment history, on the admin voucher page. Package records contain vendor-reported tracking information. The interface displays "tracking available" and labels dates "Vendor-reported ship date." Switching to local pickup preserves recorded packages as history.

## Related tests

The voucher row lock serializes redemptions of the same voucher. A waiting redemption reads the balance left by the preceding transaction. [Concurrency tests](../../test/models/voucher_redemption_concurrency_test.rb) cover overspending and repeated submission IDs with separate database connections.

- [Voucher model tests](../../test/models/voucher_test.rb) and [redemption tests](../../test/models/voucher_redemption_test.rb)
- [Issuance job tests](../../test/jobs/issue_initial_voucher_job_test.rb)
- [Vendor portal tests](../../test/controllers/vendor_portal/vouchers_controller_test.rb)
- [Redemption integration tests](../../test/integration/voucher_redemption_integration_test.rb)
