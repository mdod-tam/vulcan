# Accessibility Fixes - Implementation Guide
**Priority: P0/P1 Fixes Only**
**Estimated Time: 30 minutes**

## Critical Fixes (P0 - Deploy Immediately)

### Fix 1: Hidden Sections Accessible to Screen Readers (CRITICAL)

**File:** `app/javascript/controllers/users/document_proof_handler_controller.js`

**Lines:** 63-64

**Before:**
```javascript
// Toggle visibility of sections using utility
setVisible(this.uploadSectionTarget, isAccepted);
setVisible(this.rejectionSectionTarget, isRejected);
```

**After:**
```javascript
// Toggle visibility of sections using utility
setVisible(this.uploadSectionTarget, isAccepted, { ariaHidden: !isAccepted });
setVisible(this.rejectionSectionTarget, isRejected, { ariaHidden: !isRejected });
```

**Why:** Without `ariaHidden`, screen readers announce hidden content, causing massive confusion.

**Test:** 
1. Navigate to `/admin/paper_applications/new`
2. Select "Reject" for income proof
3. Use screen reader - should NOT hear "Upload Income Proof Document"
4. Should ONLY hear rejection fields

---

### Fix 2: Redundant ARIA Roles (CRITICAL - 2 locations)

**File:** `app/views/admin/paper_applications/new.html.erb`

#### Location 1: Line 716-718 (Income Proof)

**Before:**
```erb
<fieldset class="mb-4">
  <legend class="text-sm font-medium text-gray-700 mb-2">Income Proof Action</legend>
  <div role="radiogroup" aria-label="Income proof action" class="flex flex-wrap gap-4">
    <label class="flex items-center p-3...">
```

**After:**
```erb
<fieldset class="mb-4">
  <legend class="text-sm font-medium text-gray-700 mb-2">Income Proof Action</legend>
  <div class="flex flex-wrap gap-4">
    <label class="flex items-center p-3...">
```

#### Location 2: Line 832-834 (Residency Proof)

**Before:**
```erb
<fieldset class="mb-4">
  <legend class="text-sm font-medium text-gray-700 mb-2">Residency Proof Action</legend>
  <div role="radiogroup" aria-label="Residency proof action" class="flex flex-wrap gap-4">
    <label class="flex items-center p-3...">
```

**After:**
```erb
<fieldset class="mb-4">
  <legend class="text-sm font-medium text-gray-700 mb-2">Residency Proof Action</legend>
  <div class="flex flex-wrap gap-4">
    <label class="flex items-center p-3...">
```

**Why:** Fieldset already provides grouping. Adding role="radiogroup" causes double announcements.

**Test:**
1. Use screen reader on paper application form
2. Navigate to "Income Proof Action" fieldset
3. Should hear: "Income Proof Action, group" (ONCE)
4. Should NOT hear: "Income Proof Action, group. Income proof action, radio group"

---

## Serious Fixes (P1 - Deploy This Week)

### Fix 3: Silent Dynamic Preview Text (SERIOUS - 3 changes)

#### Change 3a: Income Proof Preview

**File:** `app/views/admin/paper_applications/new.html.erb`

**Line:** 790

**Before:**
```erb
<div id="income_proof_reason_preview" 
     class="p-3 bg-gray-50 border border-gray-200 rounded-md text-sm text-gray-700 hidden" 
     data-document-proof-handler-target="reasonPreview"></div>
```

**After:**
```erb
<div id="income_proof_reason_preview" 
     class="p-3 bg-gray-50 border border-gray-200 rounded-md text-sm text-gray-700 hidden" 
     role="status"
     aria-live="polite"
     aria-atomic="true"
     data-document-proof-handler-target="reasonPreview"></div>
```

#### Change 3b: Residency Proof Preview

**File:** `app/views/admin/paper_applications/new.html.erb`

**Line:** 903

**Before:**
```erb
<div id="residency_proof_reason_preview" 
     class="p-3 bg-gray-50 border border-gray-200 rounded-md text-sm text-gray-700 hidden" 
     data-document-proof-handler-target="reasonPreview"></div>
```

**After:**
```erb
<div id="residency_proof_reason_preview" 
     class="p-3 bg-gray-50 border border-gray-200 rounded-md text-sm text-gray-700 hidden" 
     role="status"
     aria-live="polite"
     aria-atomic="true"
     data-document-proof-handler-target="reasonPreview"></div>
```

#### Change 3c: JavaScript Preview Update

**File:** `app/javascript/controllers/users/document_proof_handler_controller.js`

**Line:** 112

**Before:**
```javascript
previewTarget.textContent = this.formatRejectionReason(selectedReason);
setVisible(previewTarget, true);
```

**After:**
```javascript
previewTarget.textContent = this.formatRejectionReason(selectedReason);
setVisible(previewTarget, true, { ariaHidden: false });
```

**Why:** Dynamic content updates must be announced to screen reader users via aria-live.

**Test:**
1. Use screen reader on paper application form
2. Select "Address Mismatch" from rejection reason dropdown
3. Screen reader should announce: "The address on the document does not match the application address."
4. Without fix, nothing is announced

---

### Fix 4: Required Field Indicator Hidden (SERIOUS - 2 locations)

#### Location 1: Sign Up Page

**File:** `app/views/registrations/new.html.erb`

**Line:** 18

**Before:**
```erb
<p style="text-align: center;" class="text-l text-gray-900" aria-hidden="true">
  <span style="color: red;">*</span> Indicates a required field
</p>
```

