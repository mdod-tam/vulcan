# User Management Features

---

## 1 · Signup Deduplication

### 1.1 · Phone Uniqueness (Hard)

* **Encrypted phone storage** with deterministic encryption for uniqueness.
* Custom uniqueness validation via `phone_must_be_unique` method.
* Normalisation before validation:

```ruby
before_validation :format_phone_number
before_save :format_phone_number, if: :phone_changed?

def format_phone_number
  return if phone.blank?
  
  digits = phone.gsub(/\D/, '')
  digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
  self.phone = if digits.length == 10
                 digits.gsub(/(\d{3})(\d{3})(\d{4})/, '\1-\2-\3')
               else
                 phone
               end
end

def phone_must_be_unique
  return if phone.blank?
  
  existing = User.exists_with_phone?(phone, excluding_id: id)
  errors.add(:phone, 'has already been taken') if existing
end
```

### 1.2 · Name + DOB Flag (Soft)

```ruby
# RegistrationsController#create
@user.needs_duplicate_review = true if potential_duplicate_found?(@user)
```

```ruby
def potential_duplicate_found?(user)
  # Normalize inputs for comparison
  normalized_first_name = user.first_name&.strip&.downcase
  normalized_last_name = user.last_name&.strip&.downcase

  # Check only if all parts are present
  return false unless normalized_first_name.present? && normalized_last_name.present? && user.date_of_birth.present?

  # Use exists? with array syntax for encrypted fields
  User.exists?(['lower(first_name) = ? AND lower(last_name) = ? AND date_of_birth = ?', 
               normalized_first_name, normalized_last_name, user.date_of_birth])
end
```

**Note**: The `needs_duplicate_review` field is implemented as an `attr_accessor` since it's not a database column but a runtime flag used during registration.

*Flag is invisible to the end user; admins review later.*

### 1.3 · Admin "Needs Review" Badge

**Current Implementation**: The duplicate review system exists in the registration flow, but the admin UI badge is not yet implemented. The `needs_duplicate_review` flag is set during user creation but there's no current admin interface for reviewing flagged duplicates.

**Planned Implementation**:
```erb
<% if user.needs_duplicate_review? %>
  <span class="rounded-full bg-yellow-100 text-yellow-800 px-2.5 py-0.5 text-xs">Needs Review</span>
<% end %>
```

---

## 2 · Test Selectors (`data-testid`)

| Element | Pattern | Example |
|---------|---------|---------|
| Form | `{feature}-form` | `sign-in-form` |
| Input | `{name}-input` | `email-input` |
| Button | `{action}-button` | `submit-button` |
| Modal | `{feature}-modal` | `confirmation-modal` |
| List / item | `{thing}-list` / `{thing}-item` | `users-list` |

**Current Implementation**: The codebase uses `data-testid` attributes in some areas but not consistently throughout. Current usage includes:

```erb
<!-- Flash messages -->
<div role="alert" class="flash-message flash-<%= type %> mb-4" data-testid="flash-<%= type %>">
  <%= message %>
</div>

<!-- Form controllers -->
<div data-controller="dependent-selector income-validation accessibility-announcer">
  <!-- Various form elements with stimulus targets -->
</div>
```

**Recommended Pattern** (not yet fully implemented):
```erb
<form data-testid="sign-in-form">
  <input type="email"    data-testid="email-input">
  <input type="password" data-testid="password-input">
  <button data-testid="sign-in-button">Sign In</button>
</form>
```

Test usage:
```ruby
within '[data-testid="sign-in-form"]' do
  fill_in  '[data-testid="email-input"]',    with: 'user@example.com'
  fill_in  '[data-testid="password-input"]', with: 'password'
  click_button '[data-testid="sign-in-button"]'
end
```

Priority areas: **Auth forms → Nav → Profile → Application forms → Admin panels**.

---

## 3 · Factory Patterns

