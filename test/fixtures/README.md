# Test Data and Fixtures

This directory contains YAML sample data and files for upload tests. New scenarios generally use [FactoryBot factories](../factories); the suite also loads shared seed data. See [testing and debugging](../../docs/development/testing_and_debugging_guide.md) for test commands and helpers, or the [project README](../../README.md) for local setup.

## How data gets loaded

[test_helper.rb](../test_helper.rb) cleans the test database and runs [db/seeds.rb](../../db/seeds.rb) once at suite startup. There is no blanket `fixtures :all` declaration.

The seed creates users through factories, then reads [products.yml](products.yml), [applications.yml](applications.yml), and [invoices.yml](invoices.yml). Application and invoice loaders translate named user/vendor references to IDs. Editing `users.yml` or another YAML file does not automatically change the seeded users or load that file into the suite.

Browser tests also have `SeedLookupHelpers` in [ApplicationSystemTestCase](../application_system_test_case.rb). Calls such as `users(:admin)` use that helper's lookup/creation rules; they are not standard Rails fixture lookups. Its application lookups can fall back to another record, so create a specific factory record when a test depends on an exact state.

## Choosing data for a test

- Use a factory to make the relevant user role, associations, and application state explicit. Start with [user factories](../factories/users.rb) and [application factories](../factories/applications.rb).
- Update shared YAML only when the shared seed data itself needs to change. Follow the existing loader and reference names.
- Treat seeded records as setup conveniences. Some application seeds bypass validations while loading historical states; they do not prove that normal intake can create the same state.
- Let the shared test base manage transactions and cleanup. Browser tests use a different cleaning strategy; do not add a second one to an individual test.

## Upload files

[files/](files) holds PDFs, images, and deliberately invalid samples. Use real files for upload, download, rendering, or file-validation behavior.

The application factory's `:with_income_proof`, `:with_residency_proof`, `:with_id_proof`, and `:with_medical_certification` traits attach real fixture PDFs. For a test that depends on a particular file format or invalid content, choose the file explicitly.

File fixtures are separate from YAML records: an approved proof status alone does not attach a file. Check both the attachment and the status when setting up proof-review scenarios.