**After:**
```erb
<p style="text-align: center;" class="text-l text-gray-900">
  <span style="color: red;">*</span> Indicates a required field
</p>
```

#### Location 2: Paper Application Page

**File:** `app/views/admin/paper_applications/new.html.erb`

**Line:** 12

**Before:**
```erb
<p class="text-l text-gray-900" aria-hidden="true">
  <span style="color: red;">*</span> Indicates a required field
</p>
```

**After:**
```erb
<p class="text-l text-gray-900">
  <span style="color: red;">*</span> Indicates a required field
</p>
```

**Why:** Screen readers skip aria-hidden content, so blind users never learn what asterisk means.

**Test:**
1. Use screen reader on sign up page
2. Should hear: "star Indicates a required field" near top of form
3. Individual fields still have aria-required="true" so this is supplementary

---

## Summary of Changes

| File | Lines | Changes | Priority |
|------|-------|---------|----------|
| `document_proof_handler_controller.js` | 63-64 | Add `ariaHidden` parameter (2 lines) | P0 |
| `paper_applications/new.html.erb` | 718, 834 | Remove role + aria-label (2 locations) | P0 |
| `paper_applications/new.html.erb` | 790, 903 | Add aria-live attributes (2 locations) | P1 |
| `document_proof_handler_controller.js` | 112 | Add `ariaHidden: false` (1 line) | P1 |
| `registrations/new.html.erb` | 18 | Remove aria-hidden (1 line) | P1 |
| `paper_applications/new.html.erb` | 12 | Remove aria-hidden (1 line) | P1 |

**Total:** 6 files, 8 locations, ~10 lines of code

---

## Testing Protocol

### Manual Screen Reader Testing

**Tools Needed:**
- NVDA (Windows, free) OR
- JAWS (Windows, commercial) OR  
- VoiceOver (Mac, built-in)

**Test Script:**

1. **Test Fix #1 (Hidden sections)**
   - Navigate to `/admin/paper_applications/new`
   - Tab to "Income Proof Action"
   - Select "Reject"
   - Tab forward
   - ✅ PASS: Should go to "Rejection Reason" dropdown
   - ❌ FAIL: If you hear "Upload Income Proof Document"

2. **Test Fix #2 (Redundant roles)**
   - Navigate to `/admin/paper_applications/new`
   - Navigate to "Income Proof Action" fieldset
   - ✅ PASS: Hear "Income Proof Action, group" ONCE
   - ❌ FAIL: If you hear it twice or "radiogroup" mentioned

3. **Test Fix #3 (Silent preview)**
   - Navigate to `/admin/paper_applications/new`
   - Select "Reject" for income proof
   - Tab to "Rejection Reason" dropdown
   - Select "Address Mismatch"
   - ✅ PASS: Screen reader announces rejection reason text
   - ❌ FAIL: If nothing is announced after selecting

4. **Test Fix #4 (Required indicator)**
   - Navigate to `/sign_up`
   - ✅ PASS: Hear "star Indicates a required field" near top
   - ❌ FAIL: If this text is not announced

### Automated Testing

Add to test suite:

```ruby
# test/system/accessibility/paper_applications_test.rb
test "rejection sections are hidden from screen readers when not selected" do
  visit new_admin_paper_application_path
  
  # Check initial state
  assert_selector "#income_proof_upload:not([aria-hidden='true'])"
  assert_selector "#income_proof_rejection[aria-hidden='true']"
  
  # Select reject radio
  find("#reject_income_proof").click
  
  # Check updated state
  assert_selector "#income_proof_upload[aria-hidden='true']"
  assert_selector "#income_proof_rejection:not([aria-hidden='true'])"
end

test "rejection reason preview is announced to screen readers" do
  visit new_admin_paper_application_path
  
  preview = find("#income_proof_reason_preview")
  assert preview["role"] == "status"
  assert preview["aria-live"] == "polite"
  assert preview["aria-atomic"] == "true"
end
```

---

## Deployment Checklist

- [ ] Apply all P0 fixes (Fixes #1 and #2)
- [ ] Run automated tests
- [ ] Manual screen reader testing (all 4 fixes)
- [ ] Regression testing (ensure nothing broke)
- [ ] Deploy to staging
- [ ] UAT with actual screen reader user (if possible)
- [ ] Deploy to production
- [ ] Monitor error logs for 24 hours

---

## Rollback Plan

If issues arise:
1. Revert commit with these changes
2. Hidden sections issue (Fix #1) can be rolled back safely
3. ARIA role removal (Fix #2) can be rolled back safely
4. Dynamic announcements (Fix #3) - rolling back makes previews silent again but doesn't break functionality
5. Required indicator (Fix #4) - rolling back hides the text but fields still marked required

**No database changes required** - All fixes are view/JS only.

---

## Questions?

**Why not use `inert` attribute instead of aria-hidden?**
- `inert` is still not universally supported (especially in older assistive tech)
- `aria-hidden` is the WCAG-recommended approach for this use case
- `inert` removes keyboard access too, which we might not want in all cases

**Why aria-live="polite" not "assertive"?**
- "polite" waits for user to finish current action before announcing
- "assertive" interrupts immediately - too disruptive
- For form preview text, "polite" is appropriate

**Why aria-atomic="true" on previews?**
- Ensures entire message is read, not just the changed part
- Without it, screen readers might only announce "mismatch" instead of full sentence

---

**Last Updated:** January 29, 2026
