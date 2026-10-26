# Vendor onboarding setup

This guide covers first-release configuration and acceptance checks. There is no retained production dataset to convert. Apply the current schema and start with the current encryption and document-access contracts.

## Configure before accepting vendors

1. Configure persistent Active Record Encryption keys on every web, worker, release, and operator process. Non-test runtime boot rejects missing or incomplete keys, and encrypted attributes reject plaintext storage. Follow the [key requirements](../security/pii_encryption.md#keys-and-encrypted-storage).
2. Apply all pending migrations before starting the matching application code. The [Procfile](../../Procfile) runs `bin/rails db:migrate` in Heroku's release phase. Complete [initial accounts and baseline seeds](setup_and_maintenance.md) before opening access.
3. Configure private [file storage](active_storage_s3_setup.md) and [attachment scanning](../security/attachment_scanning.md). W9s stay unavailable until their scan passes; reviewed files remain in the vendor's internal `w9_archive`. Authenticated W9 downloads use the dedicated document route. Generic Active Storage downloads refuse them.
4. Publish approved vendor terms as described below. Review the English and Spanish onboarding templates through the editor preview and designated test-send before enabling outbound delivery.

## Publish vendor terms

`config/vendor_terms.yml` is the blank repository-owned agreement template, initially `published: false` and `agreement: ''`. Populate approved agreement content, review the terms page, and explicitly set `published: true`. Publication and nonempty content are both required for acceptance, including forged POSTs. Never publish the test-only agreement.

W9 approval and program authorization are separate decisions. The seeded `vendor_notifications_w9_approved` templates explain this in both `en` and `es`; preserve that distinction when editing copy. Keep the supported `%<status_box_text>s` placeholder so the rendered status matches the vendor's remaining onboarding requirements. Invoice, payment, and W9 notices use the vendor's designated email.

## Verify with synthetic records

- Save a TIN through the vendor model and confirm the raw column contains ciphertext while audit metadata contains masked values. Blank profile/admin edits must preserve the TIN, and invoice PDFs must omit it. Inspect logs using synthetic values only.
- Approve a pending W9, replace it, and open the retained file associated with the original decision. Stale or repeated decisions must leave review/status/rejection counts and audit history unchanged. A delivery failure must leave the decision recorded and its delivery outcome visible.
- Check administrator access to current and retained W9s, vendor access to its own current or usable staged file, and denial for another vendor or a signed-out visitor. Generic blob and representation routes must refuse W9s; retired redirect and disk download routes must be absent. Upload references must not grant read access.
- Check Today/This Week/This Month/custom filters against Eastern `processed_at` boundaries. Pagination, CSV rows, counts, and totals must agree; invalid custom dates must refuse CSV export.
- Exercise pending vendor onboarding through upload, document review, separate authorization, voucher redemption and retry, invoicing/payment, shipment tracking, and constituent/guardian visibility. Use approved terms in the target environment.

Back up data, objects, and matching encryption/signing credentials once the environment holds retained records. Follow [backup and recovery](backup_and_recovery.md) for future recovery rehearsals.
