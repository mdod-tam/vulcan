# Dependent Contact Information Handling

This document outlines how the system handles dependent contact information (email and phone) to maintain database integrity and avoid uniqueness constraint violations.

## Context

To support cases where dependents share contact information with their guardians, the system must accommodate non-unique emails and phone numbers without violating database constraints. The architecture is designed to clearly distinguish between a dependent's own contact information and shared guardian information.

## Architecture

The system uses dedicated contact fields for dependents to provide a flexible and robust solution.

**Approach**: Dependents have separate `dependent_email` and `dependent_phone` fields. This allows them to either have their own unique contact information or share their guardian's contact information without causing database conflicts.

## Implementation Details

### 1. Database Schema

The `users` table includes dedicated contact fields for dependents to avoid uniqueness conflicts:

- `dependent_email` (string): An optional, indexed field for the dependent's own email. If blank, communications default to the guardian's email.
- `dependent_phone` (string): An optional, indexed field for the dependent's own phone number.

**Key Design Points:**
- Avoids uniqueness constraint violations on the primary `email` and `phone` columns.
- Provides a clear separation between a primary user's contact info and a dependent's.
- Ensures database integrity and query performance with indexes.
- Allows for flexible contact information handling.

### 2. Model Logic

The `User` model includes logic to manage dependent-specific contact information through the `UserProfile` and `UserGuardianship` concerns:

- **Encryption**: The `dependent_email` and `dependent_phone` fields are encrypted using `encrypts` (implemented in `UserProfile` concern).
- **Validation**: The model validates the format of `dependent_email` and `dependent_phone` (implemented in `UserProfile` concern).
- **Helper Methods** (implemented in `UserGuardianship` concern):
  - `effective_email`: Returns the dependent's own email if present, otherwise falls back to the guardian's email via `guardian_for_contact`.
  - `effective_phone`: Returns the dependent's own phone if present, otherwise falls back to the guardian's phone via `guardian_for_contact`.
  - `effective_phone_type`: Handles phone type logic for dependents.
  - `effective_communication_preference`: Uses guardian's preference if user is a dependent.
  - `guardian_for_contact`: Returns the primary guardian for contact purposes.

**Note**: The `has_own_contact_info?` and `uses_guardian_contact_info?` methods mentioned in earlier documentation are not currently implemented in the codebase.

The implementation provides a clear and secure way to handle different contact scenarios for dependents.

### 3. Paper Application Service

The paper application service (via `GuardianDependentManagementService`) uses contact strategy parameters (`email_strategy`, `phone_strategy`, `address_strategy`) to determine how to handle a dependent's contact information. This approach avoids complex checkbox logic and validation bypasses.

- **Strategy-Based Logic**: The service checks the strategy parameters in `apply_contact_strategies` method:
  - If the strategy is `'guardian'`, the dependent is assigned the guardian's contact information, and a system-generated unique primary email/phone is created to satisfy database constraints (e.g., `dependent-{uuid}@system.matvulcan.local`).
  - If the strategy is `'dependent'`, the service uses the provided dependent-specific contact information.
  - If the strategy is not specified, it defaults to guardian strategy with fallback logic.
- **Address Strategy**: Also handles address information copying from guardian to dependent.
- **Maintainability**: This design results in cleaner, more maintainable code with clear fallback logic and proper error handling.

### 4. Testing

The test suite covers the contact strategy implementation through factory patterns and service tests:

- **Factory Traits** (`test/factories/guardian_relationships.rb`):
  - `:dependent_shares_contact` - Sets dependent to use guardian's contact info
  - Various phone type traits (`:dependent_with_voice_phone`, `:dependent_with_videophone`, etc.)

- **Service Testing** - Tests cover:
  - Scenarios for a dependent having their own email and phone (`email_strategy: 'dependent'`)
  - Scenarios for a dependent sharing a guardian's email (`email_strategy: 'guardian'`)
  - Mixed scenarios (e.g., own email, guardian's phone)
  - Address strategy handling
  - Proper encryption and validation of dependent contact fields
  - Fallback logic for when dependent contact information is left blank
  - System-generated unique emails for constraint avoidance

## Usage Patterns

### Scenario 1: Dependent has their own contact information
```ruby
dependent = User.create!(
  first_name: "Child",
  email: "child@example.com",
  phone: "555-0001",
  dependent_email: "child@example.com",  # Same as primary email
  dependent_phone: "555-0001"            # Same as primary phone
)

dependent.effective_email  # => "child@example.com"
dependent.effective_phone  # => "555-0001"
# Note: has_own_contact_info? method not currently implemented
```

### Scenario 2: Dependent shares guardian's contact information
```ruby
dependent = User.create!(
  first_name: "Child",
  email: "dependent-abc123@system.matvulcan.local",  # System-generated
  phone: "000-000-1234",                             # System-generated
  dependent_email: "guardian@example.com",           # Guardian's email
  dependent_phone: "555-0002"                        # Guardian's phone
)

dependent.effective_email  # => "guardian@example.com"
dependent.effective_phone  # => "555-0002"
# Note: uses_guardian_contact_info? method not currently implemented
```

## Current Implementation Status

The system currently implements:
- ✅ Encrypted `dependent_email` and `dependent_phone` fields
- ✅ Contact strategy handling in `GuardianDependentManagementService`
- ✅ `effective_email`, `effective_phone`, `effective_phone_type`, `effective_communication_preference` methods
- ✅ Factory patterns for testing different contact scenarios
- ✅ Proper uniqueness constraint handling with system-generated fallback emails

## Future Enhancements

- Implement missing helper methods: `has_own_contact_info?` and `uses_guardian_contact_info?`
- Update frontend forms to properly handle dependent contact field selection
- Add an admin interface for managing dependent contact preferences
- Consider extending this pattern to other contact fields (e.g., emergency contacts)
- Improve contact strategy UI in paper application forms
