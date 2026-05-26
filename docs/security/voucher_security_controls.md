# Voucher Security Controls and Safeguards

## Overview

The MAT Vulcan voucher system implements multiple layers of security controls to prevent fraud, abuse, and unauthorized access. This document outlines all security measures implemented to protect the voucher lifecycle from creation to redemption.

## Table of Contents

1. [Voucher Eligibility Controls](#voucher-eligibility-controls)
2. [Voucher Creation Safeguards](#voucher-creation-safeguards)
3. [Voucher Redemption Security](#voucher-redemption-security)
4. [Vendor Authorization Controls](#vendor-authorization-controls)
5. [Identity Verification](#identity-verification)
6. [Financial Safeguards](#financial-safeguards)
7. [Audit and Monitoring](#audit-and-monitoring)
8. [Technical Security Measures](#technical-security-measures)

---

## Voucher Eligibility Controls

### Application Status Requirements
Before a voucher can be assigned to a constituent, their application must meet strict eligibility criteria:

**Required Status Checks:**
- `status_approved?` - Application must be fully approved by an administrator
- `voucher_fulfillment?` - Application must be assigned to voucher fulfillment
- `required_proofs_approved?` - Required proof statuses must all be approved
- `medical_certification_status_approved?` - Medical certification must be verified and approved
- Only one voucher may exist for the application

**Implementation:**
```ruby
def can_create_voucher?
  voucher_fulfillment? &&
    status_approved? &&
    required_proofs_approved? &&
    medical_certification_status_approved? &&
    !vouchers.exists?
end
```

**Safeguards:**
- Only ONE voucher per application (prevents duplicate voucher fraud)
- All documentation must be administrator-reviewed before voucher eligibility
- Automated checks prevent voucher creation if any requirement is missing

---

## Voucher Creation Safeguards

### Unique Code Generation
**Security Measure:** Cryptographically secure voucher codes
- 12-character alphanumeric codes generated using `SecureRandom.alphanumeric`
- Uniqueness enforced at database level with unique constraints
- Codes are case-sensitive and contain no predictable patterns

**Implementation:**
```ruby
def generate_code
  loop do
    self.code = SecureRandom.alphanumeric(12).upcase
    break unless Voucher.exists?(code: code)
  end
end
```

### Value Calculation Security
**Automatic Value Assignment:**
- Voucher values are calculated based on constituent's verified disability types
- Values are set programmatically based on policy configuration
- No manual value entry to prevent human error or manipulation

**Implementation:**
```ruby
def self.calculate_value_for_constituent(constituent)
  Constituent::DISABILITY_TYPES.sum do |disability_type|
    if constituent.send("#{disability_type}_disability") == true
      Policy.voucher_value_for_disability(disability_type)
    else
      0
    end
  end
end
```

### Creation Authorization
- Only authenticated administrators can trigger voucher creation
- Voucher creation is logged with full audit trail
- System user context is maintained for all voucher operations

---

## Voucher Redemption Security

### Multi-Layer Redemption Protection

#### 1. Client-Side Validation
**HTML5 Form Constraints:**
- Amount input field has `max` attribute set to voucher's remaining value
- Browser prevents form submission if amount exceeds balance
- Required field validation prevents empty submissions

#### 2. Server-Side Validation
**Controller-Level Checks:**
```ruby
# Amount validation
if redemption_amount > available_amount
  flash[:alert] = "Cannot redeem more than the available amount"
  redirect_to redeem_vendor_voucher_path(@voucher.code)
  return
end

# Product selection validation
if params[:product_ids].blank?
  flash[:alert] = 'Please select at least one product'
  redirect_to redeem_vendor_voucher_path(@voucher.code)
  return
end
```

#### 3. Model-Level Protection
**Business Logic Safeguards:**
```ruby
def can_redeem?(amount)
  return false unless voucher_active?
  return false if expired?
  return false if amount > remaining_value
  return false if amount < Policy.voucher_minimum_redemption_amount
  true
end
```

### Redemption State Management
**Atomic Transactions:**
- All voucher updates use database transactions
- Race condition prevention through SQL-level updates
- Voucher state changes are atomic and consistent

**Implementation:**
```ruby
Voucher.where(id: @voucher.id).update_all(
  remaining_value: new_remaining_value,
  vendor_id: current_user.id,
  status: new_status
)
```

---

## Vendor Authorization Controls

### Vendor Qualification Requirements
Before a vendor can process vouchers, they must meet ALL requirements:

**Required Qualifications:**
1. `vendor_approved?` - Vendor status must be "approved"
2. `w9_form.attached?` - Valid W9 tax form must be uploaded
3. `w9_status_approved?` - W9 form must be administrator-approved

**Implementation:**
```ruby
def can_process_vouchers?
  vendor_approved? && w9_form.attached? && w9_status_approved?
end
```

### Vendor Account Security
- Vendors must be authenticated users with proper session management
- Vendor accounts are subject to regular review and can be deactivated
- W9 forms have expiration dates and require renewal

---

## Identity Verification

### Date of Birth Verification
**Multi-Attempt Protection:**
- Maximum 3 verification attempts per voucher per session
- Failed attempts are logged and tracked
- Account lockout after maximum attempts exceeded

**Implementation:**
```ruby
def verify
  if dobs_match?
    handle_successful_verification
  else
    handle_failed_verification
  end
end
```

### Session-Based Verification Tracking
- Verification status stored in secure session data
- Verification required for each voucher redemption
- Session data cleared on logout for security

**Session Management:**
```ruby
def identity_verified?(voucher)
  session[:verified_vouchers].present? &&
    session[:verified_vouchers].include?(voucher.id)
end
```

---

## Financial Safeguards

### Minimum Redemption Amounts
- Policy-based minimum redemption amounts prevent micro-transactions
- Prevents voucher fragmentation and administrative overhead
- Configurable through system policies

### Remaining Value Protection
- Voucher remaining value cannot exceed initial value (database constraint)
- Decimal precision maintained for accurate financial calculations
- Automatic status updates when voucher is fully redeemed

### Transaction Reference Numbers
**Unique Transaction Tracking:**
- Each transaction gets a unique reference number
- Format: `TX-[voucher-code-part]-[timestamp]-[random]`
- Enables transaction tracking and dispute resolution

---

## Audit and Monitoring

### Comprehensive Audit Trail
**All voucher operations are logged:**
- Voucher creation with actor and timestamp
- Redemption attempts (successful and failed)
- Status changes with reasons
- Identity verification attempts

**Implementation:**
```ruby
AuditEventService.log(
  action: 'voucher_redeemed',
  actor: vendor,
  auditable: voucher,
  metadata: {
    amount: amount,
    vendor_name: vendor.business_name,
    transaction_id: transaction.id,
    remaining_value: remaining_value
  }
)
```

### Event Tracking
- All user interactions with vouchers are tracked in Event model
- IP addresses and user agents logged for security analysis
- Failed verification attempts trigger security alerts

### Email Notifications
**Automated Notifications:**
- Voucher assignment notifications to constituents
- Redemption confirmations with transaction details
- Expiration warnings and notifications
- Vendor notifications for successful redemptions

---

## Technical Security Measures

### Database-Level Security
**Constraints and Validations:**
- Unique constraints on voucher codes
- Foreign key constraints for data integrity
- Enum validations for status fields
- Numeric validations for amounts and values

### Expiration Management
**Automated Expiration:**
- Vouchers automatically expire after policy-defined period
- Expired vouchers cannot be redeemed
- Expiration status is checked before any redemption attempt

**Implementation:**
```ruby
def expired?
  return true if status == 'expired'
  if issued_at
    issued_at + Policy.voucher_validity_period <= Time.current
  else
    false
  end
end
```

### Status Transition Security
**Controlled State Machine:**
- Voucher status transitions follow strict business rules
- Invalid status transitions are prevented
- Status changes are logged and auditable

**Valid Status Transitions:**
- `active` → `redeemed` (when fully used)
- `active` → `expired` (when time limit exceeded)
- `active` → `cancelled` (admin action only)

### Race Condition Prevention
**Concurrent Access Protection:**
- Database-level locking for voucher updates
- Atomic operations for balance calculations
- Transaction isolation to prevent double-spending

---

## Security Best Practices Implemented

### Defense in Depth
1. **Client-side validation** - First line of defense
2. **Server-side validation** - Business logic enforcement
3. **Model-level validation** - Data integrity protection
4. **Database constraints** - Final safety net

### Principle of Least Privilege
- Vendors can only access their own processed vouchers
- Administrators have read-only access to voucher details
- Constituents can only view their own voucher status

### Secure by Default
- All new vouchers start in `active` status
- Minimum redemption amounts prevent abuse
- Automatic expiration prevents indefinite validity

### Audit Everything
- All voucher operations are logged
- Failed attempts are tracked and monitored
- Regular audit reports can be generated

---

## Monitoring and Alerting

### Security Monitoring
- Failed identity verification attempts
- Unusual redemption patterns
- Expired voucher redemption attempts
- Multiple failed login attempts from vendors

### Automated Alerts
- Voucher expiration warnings
- Large redemption amounts (configurable thresholds)
- Vendor account issues (expired W9, etc.)
- System errors during voucher processing

---

## Conclusion

The voucher system implements comprehensive security controls across all layers of the application stack. From strict eligibility requirements to multi-layer redemption protection, the system is designed to prevent fraud, abuse, and unauthorized access while maintaining usability for legitimate users.

Regular security reviews and updates ensure these controls remain effective against evolving threats and attack vectors.

**Key Security Principles:**
- **Trust but Verify**: All operations are validated and logged
- **Defense in Depth**: Multiple layers of protection
- **Fail Secure**: System fails to a secure state when errors occur
- **Audit Everything**: Complete audit trail for all operations
- **Least Privilege**: Users have minimal necessary access 
