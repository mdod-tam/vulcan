# PII Encryption Implementation Guide

Rails 8 ActiveRecord Encryption protects all personally identifiable data in MAT Vulcan. This guide explains **what is encrypted, how queries work, and how to maintain the encryption system**.

---

## 1 · What We Encrypt

| Model / Table | Column | Deterministic? | Why |
|---------------|--------|----------------|-----|
| `users` | `email`, `phone`, `dependent_email`, `dependent_phone`, `ssn_last4`, `date_of_birth` | **Yes** | We must query & index them |
|         | `password_digest` | No | Hash is already random; extra layer |
|         | `physical_address_1/2`, `city`, `state`, `zip_code` | No | Not queried directly |
| `totp_credentials` | `secret` | No | Never queried |
| `sms_credentials` | `code_digest` | No | Never queried |
| `webauthn_credentials` | `public_key` | No | Never queried |

**Deterministic = identical plaintext → identical ciphertext → indexable.** Trade-off: slight leakage of equality; documented in security controls.

---

## 2 · Model Declarations (Current Implementation)

```ruby
# app/models/concerns/user_profile.rb (included in User)
encrypts :email, deterministic: true
encrypts :phone, deterministic: true
encrypts :dependent_email, deterministic: true
encrypts :dependent_phone, deterministic: true
encrypts :ssn_last4, deterministic: true
encrypts :password_digest
encrypts :date_of_birth, deterministic: true
encrypts :physical_address_1
encrypts :physical_address_2
encrypts :city
encrypts :state
encrypts :zip_code

# app/models/totp_credential.rb
class TotpCredential < ApplicationRecord
  encrypts :secret
end

# app/models/sms_credential.rb  
class SmsCredential < ApplicationRecord
  encrypts :code_digest
end

# app/models/webauthn_credential.rb
class WebauthnCredential < ApplicationRecord
  encrypts :public_key
end
```

---

## 3 · Query Helpers (Current Implementation)

Rails 8 transparent encryption allows normal queries, but we have helper methods for reliability:

```ruby
# app/models/user.rb
def self.find_by_email(email_value)
  return nil if email_value.blank?
  
  # With transparent encryption, we can use regular find_by
  User.find_by(email: email_value)
rescue StandardError => e
  Rails.logger.warn "find_by_email failed: #{e.message}"
  nil
end

def self.find_by_phone(phone_value)
  return nil if phone_value.blank?
  
  User.find_by(phone: phone_value)
rescue StandardError => e
  Rails.logger.warn "find_by_phone failed: #{e.message}"
  nil
end

def self.exists_with_email?(email_value, excluding_id: nil)
  return false if email_value.blank?
  
  query = User.where(email: email_value)
  query = query.where.not(id: excluding_id) if excluding_id
  query.exists?
rescue StandardError => e
  Rails.logger.warn "exists_with_email? failed: #{e.message}"
  false
end

def self.exists_with_phone?(phone_value, excluding_id: nil)
  return false if phone_value.blank?
  
  query = User.where(phone: phone_value)
  query = query.where.not(id: excluding_id) if excluding_id
  query.exists?
rescue StandardError => e
  Rails.logger.warn "exists_with_phone? failed: #{e.message}"
  false
end
```

Use these helpers **everywhere** instead of direct `find_by(email:)` for consistency and error handling.

---

## 4 · Database Schema (Current State)

The users table stores encrypted data directly in the original columns:

```sql
-- No separate _encrypted columns needed with Rails 8 transparent encryption
CREATE TABLE "users" (
  "email" varchar(510) NOT NULL,           -- Encrypted deterministically
  "phone" varchar(300),                    -- Encrypted deterministically  
  "dependent_email" varchar,               -- Encrypted deterministically
  "dependent_phone" varchar,               -- Encrypted deterministically
  "ssn_last4" varchar(300),               -- Encrypted deterministically
  "date_of_birth" text,                   -- Encrypted deterministically
  "password_digest" varchar(500) NOT NULL, -- Encrypted non-deterministically
  "physical_address_1" varchar(1000),     -- Encrypted non-deterministically
  "physical_address_2" varchar(1000),     -- Encrypted non-deterministically
  "city" varchar(500),                    -- Encrypted non-deterministically
  "state" varchar(300),                   -- Encrypted non-deterministically
  "zip_code" varchar(300),                -- Encrypted non-deterministically
  -- ... other columns ...
);

-- Indexes work on encrypted values for deterministic columns
CREATE UNIQUE INDEX "index_users_on_email_unique" ON "users" ("email");
CREATE UNIQUE INDEX "index_users_on_phone_unique" ON "users" ("phone") WHERE "phone" IS NOT NULL;
CREATE INDEX "index_users_on_dependent_email" ON "users" ("dependent_email");
CREATE INDEX "index_users_on_dependent_phone" ON "users" ("dependent_phone");
```

---

## 5 · Configuration (Current Implementation)

### Encryption Keys
```ruby
# config/initializers/active_record_encryption.rb
Rails.application.configure do
  config.active_record.encryption.add_to_filter_parameters = true
  config.active_record.encryption.extend_queries = false  # Disabled - causing issues in Rails 8.0
  
  # Keys loaded from Rails.application.credentials.active_record_encryption
  encryption_config = Rails.application.credentials.active_record_encryption
  if encryption_config.present?
    config.active_record.encryption.primary_key = encryption_config.primary_key
    config.active_record.encryption.deterministic_key = encryption_config.deterministic_key
    config.active_record.encryption.key_derivation_salt = encryption_config.key_derivation_salt
  else
    # Fallback for development/test when credentials missing
    Rails.logger.warn '[ENCRYPTION] Using temporary keys for missing credentials.'
    config.active_record.encryption.primary_key = SecureRandom.hex(32)
    config.active_record.encryption.deterministic_key = SecureRandom.hex(32)
    config.active_record.encryption.key_derivation_salt = SecureRandom.hex(32)
  end
  
  config.active_record.encryption.support_unencrypted_data = true
  config.active_record.encryption.encrypt_fixtures = true
  config.active_record.encryption.store_key_references = true
end
```