```ruby
# Basic user creation
create(:user)  # Creates base User
create(:constituent)  # Creates Users::Constituent (most common)
create(:administrator)  # Creates Users::Administrator

# Guardian / dependent relationships
guardian = create(:constituent, :with_dependents)  # Creates guardian with dependents
guardian = create(:constituent, :with_dependent)   # Creates guardian with single dependent
dependent = create(:constituent, :with_guardian)   # Creates dependent with guardian

# Specific guardian traits
guardian = create(:constituent, :as_guardian)       # Guardian with default dependent
guardian = create(:constituent, :as_legal_guardian) # Legal guardian relationship

# Explicit relationship creation
create(:guardian_relationship,
       guardian_user: guardian,
       dependent_user: dependent,
       relationship_type: 'Parent')  # or 'Legal Guardian', 'Caretaker'

# Application factory patterns
create(:application, :for_dependent, guardian: guardian)  # Application for dependent
create(:application, :for_dependent, 
       dependent_attrs: { first_name: 'John', last_name: 'Doe' })

# Avoid uniqueness clashes (uses sequences automatically)
create(:constituent, email: generate(:email), phone: generate(:phone))
```

---

## 4 · Model Test Examples

```ruby
# Phone uniqueness validation (with encryption)
test 'phone uniqueness' do
  create(:constituent, phone: '555-123-4567')
  dup = build(:constituent, phone: '555-123-4567')
  assert_not dup.valid?
  assert_includes dup.errors[:phone], 'has already been taken'
end

# Phone formatting callback
test 'phone formatted' do
  u = create(:constituent, phone: '(555) 123-4567')
  assert_equal '555-123-4567', u.phone
end

# Date of birth parsing
test 'date of birth parsing' do
  u = build(:constituent, date_of_birth: '1990-01-01')
  assert u.date_of_birth.is_a?(Date)
  assert_equal Date.parse('1990-01-01'), u.date_of_birth
end

# Duplicate detection
test 'duplicate detection flags user for review' do
  create(:constituent, first_name: 'John', last_name: 'Doe', date_of_birth: '1990-01-01')
  
  # Simulate registration controller logic
  new_user = build(:constituent, first_name: 'John', last_name: 'Doe', date_of_birth: '1990-01-01')
  new_user.needs_duplicate_review = true if potential_duplicate_found?(new_user)
  
  assert new_user.needs_duplicate_review
end

# Guardian relationship validation
test 'guardian can have multiple dependents' do
  guardian = create(:constituent, :with_dependents, dependents_count: 3)
  assert_equal 3, guardian.dependents.count
  guardian.dependents.each do |dependent|
    assert_equal 'Parent', dependent.guardian_relationships.first.relationship_type
  end
end
```

---

## 5 · Current State & Future Work

### 5.1 · Implemented Features ✅

* **Phone uniqueness**: Hard validation with encryption support
* **Phone formatting**: Automatic normalization to XXX-XXX-XXXX format
* **Duplicate detection**: Name + DOB soft flagging during registration
* **Guardian/dependent relationships**: Full factory support and relationship management
* **STI user types**: `Users::Constituent`, `Users::Administrator`, `Users::Vendor`, etc.
* **Encrypted PII**: Email, phone, address, SSN, date of birth encryption

### 5.2 · Partially Implemented ⚠️

* **Admin duplicate review UI**: Detection exists, but admin review interface not implemented
* **Test selectors**: Some `data-testid` usage exists but not systematically applied

### 5.3 · Future Work 🔄

* **Duplicate review UI**: Complete admin interface for reviewing and merging flagged accounts
* **Enhanced deduplication**: Fuzzy address matching, ML-based scoring
* **Bulk scanning**: Legacy data cleanup and duplicate resolution
* **`data-testid` expansion**: Systematic application across all forms and UI components
* **Accessibility improvements**: Enhanced screen reader support and keyboard navigation
* **Performance optimization**: Caching for encrypted field queries

### 5.4 · Key Architecture Notes

* **Encryption**: All PII fields use Rails 7+ deterministic encryption
* **User model**: Base `User` class with STI for different user types
* **Validation**: Custom validation methods handle encrypted field uniqueness
* **Factory patterns**: Comprehensive factory support for complex relationship testing