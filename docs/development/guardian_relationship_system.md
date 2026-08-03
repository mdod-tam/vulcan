# Guardian Relationship System

Explicit `GuardianRelationship` records replace the old boolean flags, allowing each guardian to manage many dependents and vice-versa while preserving data integrity.

---

## 1 · Data Model

| Table | Key Columns | Notes |
|-------|-------------|-------|
| **guardian_relationships** | `guardian_id`, `dependent_id`, `relationship_type` | Unique index on `[guardian_id, dependent_id]`. |
| **applications** | `user_id`, `managing_guardian_id` | `user_id` = applicant; `managing_guardian_id` set only for dependents. |
| **users** (associations) | see below | |

```ruby
# Implemented in UserGuardianship concern (app/models/concerns/user_guardianship.rb)
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

---

## 2 · Dependent Contact Strategy

| Field | Purpose |
|-------|---------|
| `dependent_email` | Encrypted, optional e-mail for dependent |
| `dependent_phone` | Encrypted, optional phone |

**Own contact info**

```ruby
dependent = User.create!(
  email:            'child@example.com',
  phone:            '555-0001',
  dependent_email:  'child@example.com',
  dependent_phone:  '555-0001'
)
```

**Shared contact info**

Guardian-contact sharing snapshots guardian contact into dependent fields plus
system-generated primary email and `000-` phone values when needed.

```ruby
dependent = User.create!(
  email:            'dependent-abc123@system.matvulcan.local', # system-generated unique
  phone:            '000-000-0042',
  dependent_email:  'guardian@example.com',
  dependent_phone:  '555-0002'
)
```

Helper methods (implemented in `UserGuardianship` concern):

```ruby
dependent.effective_email  # prefers dependent_email, falls back to guardian's email
dependent.effective_phone  # prefers dependent_phone, falls back to guardian's phone
dependent.effective_phone_type  # handles phone type logic for dependents
dependent.effective_communication_preference  # uses guardian's preference if dependent
dependent.effective_locale  # see below
dependent.effective_message_locale  # see below
dependent.guardian_for_contact  # returns primary guardian for contact purposes
```

**Locale resolution.** `effective_locale` follows the contact path rather than the record: a dependent whose `effective_email` is the guardian's email is reached *through* the guardian, so the guardian's `locale` is the one that matters. A dependent with their own `dependent_email` keeps their own `locale`. Getting this backwards writes messages in a language the actual reader does not use.

`effective_message_locale` narrows that to something `I18n` will accept, returning `nil` when the user has no locale set or carries a value the app no longer ships. Stored locales are **not** validated against `I18n.available_locales`, so any caller passing one to `I18n.t` or `I18n.with_locale` must go through this method and supply its own fallback — an unsupported value otherwise raises `I18n::InvalidLocale` rather than rendering a message. `ApplicationForm#message_locale` composes it: the submitted locale (allowlisted the same way) first, then the applicant's, then the actor's, then `I18n.default_locale`.

For a **persisted** application the form takes its applicant from `application.user` — the owner the actor was already authorized to open — never from a submitted `user_id`. The edit form posts no such field, so deriving it from params made every update resolve to the acting adult and rendered refusals in the guardian's language on a dependent's draft.

These effective-contact helpers are for communication, display, and notification routing. They are not login identifiers. Public portal auth and recovery require an email-backed account (`real_email?` via `User.find_by_login_identifier`); phone is an alternate identifier only when the same user also has `real_phone?`.

*Avoids uniqueness violations and supports real-world family setups.*

---

## 3 · Key Methods & Scopes

| Model | Method | Purpose |
|-------|--------|---------|
| **User** | `guardian?`, `dependent?` | Quick role checks (implemented in UserGuardianship) |
|  | `dependent_applications` | All apps for dependents (implemented in UserGuardianship) |
|  | `relationship_types_for_dependent(user)` | Returns relationship strings (implemented in UserGuardianship) |
|  | `effective_email`, `effective_phone` | Contact info with guardian fallback |
|  | `guardian_for_contact` | Primary guardian for contact purposes |
| **Application** | `for_dependent?` | Returns true if managing_guardian_id present |
|  | `guardian_relationship_type` | Returns relationship_type from GuardianRelationship |
|  | `ensure_managing_guardian_set` | Callback for safety (before_save and before_create) |

```ruby
# Application scopes (implemented in app/models/application.rb)
scope :managed_by, lambda { |guardian_user|
  where(managing_guardian_id: guardian_user.id)
}

scope :for_dependents_of, lambda { |guardian_user|
  if guardian_user
    joins('INNER JOIN guardian_relationships ON applications.user_id = guardian_relationships.dependent_id')
      .where(guardian_relationships: { guardian_id: guardian_user.id })
  else
    none
  end
}

scope :related_to_guardian, lambda { |guardian_user|
  managed_by(guardian_user).or(for_dependents_of(guardian_user))
}

# User scopes (implemented in UserGuardianship concern)
scope :with_dependents, -> { joins(:guardian_relationships_as_guardian).distinct }
scope :with_guardians, -> { joins(:guardian_relationships_as_dependent).distinct }
```

---

## 4 · User Flows

### 4.1 · Web-Created Dependent (Constituent Portal)