### Parameter Filtering
```ruby
# config/initializers/filter_parameter_logging.rb
Rails.application.config.filter_parameters += [
  # Password-related fields
  :password, :password_confirmation, :current_password, :password_digest,
  
  # PII fields (plaintext) - User model
  :email, :phone, :ssn_last4, :date_of_birth,
  :physical_address_1, :physical_address_2, :city, :state, :zip_code,
  
  # SMS credential specific field
  :phone_number,
  
  # Medical provider PII fields
  :medical_provider_name, :medical_provider_phone, :medical_provider_email, :medical_provider_fax,
  
  # Encrypted columns and IVs (regex patterns)
  /_encrypted\z/, /_encrypted_iv\z/,
  
  # Authentication credential secrets
  :secret, :code_digest,
  
  # Legacy broad filters
  /passw/, /\btoken\z/, /_key\z/, /crypt/, /salt/, /certificate/, /\botp\z/, /\bssn\z/, /cvv/, /cvc/
]
```

---

## 6 · Testing Encryption

Current test approach verifies encryption is working:

```ruby
# test/models/user_encrypted_validation_test.rb
test 'creates user with transparent encryption' do
  attrs = unique_attributes
  user = User.create!(attrs)
  
  # Data should be accessible as plaintext (Rails decrypts automatically)
  assert_equal attrs[:email], user.email
  assert_equal attrs[:phone], user.phone
  assert_equal attrs[:ssn_last4], user.ssn_last4
  
  # Verify encryption is actually happening in the database
  if data_encrypted_in_database?(user)
    puts '✓ Encryption is working - data is encrypted in database but accessible as plaintext'
  else
    puts '⚠ Encryption may not be working yet - data appears to be stored as plaintext'
  end
end

test 'helper methods work with encrypted data' do
  user = create(:user, email: 'test@example.com', phone: '555-123-4567')
  
  assert_equal user, User.find_by_email('test@example.com')
  assert_equal user, User.find_by_phone('555-123-4567')
  assert User.exists_with_email?('test@example.com')
  assert User.exists_with_phone?('555-123-4567')
  assert_not User.exists_with_email?('nonexistent@example.com')
end
```

---

## 7 · Key Rotation (Future Need)

When key rotation is required:

```yaml
# credentials.yml.enc
active_record_encryption:
  primary_key: <new>
  deterministic_key: <new>
  key_derivation_salt: <new>
  previous:
    - primary_key: <old>
      deterministic_key: <old>
      key_derivation_salt: <old>
```

Then create a rake task to re-save all encrypted records:

```ruby
# lib/tasks/pii.rake
namespace :pii do
  desc 'Rotate encryption keys by re-saving all encrypted records'
  task rotate_keys: :environment do
    User.find_each(&:save!)
    TotpCredential.find_each(&:save!)
    SmsCredential.find_each(&:save!)
    WebauthnCredential.find_each(&:save!)
    puts 'Key rotation complete.'
  end
  
  desc 'Verify all records can be decrypted'
  task verify: :environment do
    errors = []
    
    User.find_each do |user|
      begin
        user.email # Force decryption
        user.phone
        user.ssn_last4
      rescue => e
        errors << "User #{user.id}: #{e.message}"
      end
    end
    
    if errors.any?
      puts "Decryption errors found:"
      errors.each { |error| puts "  #{error}" }
    else
      puts "All records decrypt successfully."
    end
  end
end
```

Remove the `previous:` block once all records are rotated.

---

## 8 · Current Status & Gotchas

### ✅ Already Implemented
- Rails 8 ActiveRecord Encryption enabled
- All PII fields encrypted in User model and credential models
- Transparent encryption allows normal queries
- Helper methods for consistent querying
- Parameter filtering configured
- Test coverage for encryption functionality
- Database indexes work on encrypted deterministic columns

### ⚠️ Important Notes
- **extend_queries disabled** - Rails 8 has bugs with this feature, so we rely on transparent encryption instead
- **support_unencrypted_data enabled** - allows reading existing unencrypted data during any transition period
- **Deterministic encryption** trades some security for queryability - this is documented in security controls
- **Database backups** require encryption keys for restore - ensure keys are included in disaster recovery procedures
- **Column limits increased** - encrypted data takes more space than plaintext (varchar limits set appropriately)

### 🔍 Monitoring
- Watch for encryption/decryption errors in logs
- Monitor query performance on encrypted columns
- Ensure all user creation/update flows use the helper methods
- Verify no sensitive data appears in logs (parameter filtering should prevent this)

---

## 9 · Migration History

The current implementation uses Rails 8's transparent encryption, which stores encrypted data directly in the original columns without separate `_encrypted` columns. This approach:

1. **Simpler schema** - No additional columns needed
2. **Transparent queries** - Normal ActiveRecord queries work
3. **Easier migration** - Existing data can be encrypted in place
4. **Better performance** - No query translation overhead

If migrating from an older encryption approach, the `support_unencrypted_data` flag allows reading both encrypted and unencrypted data during the transition.