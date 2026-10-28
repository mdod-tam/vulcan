# CSV exports

[`CsvExport`](../../app/services/csv_export.rb) is the serialization boundary for the admin invoice, voucher and equipment bid downloads, vendor transaction downloads, and the duplicate-reconciliation report file. Callers supply typed rows in their existing order and scope. The writer applies [`SpreadsheetCell`](../../app/services/spreadsheet_cell.rb) to every header and text cell; callers do not escape individual fields.

Text starting with a formula operator (`=`, `+`, `-`, `@`, or the fullwidth equivalents) receives a leading apostrophe, including when whitespace or control characters precede the operator. Leading tabs, carriage returns and line feeds receive the same treatment. Ruby's CSV writer keeps commas, quotes and embedded newlines inside their original cells. Numeric values, including negative integers and decimals, and nil cells pass through without a text prefix. A negative value supplied as a string is treated as text.

This targets the initial exported CSV. Spreadsheet applications can remove escaping when saving and reopening files, and downstream imports may treat the added apostrophe as data. There is no universal format safe for every spreadsheet and consumer; see [OWASP's CSV injection guidance](https://owasp.org/www-community/attacks/CSV_Injection). These downloads retain CSV output rather than making a stronger save/reopen guarantee.

Successful HTTP exports create an `export_generated` audit event with the requesting actor, fixed export type and data-row count. The event excludes exported contents, submitted filters and selected record IDs. Each completed generation records its own event, including an empty export. The command-line duplicate report retains its existing read-only behavior and writes through the same serialization policy to the caller's file.

This boundary does not decide which personal fields each role needs. Existing authorization, columns, filters, grouping and pagination remain the export owners' responsibility. The [report privacy review](../future_work/mat_vulcan_todos.md#advanced-reporting) is still open.
