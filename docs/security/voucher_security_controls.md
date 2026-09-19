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

`Voucher#redeem!` writes the transaction, product associations, and new balance in a database transaction. It is deliberately not the whole check: vendor eligibility and DOB verification live in the service above it, so a call that reaches the model directly spends voucher value without either.

### Verification limits

DOB verification compares the application owner's date of birth and stores successful voucher IDs in `session[:verified_vouchers]`. Mismatch counts are session-based, with a policy threshold defaulting to three. The controller resets the counter on the verification page; this is not a persistent lockout.

The redemption service simplifies vendor authorization in the test environment. Passing a portal test alone does not establish that the production W9 requirement works; cover `can_process_vouchers?` directly when changing eligibility.

## State, history, and messages

Vouchers have four states: `active`, `redeemed`, `expired`, and `cancelled`. Full redemption consumes the balance; expiry is calculated from issue time and the policy validity period. The model checks elapsed expiry during redemption even if status has not yet changed.

[CheckVoucherExpirationJob](../../app/jobs/check_voucher_expiration_job.rb) is the entry point for batch expiration processing. Admin cancellation runs through [Admin::VouchersController](../../app/controllers/admin/vouchers_controller.rb) and `Voucher#cancel!`.

Issuance owns `voucher_assigned`, redemption owns `voucher_redeemed`, and the admin controller owns `voucher_cancelled` / `voucher_updated`. Model callbacks record status changes. [VoucherAuditLogBuilder](../../app/services/vouchers/voucher_audit_log_builder.rb) assembles the displayed history.

Assignment, redemption, and expiration messages use [VoucherNotificationsMailer](../../app/mailers/voucher_notifications_mailer.rb) directly; they do not create `NotificationService` records.

## Where this flow goes wrong

Eligibility, balance changes, history, and messages are bundled into the owning methods on purpose; splitting any of them out is how a voucher gets issued twice, or spent without a matching transaction row. The failure modes worth having a test for are duplicate issuance, an ineligible vendor, a redemption with no DOB verification in session, an expired voucher, an amount over the remaining balance, and one under the policy minimum.

A transaction boundary is not by itself a concurrency argument — two redemptions of the same voucher can interleave inside one — so any change to balance handling needs that checked directly rather than inferred.

Examples:

- [Voucher model tests](../../test/models/voucher_test.rb) and [redemption tests](../../test/models/voucher_redemption_test.rb)
- [Issuance job tests](../../test/jobs/issue_initial_voucher_job_test.rb)
- [Vendor portal tests](../../test/controllers/vendor_portal/vouchers_controller_test.rb)
- [Redemption integration tests](../../test/integration/voucher_redemption_integration_test.rb)
