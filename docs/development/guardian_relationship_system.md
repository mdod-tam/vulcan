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

```ruby
dependent = User.create!(
  email:            'dependent-abc123@system.local', # system-generated unique
  phone:            '000-000-1234',
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
dependent.guardian_for_contact  # returns primary guardian for contact purposes

# Note: has_own_contact_info? and uses_guardian_contact_info? methods
# are mentioned in docs but not currently implemented in the codebase
```

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
2. Uses `UserServiceIntegration` concern for consistent user creation
3. Flow: `create_user_with_service(params, is_managing_adult: false)` → handles password, disability validation
4. Then: `create_guardian_relationship_with_service(guardian, dependent, relationship_type)` → creates GuardianRelationship
5. Application creation happens separately when dependent applies

### 4.2 · Admin Paper Application

Handled by `Applications::PaperApplicationService` with `GuardianDependentManagementService`:

```ruby
Current.paper_context = true
begin
  # PaperApplicationService.process_guardian_dependent calls:
  # GuardianDependentManagementService.process_guardian_scenario
  # - Sets up guardian (existing or new)
  # - Creates dependent with contact strategies
  # - Creates GuardianRelationship
  # - Creates Application with managing_guardian_id set
ensure
  Current.paper_context = nil
end
```

Supports both new & existing guardians. Uses contact strategies (email_strategy, phone_strategy, address_strategy) to handle dependent contact information.

---

## 5 · Database Constraints

* Unique composite index on `(guardian_id, dependent_id)` (implemented in GuardianRelationship model)
* FK constraints on both IDs with proper inverse_of associations
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
create(:constituent, :with_guardians)            # Dependent with guardians
```

*Always*:

1. Build `GuardianRelationship` before dependent apps
2. Set `Current.paper_context = true` in paper-flow tests
3. Assert both `user_id` and `managing_guardian_id`
4. Use appropriate factory traits for different contact scenarios

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