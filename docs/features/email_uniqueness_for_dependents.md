# Dependent Contact Information Handling

This document describes how MAT Vulcan stores and resolves contact information for dependents without violating unique email and phone constraints.

## High-Level Flow

1. A guardian or admin enters dependent contact information.
2. The controller decides the contact strategy for email and phone. On portal create and paper intake, that can come from checkboxes or direct strategy params. On portal edit, the form has no checkboxes — the app infers the strategy from what was submitted (blank contact, contact matching the guardian, or the dependent's own contact).
3. `Applications::GuardianDependentManagementService` applies those strategies before creating a new dependent, or before updating one when email or phone was submitted. If a contact field was not submitted, the service leaves that field alone.
4. `Applications::UserCreationService` creates or reuses the constituent record, depending on the entry point.
5. `GuardianRelationship` connects the guardian and dependent.
6. Mailers, notification builders, secure request resolution, and admin lookup endpoints use effective contact helpers or `dependent_email` fallback when choosing recipients.

## Main Entry Points

| Area | Path | Current behavior |
|------|------|------------------|
| Portal dependent creation and update | `app/controllers/constituent_portal/dependents_controller.rb` | On `create`, strategy comes from `use_guardian_email` / `use_guardian_phone` checkboxes; blank contact also uses guardian strategy. Portal-created dependents always use `skip_user_lookup: true`. On `update`, strategies run only when email or phone was submitted — a name-only PATCH leaves stored contact alone. Submitted contact that matches the guardian's email or phone also uses guardian strategy (generated primary contact plus real contact in `dependent_email` / `dependent_phone`). |
| Admin paper intake | `app/controllers/admin/paper_applications_controller.rb` | `create` permits direct strategy params and guardian-contact checkboxes, then passes normalized params to the paper application service. For an existing dependent, the service updates submitted contact fields directly from `dependent_email` and `dependent_phone` aliases instead of reapplying strategy params. |
| Strategy application | `app/services/applications/guardian_dependent_management_service.rb` | Applies email, phone, and address strategies when creating a dependent or when a portal update submits contact fields. When a strategy is `nil` for a field, that field is not rewritten. |
| User creation | `app/services/applications/user_creation_service.rb` | Creates constituent records and, unless `skip_user_lookup` is true, may reuse an existing user by primary email or phone. System email addresses are not used for lookup. |
| Model behavior | `app/models/concerns/user_profile.rb`, `app/models/concerns/user_guardianship.rb` | Encrypts and validates dependent contact fields, then resolves effective contact values through guardian relationships. |
| Mail delivery | `app/mailers/application_mailer.rb`, `app/services/notifications/parameter_normalization_service.rb` | Uses `effective_email` and `effective_communication_preference` when available. Letter delivery for dependents is addressed to `guardian_for_contact`. |
| Lookup and secure requests | `app/controllers/admin/paper_applications_controller.rb`, `app/models/concerns/user_email_search.rb`, `app/services/applications/secure_request_recipient_resolver.rb` | Admin recipient preference lookup checks primary email first, then `dependent_email`. User email search indexes both `email` and `dependent_email`; dependents without their own `dependent_email` can be found through linked guardian email tokens. Secure request defaults use the managing guardian when the dependent's effective email matches that guardian. |

## Key Concepts

| Concept | Meaning |
|---------|---------|
| Primary contact fields | `users.email` and `users.phone`. These remain unique and are still required by user creation. |
| Dependent contact fields | `users.dependent_email` and `users.dependent_phone`. Encrypted fields for the dependent's real contact. They are searchable but are not held to the same uniqueness rules as primary `email` and `phone`. |
| Guardian strategy | Stores guardian contact in the dependent contact field and assigns a generated unique primary contact value to avoid uniqueness conflicts. |
| Dependent strategy | Uses the dependent's submitted contact as both the primary contact and dependent contact field. If the submitted contact is blank, the strategy service falls back to guardian contact. |
| Managing guardian | The guardian responsible for a dependent application. See `docs/development/guardian_relationship_system.md`. |

> Important distinction: contact strategies are request-time params. The app does not currently persist `email_strategy` or `phone_strategy` columns on users or guardian relationships. There is also no flag to skip uniqueness validation — shared contact is handled by storing the real address in `dependent_email` / `dependent_phone` and generating unique primary values when needed.

## Current Behavior

### Email

- With `email_strategy: "guardian"`, the dependent gets a generated primary email like `dependent-{uuid}@system.matvulcan.local`, and `dependent_email` is set to the guardian's email when the guardian has one.
- With `email_strategy: "dependent"`, the submitted dependent email is normalized into both `email` and `dependent_email`.
- If `email_strategy` is omitted (`nil`), the service leaves email fields unchanged. This is how partial portal updates avoid rewriting contact.
- Invalid strategy values, or a blank email under the dependent strategy, fall back to guardian strategy.
- On portal `update`, a submitted blank email also uses guardian strategy and generates a new primary email. Omitted email (not in the request) is left alone.
- Portal `update` also uses guardian strategy when the submitted email matches the guardian's email (after normalization).
- `UserGuardianship#effective_email` returns `dependent_email` for dependents when present. If it is blank and a guardian relationship exists, it falls back to `guardian_for_contact.email`. Otherwise it returns the user's primary `email`.

### Phone

- With `phone_strategy: "guardian"`, the dependent gets a generated primary phone like `000-000-1234`, and `dependent_phone` is set to the guardian's phone.
- With `phone_strategy: "dependent"`, the submitted dependent phone is normalized into both `phone` and `dependent_phone`.
- If `phone_strategy` is omitted (`nil`), the service leaves phone fields unchanged.
- Invalid strategy values, or a blank phone under the dependent strategy, fall back to guardian strategy.
- On portal `update`, a submitted blank phone also uses guardian strategy and generates a new primary phone. Omitted phone (not in the request) is left alone.
- Portal `update` also uses guardian strategy when the submitted phone matches the guardian's phone (after normalization).
- `UserGuardianship#effective_phone` returns `dependent_phone` for dependents when present. If it is blank and a guardian relationship exists, it falls back to `guardian_for_contact.phone`. Otherwise it returns the user's primary `phone`.
- `UserGuardianship#effective_phone_type` returns the guardian's phone type when the dependent is using the guardian's phone, including when `dependent_phone` normalizes to the guardian's phone. Otherwise it returns the dependent user's `phone_type`.

### Communication Preference And Locale

- `effective_communication_preference` returns the guardian's communication preference for dependents with a contact guardian.
- `effective_locale` returns the guardian's locale only when a dependent's effective email is the guardian's email. Otherwise it returns the dependent user's locale.
- `ApplicationMailer#letter_recipient_for` sends printed letters for dependents to `guardian_for_contact` when one exists.

## Verified Test Coverage

| Test | Coverage |
|------|----------|
| `test/services/applications/dependent_email_handling_test.rb` | Paper application service behavior for guardian email, dependent email, and guardian phone type resolution. |
| `test/services/applications/guardian_dependent_management_service_test.rb` | Failure result handling for missing guardian information, invalid guardian IDs, and missing relationship type. |
| `test/controllers/admin/paper_applications_controller_test.rb` | Admin paper application creation for dependents with new or existing guardians, own email, guardian email, locale persistence, and recipient lookup by `dependent_email`. |
| `test/controllers/constituent_portal/dependents_controller_test.rb` | Portal dependent creation, guardian email fallback, validation failures, forced creation of a new dependent user, contact-sharing update, and partial-update contact preservation. |

## Related Docs

- `docs/development/guardian_relationship_system.md`
- `docs/development/paper_application_architecture.md`
- `docs/features/application_workflow_guide.md`