1. Guardian uses `ConstituentPortal::DependentsController#create`
2. Applies dependent contact strategies, then checks `DuplicateDetectionService` with context `:portal_new_dependent`
3. Exact contact collisions block before persistence; soft name+DOB/address matches continue to new dependent creation
4. Before writing, locks the guardian plus every candidate needed by a soft-match review case in one ascending-ID `User.lock_for_merge_integrity!` call
5. Requalifies the locked guardian as an active constituent and re-derives guardian contact snapshots from that locked row
6. Uses `UserServiceIntegration` for `create_user_with_service(params, is_managing_adult: false, skip_user_lookup: true, require_disability_validation: true)` — which handles password generation, requires the disability validation, and always creates a new dependent rather than reusing a lookup hit — and then `create_guardian_relationship_with_service(guardian, dependent, relationship_type)`
7. The whole review bundle commits or rolls back together: the dependent `User`, the `GuardianRelationship`, and — for a soft match — the `DuplicateReviewCase` with source `:portal_dependent`, its `DuplicateReviewCaseCandidate` rows, the subject's `needs_duplicate_review` flag, and the `duplicate_review_case_opened` audit event. No compensating delete is used; a failure at any step leaves nothing behind
8. A participant deleted between duplicate detection and the lock fails closed with the ordinary retry response rather than a server error
9. Application creation happens separately when the dependent applies

**The `:portal_dependent` review case opened in step 7 does not gate that later application.** It is staff review work, not a submission blocker. What gates is an open case with source `:registration_soft_match` whose **subject is the applicant** — so a dependent who registered their own account and was soft-matched cannot have an application finally submitted for them until staff resolve it, whether the guardian or the dependent presses the button. The acting guardian's own open case never gates a dependent's application, and a dependent named only as a *candidate* on someone else's case is never gated for being matched. Draft creation, editing, autosave, and draft saves stay available throughout. See [User Management Features §3.2](user_management_features.md#32-name-and-dob-review-flag).

Because the gate follows the applicant rather than the actor, the refusal copy is owner-neutral: a guardian reading it is not the account under review.

### 4.2 · Admin Paper Application

Handled by `Applications::PaperApplicationService` with `GuardianDependentManagementService`:

```ruby
Current.paper_context = true
begin
  # PaperApplicationService.process_guardian_dependent calls:
  # GuardianDependentManagementService.process_guardian_scenario
  # - Sets up guardian (existing or new)
  # - Creates or reuses dependent with contact strategies
  # - Creates GuardianRelationship
  # - Creates Application with managing_guardian_id set
ensure
  Current.paper_context = nil
end
```

Supports new guardians, existing guardians, new dependents, and existing dependents selected with `dependent_id`. `PaperApplicationService` owns application creation and eligibility checks; `GuardianDependentManagementService` owns dependent/guardian setup, duplicate detection for new paper guardians/dependents, duplicate-review case creation with source `:paper_intake`, and request-time contact strategy snapshots (`email_strategy`, `phone_strategy`, `address_strategy`).

Existing dependent reuse should preserve the current relationship when possible, set `managing_guardian_id` explicitly on the new application, and still respect waiting-period or `blocking_new_submission` checks from the paper applicant lookup.

---

## 5 · Database Constraints

* Unique composite index on `(guardian_id, dependent_id)`
* FK constraints on both IDs with proper inverse-of associations
* Guardian and dependent equality is rejected by `GuardianRelationship#guardian_and_dependent_must_be_different`; there is no database `CHECK` constraint for that invariant
* `managing_guardian_id` nullable in applications table
* Proper dependent: :destroy and dependent: :nullify for data integrity

## 6 · Service Integration

### UserServiceIntegration Concern

Controllers use `UserServiceIntegration` concern for consistent user and relationship creation:

```ruby
# Used in ConstituentPortal::DependentsController and Admin::GuardianRelationshipsController
create_user_with_service(user_params, is_managing_adult: false)
create_guardian_relationship_with_service(guardian, dependent, relationship_type)
```

### GuardianDependentManagementService

Handles complex guardian/dependent scenarios in paper applications:

```ruby
# Contact strategies determine how dependent contact info is handled
service = GuardianDependentManagementService.new(params)
service.process_guardian_scenario(guardian_id, new_guardian_attrs, applicant_data, relationship_type)
```

---

## 7 · Testing Patterns

```ruby
# Factory patterns (test/factories/guardian_relationships.rb)
create(:guardian_relationship)                    # Basic relationship
create(:guardian_relationship, :legal_guardian)   # Specific relationship type
create(:guardian_relationship, :dependent_shares_contact)  # Shared contact info

# User factory traits
create(:constituent, :with_dependents)           # Guardian with dependents
create(:constituent, :with_guardian)             # Dependent with a guardian
```

`User.with_guardians` is a model scope for querying dependent users with guardians; it is not a FactoryBot trait.

*Always*:

1. Build `GuardianRelationship` before dependent apps
2. Set `Current.paper_context = true` in paper-flow tests
3. Assert both `user_id` and `managing_guardian_id`
4. Use appropriate factory traits for different contact scenarios
5. Cover existing dependent reuse, waiting-period blocking, and explicit managing guardian assignment

Example:

```ruby
test 'dependent app sets guardian' do
  service = PaperApplicationService.new(params:, admin: @admin)
  assert_difference ['GuardianRelationship.count', 'Application.count'] do
    assert service.create
  end
  app = service.application
  assert app.for_dependent?
  assert_equal service.guardian_user_for_app.id, app.managing_guardian_id
end
```
