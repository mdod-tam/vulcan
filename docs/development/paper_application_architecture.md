# Paper Application Architecture (Rails)

A concise reference for how the admin-only “paper” application path works and how to extend or test it safely.

---

## 1 · High-Level Flow

```
Admin → Admin::PaperApplicationsController → Applications::PaperApplicationService
            ↘ proofs (accept/reject) ↙
                     Audits / Notifications
```

* **Why a separate path?** Paper apps bypass online-only validations (proof uploads, attachment checks) while still preserving audit trails.
* **Key difference from portal:** Uses `Current.paper_context = true` to bypass some validations. Approvals still require attachments; only rejections may proceed without a file.

---

## 2 · Key Components

### 2.1 · Applications::PaperApplicationService

```ruby
service = Applications::PaperApplicationService.new(
  params: paper_application_processing_params,
  admin: current_user
)
service.create  # returns true/false
```

| Responsibility | Notes |
|----------------|-------|
| Constituent lookup / create | Delegates to `GuardianDependentManagementService` and `UserCreationService` |
| GuardianRelationship | Handled by `GuardianDependentManagementService` |
| Proof processing | Upload, accept with file, reject without file using `ProofAttachmentService` |
| Thread-local context | `Current.paper_context = true` (auto-managed in ensure block) |
| Audits & notifications | Uses `AuditEventService` and `NotificationService` |

---

### 2.2 · Admin::PaperApplicationsController

```ruby
def create
  service = Applications::PaperApplicationService
              .new(params: paper_application_processing_params, admin: current_user)

  if service.create
    redirect_to admin_application_path(service.application),
                notice: generate_success_message(service.application)
  else
    handle_service_failure(service)
  end
end
```

Handles web UI, guardian search/creation, proof buttons, and FPL checks.

---

## 3 · Thread-Local Context

```ruby
Current.paper_context = true
begin
  # create application, process proofs, etc.
ensure
  Current.paper_context = nil
end
```

* Skips certain validations for paper flows via `Current.paper_context`.
* Approvals still require an attached file; rejections do not.
* Always reset in `ensure` or test teardown.

---

## 4 · Guardian / Dependent Logic

| Flow | Key Points |
|------|------------|
| **Self-applicant** | `managing_guardian_id` is `nil`. |
| **Dependent** | Guardian selected/created → `GuardianRelationship` made → app’s `managing_guardian_id` set. |

Guardian creation snippet:

```ruby
# Actual implementation delegates to GuardianDependentManagementService:
service = GuardianDependentManagementService.new(params)
result = service.process_guardian_scenario(guardian_id, new_guardian_attrs, applicant_data, relationship_type)

if result.success?
  @guardian_user_for_app = result.data[:guardian]
  @constituent = result.data[:dependent]
end
```

---

## 5 · Proof Processing

Paper applications can process proofs in two ways:

1. **Accept with file**: Uses `ProofAttachmentService.attach_proof` to attach and approve
2. **Reject without file**: Uses `ProofAttachmentService.reject_proof_without_attachment`

```ruby
# Accept with file
result = ProofAttachmentService.attach_proof(
  application: @application,
  proof_type: type,
  blob_or_file: blob_or_file,
  status: :approved,
  admin: @admin,
  submission_method: :paper
)
```

<!-- Accept without file is not allowed when approving. Selecting approve without a file will return a validation error. -->

```ruby
# Reject
ProofAttachmentService.reject_proof_without_attachment(
  application: @application,
  proof_type: type,
  admin: @admin,
  reason: params["#{type}_proof_rejection_reason"],
  notes: params["#{type}_proof_rejection_notes"],
  submission_method: :paper
)
```

---

## 6 · Form Front-End

| Stimulus Controller | Role |
|---------------------|------|
| `paper_application_controller` | Overall coordination / income check |
| `applicant_type_controller`    | Adult vs dependent toggle |
| `dependent_fields_controller`  | Dependent-only inputs |
| `guardian_picker_controller`   | Search & select/create guardian |
| `document_proof_handler_controller` | Accept / reject buttons |

Form sections (in order):

1. Applicant type  
2. Guardian info (if dependent)  
3. Applicant info  
4. Application details (household size, income, provider)  
5. Proof documents  

---

## 7 · Parameter Shape

```ruby
{
  applicant_type:   "dependent",
  relationship_type:"Parent",
  guardian_id:      123,           # or guardian_attributes
  guardian_attributes: { ... },
  constituent: { ... },            # applicant
  email_strategy:  "dependent",    # or "guardian"
  phone_strategy:  "guardian",
  address_strategy:"guardian",
  application: { household_size:3, annual_income:25_000 },
  income_proof_action:    "accept",
  residency_proof_action: "reject",
  # proof files or signed IDs may be included
}
```

