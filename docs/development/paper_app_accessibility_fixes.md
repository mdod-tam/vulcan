# Paper Application Form Accessibility Fixes

## Overview
Three critical accessibility issues were identified during a screen reader simulation audit of the paper application form. These issues affect blind users and violate WCAG 2.1 AA guidelines.

---

## Issue 1: Hidden sections remain accessible to screen readers (CRITICAL)

**Problem:**  
Upload and rejection sections are visually hidden with CSS `.hidden` class but lack `aria-hidden` attributes. Screen readers can still access and announce these sections when they should be completely hidden.

**Location:** `app/javascript/controllers/users/document_proof_handler_controller.js`, lines 63-64

**Current code:**
```javascript
setVisible(this.uploadSectionTarget, isAccepted);
setVisible(this.rejectionSectionTarget, isRejected);
```

**Fixed code:**
```javascript
setVisible(this.uploadSectionTarget, isAccepted, { ariaHidden: !isAccepted });
setVisible(this.rejectionSectionTarget, isRejected, { ariaHidden: !isRejected });
```

**Why this matters:**  
When "Reject" is selected, blind users hear both the upload section (which should be hidden) AND the rejection section, causing confusion about which fields to complete.

---

## Issue 2: Redundant ARIA roles cause double announcements (CRITICAL)

**Problem:**  
`role="radiogroup"` and `aria-label` attributes on `<div>` elements inside `<fieldset>` tags cause screen readers to announce the group name twice. The native `<fieldset>` + `<legend>` already provides proper semantic grouping.

**Locations:**
- `app/views/admin/paper_applications/new.html.erb`, line 718 (Income Proof Action)
- `app/views/admin/paper_applications/new.html.erb`, line 834 (Residency Proof Action)

**Current code:**
```erb
<fieldset class="mb-4">
  <legend class="text-sm font-medium text-gray-700 mb-2">Income Proof Action</legend>
  <div role="radiogroup" aria-label="Income proof action" class="flex flex-wrap gap-4">
```

**Fixed code:**
```erb
<fieldset class="mb-4">
  <legend class="text-sm font-medium text-gray-700 mb-2">Income Proof Action</legend>
  <div class="flex flex-wrap gap-4">
```

**Why this matters:**  
Screen readers announce: "Income Proof Action, group. Income proof action, radio group." This redundant announcement wastes the user's time and creates confusion.

**Action required:**
1. Remove `role="radiogroup"` from line 718
2. Remove `aria-label="Income proof action"` from line 718
3. Remove `role="radiogroup"` from line 834
4. Remove `aria-label="Residency proof action"` from line 834

---

## Issue 3: Dynamic preview text appears silently (MEDIUM)

**Problem:**  
When users select a rejection reason, preview text appears in the `reasonPreview` div, but screen readers don't announce it because the div lacks live region attributes.

**Locations:**
- `app/views/admin/paper_applications/new.html.erb`, line 790 (Income proof reason preview)
- `app/views/admin/paper_applications/new.html.erb`, line 903 (Residency proof reason preview)

**Current code:**
```erb
<div id="income_proof_reason_preview" class="p-3 bg-gray-50 border border-gray-200 rounded-md text-sm text-gray-700 hidden" data-document-proof-handler-target="reasonPreview"></div>
```

**Fixed code:**
```erb
<div id="income_proof_reason_preview" 
     class="p-3 bg-gray-50 border border-gray-200 rounded-md text-sm text-gray-700 hidden" 
     role="status" 
     aria-live="polite" 
     data-document-proof-handler-target="reasonPreview"></div>
```

**Why this matters:**  
When a staff member selects a rejection reason from the dropdown, the preview text appears but screen reader users never hear it. They miss important context about what message the applicant will receive.

**Action required:**
1. Add `role="status"` and `aria-live="polite"` to line 790 (income_proof_reason_preview)
2. Add `role="status"` and `aria-live="polite"` to line 903 (residency_proof_reason_preview)

---

## JavaScript fix also required

**Location:** `app/javascript/controllers/users/document_proof_handler_controller.js`, lines 112-114

**Current code:**
```javascript
if (selectedReason) {
  previewTarget.textContent = this.formatRejectionReason(selectedReason);
  setVisible(previewTarget, true);
} else {
  setVisible(previewTarget, false);
}
```

**Fixed code:**
```javascript
if (selectedReason) {
  previewTarget.textContent = this.formatRejectionReason(selectedReason);
  setVisible(previewTarget, true, { ariaHidden: false });
} else {
  setVisible(previewTarget, false, { ariaHidden: true });
}
```

**Why this matters:**  
Ensures the preview div is properly exposed to/hidden from screen readers when content appears/disappears.

---

## Summary of Changes

### Files to modify:
1. `app/views/admin/paper_applications/new.html.erb` (4 changes)
2. `app/javascript/controllers/users/document_proof_handler_controller.js` (3 changes)

### Total lines changed: ~7 lines

### Testing:
After applying fixes, verify with:
1. Manual screen reader testing (NVDA on Windows, VoiceOver on Mac)
2. Automated accessibility testing tools (axe DevTools)
3. Check that hidden sections are truly hidden from accessibility tree
4. Verify preview text announces when rejection reasons are selected

### Impact:
- Fixes confusing double-navigation for blind users
- Ensures hidden content is truly hidden from assistive technology
- Provides feedback when rejection preview text appears
- Brings the form into WCAG 2.1 AA compliance
