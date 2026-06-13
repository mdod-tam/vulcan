# Guardian Relationship System

How MAT Vulcan records guardian/dependent relationships and connects them to dependent applications.

---

## 1 · High-Level Flow

```text
Portal dependent management
  ConstituentPortal::DependentsController
  -> UserServiceIntegration
  -> Applications::UserCreationService
  -> Applications::GuardianDependentManagementService
  -> GuardianRelationship

Portal dependent application
  ConstituentPortal::ApplicationsController
  -> ApplicationForm
  -> Applications::ApplicationCreator
  -> Application(user: dependent, managing_guardian: current_user)

Admin paper application
  Admin::PaperApplicationsController
  -> Applications::PaperApplicationService
  -> Applications::GuardianDependentManagementService / Applications::UserCreationService
  -> GuardianRelationship
  -> Application(user: dependent, managing_guardian: guardian)
```

A `GuardianRelationship` records that one user can act for another user. An `Application` records the actual applicant in `user_id`; dependent applications also store the responsible guardian in `managing_guardian_id`.

---

## 2 · Main Entry Points

### 2.1 Constituent Portal Dependents

`ConstituentPortal::DependentsController` is mounted with `resources :dependents`. The controller currently implements `new`, `create`, `show`, `edit`, `update`, and `destroy`.

| Action | Current behavior |
|--------|------------------|
| `new` / `create` | Creates a new dependent user with `skip_user_lookup: true`, requires at least one disability, applies contact strategies via `Applications::GuardianDependentManagementService` (blank dependent contact or `use_guardian_email` / `use_guardian_phone` checkboxes fall back to guardian strategy), then creates `GuardianRelationship`. |
| `show` / `edit` | Loads only dependents returned by `User.editable_by_guardian(current_user)` and displays the current user's relationship plus recent profile-change events. |
| `update` | Updates permitted dependent profile fields. When `email` or `phone` is explicitly submitted, the controller applies the same contact strategies as `create`; omitted contact keys are left unchanged so partial PATCHes do not rewrite existing contact. Submitted contact matching the guardian's email/phone uses guardian strategy (generated primary contact plus real contact in `dependent_email` / `dependent_phone`). `Current.user` is set to the guardian, so `UserProfile` logs `profile_updated_by_guardian` for profile-field changes. |
| `destroy` | Destroys the current guardian's `GuardianRelationship`. It does not destroy the dependent user. |

### 2.2 Constituent Portal Applications

`ConstituentPortal::ApplicationsController` builds dependent applications through `ApplicationForm` and persists them with `Applications::ApplicationCreator`.

For dependent applications:

1. The form carries the dependent `user_id`.
2. `ApplicationForm#for_dependent?` checks that `user_id` differs from `current_user.id`.
3. `ApplicationForm#validate_guardian_relationship` verifies a `GuardianRelationship` for `current_user` and the dependent.
4. `Applications::ApplicationCreator` sets the application user to the dependent and `managing_guardian_id` to the guardian.

### 2.3 Admin Paper Applications

`Admin::PaperApplicationsController` normalizes paper form params and calls `Applications::PaperApplicationService`.

`Applications::PaperApplicationService` handles:

- existing self applicants
- new self applicants
- existing guardian plus existing dependent
- existing guardian plus new dependent
- new guardian plus new dependent

For dependent paper applications, the service creates or verifies the `GuardianRelationship`, sets `@guardian_user_for_app`, and saves the paper `Application` with `managing_guardian`.

Paper create/update paths wrap the main work in `Current.paper_context = true`, and nested proof/application operations also set it where needed.

### 2.4 Admin Relationship Views

Admin user and application pages display guardian/dependent relationships through `Admin::UsersController`, `Application#managing_guardian`, and the `GuardianRelationship` associations.

Only relationship removal is currently routed for `Admin::GuardianRelationshipsController`:

```text
DELETE /admin/guardian_relationships/:id -> admin/guardian_relationships#destroy
```

The controller has `new` and `create` methods, but `config/routes.rb` does not currently route them.

---

## 3 · Data Model

| Table | Key columns | Current behavior |
|-------|-------------|------------------|
| `guardian_relationships` | `guardian_id`, `dependent_id`, `relationship_type` | Requires both users and a relationship type. Unique index on `[guardian_id, dependent_id]`. |
| `applications` | `user_id`, `managing_guardian_id` | `user_id` is the applicant. `managing_guardian_id` is nullable and present for dependent applications. |
| `users` | `dependent_email`, `dependent_phone` | Encrypted optional contact fields for dependents. Primary `email` and `phone` remain unique. |

Associations live in `app/models/concerns/user_guardianship.rb`:

```ruby
has_many :guardian_relationships_as_guardian,
         class_name: 'GuardianRelationship',
         foreign_key: 'guardian_id',
         dependent: :destroy,
         inverse_of: :guardian_user
has_many :dependents, through: :guardian_relationships_as_guardian, source: :dependent_user

has_many :guardian_relationships_as_dependent,
         class_name: 'GuardianRelationship',
         foreign_key: 'dependent_id',
         dependent: :destroy,
         inverse_of: :dependent_user
has_many :guardians, through: :guardian_relationships_as_dependent, source: :guardian_user

has_many :managed_applications,
         class_name: 'Application',
         foreign_key: 'managing_guardian_id',
         inverse_of: :managing_guardian,
         dependent: :nullify
```