Processing steps:

1. Validate & cast → **FPL threshold check**.  
2. Process guardian (if dependent).  
3. Process applicant.  
4. Apply contact strategies.  
5. Create GuardianRelationship.  
6. Build Application.  
7. Handle proofs.  
8. Audit & notify.

---

## 8 · Testing Guide

### 8.1 · Context Setup

```ruby
setup    { Current.paper_context = true }
teardown { Current.paper_context = nil }
```

### 8.2 · Guardian Relationship

```ruby
assert_difference ['GuardianRelationship.count', 'Application.count'] do
  service = Applications::PaperApplicationService
              .new(params: dependent_params, admin: @admin)
  assert service.create
  assert service.application.persisted?
end
```

<!-- Removed: approval without file is not supported. Approvals require an attachment. -->

---

## 9 · Error Handling

```ruby
def handle_service_failure(service, existing_application = nil)
  error_msg = if service.errors.any?
                service.errors.join('; ')
              else
                'An error occurred while processing the application.'
              end
  
  flash.now[:alert] = error_msg
  repopulate_form_data(service, existing_application)
  render(existing_application ? :edit : :new, status: :unprocessable_entity)
end
```

Typical failures: FPL too high, missing guardian data, proof issues, user validation errors.

---

## 10 · Medical Certification Submission Methods

Paper applications support the same medical certification submission methods as online applications:

1. **Email**: Automated processing via `MedicalCertificationMailbox`
2. **Fax**: **PARTIALLY IMPLEMENTED** - Outbound only (see gaps below)
3. **Snail Mail**: Admin receives mail, scans document, uploads via admin interface (`admin/applications#show`)

All methods update the `medical_certification_status` to 'received' and create appropriate audit trails.

### 10.1 · Fax Implementation Status

**Currently Implemented:**
- ✅ **Outbound Fax Sending**: `FaxService` + `MedicalProviderNotifier` can send certification requests via Twilio
- ✅ **Fax Status Tracking**: `TwilioController#fax_status` webhook handles delivery status updates
- ✅ **Fallback Logic**: Auto-falls back to email if fax fails
- ✅ **PDF Generation**: Creates formatted PDFs for fax transmission

**Implementation Gaps (Manual Process Required):**
- ❌ **Inbound Fax Processing**: No automated processing of incoming faxes from providers
- ❌ **Fax-to-Email Bridge**: No Twilio webhook to convert received faxes to email for mailbox processing
- ❌ **Fax Media URL Handling**: `FaxService#send_pdf_fax` uses placeholder `file://` URLs (needs S3 integration)

### 10.2 · Required Work for Full Fax Support

To fully implement inbound fax processing, the following components need to be added:

1. **Twilio Fax Receive Webhook** (`webhooks/twilio#fax_received`):
   ```ruby
   # Handle incoming faxes from Twilio
   def fax_received
     media_url = params[:MediaUrl]
     from_number = params[:From]
     # Download fax media, identify application, attach to medical_certification
   end
   ```

2. **Fax Media Processing Service**:
   ```ruby
   # Service to download and process fax media from Twilio
   class FaxMediaProcessor
     def process_inbound_fax(media_url:, from_number:, fax_sid:)
       # Download media, identify provider/application, create attachment
     end
   end
   ```

3. **Provider Phone Number Mapping**:
   ```ruby
   # Add fax number tracking to applications table or medical_providers
   add_column :applications, :medical_provider_fax, :string
   # Or create MedicalProvider model with phone/fax/email mapping
   ```

4. **S3 Integration for Outbound Fax**:
   ```ruby
   # Update FaxService to upload PDFs to S3 before sending
   def upload_pdf_to_s3(pdf_path)
     # Upload to S3, return public URL for Twilio media_url
   end
   ```

**Current Workaround**: Providers can fax to a dedicated fax number, admin manually scans/uploads via `admin/applications#show` interface.

---

## 11 · Current Implementation Details

The current implementation has the following characteristics:

*   **Validation**: Some validation logic resides in client-side JavaScript.
*   **Service Layer**: The `PaperApplicationService` handles the core creation and update logic, but the controller still performs significant processing.
*   **Views**: The form is rendered using ERB partials, which contain some repetitive logic.

Recent controller enhancements include:

*   Unified `constituent` parameters.
*   The addition of `email_strategy`, `phone_strategy`, and `address_strategy` to manage contact information.
*   Inference of dependent applications when `guardian_attributes` are present.