`Application#ensure_managing_guardian_set` is a safety callback. If an application is assigned to a dependent with an existing relationship and no `managing_guardian_id`, it sets `managing_guardian_id` from an existing `GuardianRelationship`.

---

## 4 · Contact Handling

Dependent contact handling separates the unique login/contact columns from effective recipient information.

| Field or parameter | Current behavior |
|--------------------|------------------|
| `users.email` | Primary email. Deterministically encrypted and unique. |
| `users.phone` | Primary phone. Deterministically encrypted and unique when present. |
| `users.dependent_email` | Optional encrypted dependent contact email. Used by `effective_email` before guardian fallback. |
| `users.dependent_phone` | Optional encrypted dependent contact phone. Used by `effective_phone` before guardian fallback. |
| `email_strategy` / `phone_strategy` / `address_strategy` | Runtime params used by portal and paper flows. They are not persisted strategy columns. |

Guardian-contact sharing uses dependent fields plus generated primary values when needed:

```ruby
dependent = User.create!(
  email: 'dependent-abc123@system.matvulcan.local',
  phone: '000-000-1234',
  dependent_email: 'guardian@example.com',
  dependent_phone: '555-0002'
)
```

There is no validation bypass flag for shared contact. `User` always validates primary `email` and `phone` uniqueness; guardian sharing is handled by `Applications::GuardianDependentManagementService` contact strategies, not by skipping uniqueness checks.

Contact helper methods live in `UserGuardianship`:

| Method | Current behavior |
|--------|------------------|
| `effective_email` | Uses `dependent_email` for dependents when present, then falls back to `guardian_for_contact.email`; otherwise uses `email`. |
| `effective_phone` | Uses `dependent_phone` for dependents when present, then falls back to `guardian_for_contact.phone`; otherwise uses `phone`. |
| `effective_phone_type` | Uses the guardian phone type when the effective phone matches the guardian phone; otherwise uses the dependent phone type. |
| `effective_communication_preference` | Uses the guardian preference for dependents with a contact guardian. |
| `effective_locale` | Uses the guardian locale when a dependent's effective email is the guardian email; otherwise uses the user's locale. |
| `guardian_for_contact` | Returns the first loaded or queryable guardian relationship's guardian user. |

`has_own_contact_info?` and `uses_guardian_contact_info?` are not implemented.

See also [email uniqueness for dependents](../features/email_uniqueness_for_dependents.md).

---

## 5 · Key Methods and Scopes

| Model | Method or scope | Current behavior |
|-------|-----------------|------------------|
| `User` | `guardian?`, `dependent?` | Checks whether relationship associations exist. |
| `User` | `with_dependents`, `with_guardians` | Finds users with guardian/dependent relationships. |
| `User` | `editable_by_guardian(guardian)`, `accessible_by_guardian(guardian)` | Returns dependents for a guardian; `accessible_by_guardian` aliases `editable_by_guardian`. |
| `User` | `editable_by_guardian?`, `accessible_by_guardian?`, `viewable_by_guardian?` | Checks whether the supplied guardian is related to this dependent. |
| `User` | `dependent_applications` | Returns applications for this user's dependents. |
| `User` | `relationship_types_for_dependent(user)` | Returns relationship type strings for a dependent. |
| `Application` | `for_dependent?` | True when `managing_guardian_id` is present. |
| `Application` | `guardian_relationship_type` | Looks up the relationship type for `managing_guardian_id` and `user_id`. |
| `Application` | `managed_by(guardian)` | Applications whose `managing_guardian_id` is the guardian. |
| `Application` | `for_dependents_of(guardian)` | Applications for any dependent related to the guardian. |
| `Application` | `related_to_guardian(guardian)` | Broad viewing scope: managed applications plus applications for related dependents. |
| `Application` | `editable_by(user)`, `accessible_by(user)` | Strict ownership scope: self applications with no guardian, or applications managed by the user. |
| `Application` | `editable_by?`, `accessible_by?`, `viewable_by?` | Instance-level versions of the strict ownership check. |

Important distinction: `related_to_guardian` is broader than edit access and is documented in the model as view-only.

---

## 6 · Testing Notes

Factory patterns:

```ruby
create(:guardian_relationship)
create(:guardian_relationship, :legal_guardian)
create(:guardian_relationship, :caretaker)

create(:constituent, :with_dependents)
create(:constituent, :with_guardian)
```

Use `GuardianRelationship` before creating dependent applications unless the service under test is responsible for creating the relationship.

For paper-flow tests, `Applications::PaperApplicationService` sets `Current.paper_context` itself. Tests that call lower-level proof, model, or service paths directly should set `Current.paper_context` or use the paper context helpers as the surrounding tests do.

Useful coverage:

- `test/controllers/constituent_portal/dependents_controller_test.rb`
- `test/controllers/constituent_portal/applications_controller_test.rb`
- `test/services/applications/guardian_dependent_management_service_test.rb`
- `test/services/applications/dependent_email_handling_test.rb`
- `test/system/admin_guardian_management_test.rb`
- `test/services/applications/paper_application_service_test.rb`

Related docs:

- [Paper application architecture](paper_application_architecture.md)
- [Application workflow guide](../features/application_workflow_guide.md)
- [Email uniqueness for dependents](../features/email_uniqueness_for_dependents.md)
