import { Controller } from "@hotwired/stimulus"
import { setVisible, setFieldValue } from "../../utils/visibility"
import { debouncedDispatch } from "../../utils/debounce"

// Same bound as the identity preflight, for the same reason. While this lookup is pending the paper
// form has disabled every candidate button and is still blocking Submit, so a request that never
// settles traps a completed application -- including four selected files a reload would discard --
// with no way forward at all.
const ELIGIBILITY_TIMEOUT_MS = 15000

// Manages adult applicant search-and-select for paper applications.
// Mirrors guardian_picker_controller pattern but adds contact mode switching,
// on-file data tracking, and changed-field highlighting.
export default class extends Controller {
  static targets = [
    "searchPane",
    "selectedPane",
    "selectedHeading",
    "constituentIdField",
    "selectedAdultDisplay",
    "displaySelection",
    "onFileSummary",
    "onFileSummaryContent",
    "incomeCopyButton",
    "medicalCopyButton",
    "contactModeRadio",
    "verificationCheckbox",
    "verificationSection",
    "contactModeSection"
  ]

  connect() {
    this.selectedValue = !!(this.hasConstituentIdFieldTarget && this.constituentIdFieldTarget.value)
    this._adultApplicationContext = null
    this._onFileData = {}
    // Set by the server when it re-renders the form after a failed submission. On that render the
    // fields already hold what staff typed, including corrections to the on-file record, so the
    // context fetch below must not paste database values back over them.
    this._restoredFromSubmission = this.element.dataset.adultPickerRestoredValue === "true"
    this.togglePanes()

    if (this.selectedValue) {
      this.fetchAdultContext(this.constituentIdFieldTarget.value)
    }
  }

  /* Public API ----------------------------------------------------------- */

  selectAdult(id, displayHTML, _userData) {
    if (this.hasConstituentIdFieldTarget) this.constituentIdFieldTarget.value = id

    const box = this.selectedPaneTarget.querySelector(".adult-details-container")
    if (box) box.innerHTML = displayHTML

    this.selectedValue = true
    this.togglePanes()
    this.fetchAdultContext(id)
    this.dispatchSelectionChange()
  }

  /**
   * Selection entry point for the paper identity review.
   *
   * Deliberately not `selectAdult`, for two reasons. That method takes display *markup* and writes
   * it with innerHTML, and these values are names and addresses that arrived as JSON. And it selects
   * unconditionally, whereas a candidate surfaced by an identity review may be ineligible -- an
   * active application, or inside the waiting period -- in which case it must be left unselected
   * with the reason reported rather than quietly chosen.
   *
   * @param {{id: number, name: string, date_of_birth: string}} candidate
   * @returns {Promise<{selected: boolean, reason?: string}>}
   */
  async selectAdultFromIdentityReview(candidate, { signal } = {}) {
    if (!candidate || !candidate.id) return { selected: false, reason: 'That record could not be selected.' }

    const outcome = await this.fetchAdultEligibility(candidate.id, { signal })
    // Aborted while the answer was in flight: staff have moved on, so nothing may be selected and
    // nothing may be said about it. Checked first, because an abort is not a failure to report.
    if (outcome.reason === 'aborted' || (signal && signal.aborted)) return { selected: false }
    if (!outcome.ok) return { selected: false, reason: this._lookupFailureReason(outcome.reason) }

    const context = outcome.context
    // Fails closed. An earlier version refused only an explicit `false`, so a response missing the
    // field entirely -- a shape change, a partial payload -- was treated as eligible.
    if (context.eligible_now !== true) {
      return { selected: false, reason: this._ineligibleReason(context) }
    }

    // The context is applied from the response already in hand rather than started again and left
    // running. A second unawaited fetch would announce the selection before the verification
    // control existed, and submit gating would conclude verification was unnecessary -- or, if that
    // fetch failed, leave a half-selected record with no verification UI at all.
    this._applyAdultContext(context)

    if (this.hasConstituentIdFieldTarget) this.constituentIdFieldTarget.value = candidate.id
    this._renderSelectedCandidate(candidate)

    this.selectedValue = true
    this.togglePanes()
    // Announced only once the contact mode and verification controls are actually in place.
    this.dispatchSelectionChange()

    // The button that had focus was inside the review panel, which selecting has just torn down.
    // Without this, focus falls back to <body>: a keyboard or screen-reader user is returned to the
    // top of a long form with no indication that anything happened, and the contact-verification
    // step they now have to complete is somewhere below them. Moved after togglePanes, because a
    // hidden element cannot take focus.
    this._focusSelectionOutcome()

    return { selected: true }
  }

  /** @private */
  _focusSelectionOutcome() {
    const destination = this.hasSelectedHeadingTarget ? this.selectedHeadingTarget : this.selectedPaneTarget
    if (destination && typeof destination.focus === "function") destination.focus()
  }

  /**
   * Bounded and session-aware, matching the identity preflight's contract, because this lookup sits
   * inside the same trap: the form is gated while it runs.
   *
   * Returns a discriminated outcome rather than a context-or-null. Collapsing every failure into
   * null made an expired session indistinguishable from a transient error, so staff were told to
   * "try again" when trying again is exactly what cannot work.
   *
   * @private
   * @returns {Promise<{ok: true, context: object}|{ok: false, reason: string}>}
   */
  async fetchAdultEligibility(userId, { signal } = {}) {
    if (signal && signal.aborted) return { ok: false, reason: 'aborted' }

    // One controller for both ways this can stop early, so the fetch has a single signal.
    const controller = new AbortController()
    const abortFromCaller = () => controller.abort()
    if (signal) signal.addEventListener('abort', abortFromCaller, { once: true })

    let timedOut = false
    const timer = setTimeout(() => { timedOut = true; controller.abort() }, ELIGIBILITY_TIMEOUT_MS)

    try {
      const response = await fetch(`/admin/users/${userId}/adult_application_context`, {
        headers: { Accept: 'application/json' },
        credentials: 'same-origin',
        signal: controller.signal
      })

      // The server answers an unauthenticated JSON request with 401; `redirected` covers a caller
      // or intermediary that redirects to sign-in anyway.
      if (response.status === 401 || response.redirected) return { ok: false, reason: 'session_expired' }
      if (!response.ok) return { ok: false, reason: 'error' }

      const data = await response.json()
      if (!data || data.success !== true) return { ok: false, reason: 'error' }

      return { ok: true, context: data }
    } catch (e) {
      if (timedOut) return { ok: false, reason: 'timed_out' }
      if (e && e.name === 'AbortError') return { ok: false, reason: 'aborted' }
      console.warn('fetchAdultEligibility failed', e)
      return { ok: false, reason: 'error' }
    } finally {
      clearTimeout(timer)
      if (signal) signal.removeEventListener('abort', abortFromCaller)
    }
  }

  /**
   * Each failure gets the recovery that actually applies to it.
   * @private
   */
  _lookupFailureReason(reason) {
    switch (reason) {
      case 'session_expired':
        return 'Your session has expired. Sign in again in another browser tab, then try again ' +
               'here. Your entries and selected documents stay on this page.'
      case 'timed_out':
        return 'Checking that record took too long. Try again.'
      default:
        return 'That record could not be checked right now. Try again.'
    }
  }

  /**
   * Reads the explicit reason the server sends rather than inferring one from a date. The payload
   * carries `ineligibility_reason` ('active_application' or 'waiting_period') and, for the waiting
   * period only, `eligible_after` -- an earlier version read a non-existent `eligible_date`, so
   * every waiting-period candidate was described as having an active application.
   * @private
   */
  _ineligibleReason(context) {
    if (context.ineligibility_reason === 'waiting_period') {
      const date = this._formatEligibleAfter(context.eligible_after)
      return date
        ? `That constituent is within the waiting period and is not eligible for a new application until ${date}.`
        : 'That constituent is within the waiting period and is not yet eligible for a new application.'
    }
    if (context.ineligibility_reason === 'active_application') {
      return 'That constituent already has an active application and cannot start another.'
    }
    return 'That constituent is not eligible for a new application.'
  }

  /**
   * `eligible_after` is a calendar date, not an instant. `new Date('2027-04-02')` parses as UTC
   * midnight, which in any western timezone renders as the *previous* day -- telling staff a
   * constituent is eligible a day earlier than they are. Formatted in UTC so the date shown is the
   * date the server sent.
   * @private
   */
  _formatEligibleAfter(value) {
    if (!value) return null

    const parsed = new Date(value)
    if (Number.isNaN(parsed.getTime())) return String(value)

    return parsed.toLocaleDateString(undefined, {
      year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC'
    })
  }

  /**
   * Text nodes rather than markup: these values came from JSON and are rendered as data.
   * @private
   */
  _renderSelectedCandidate(candidate) {
    const box = this.selectedPaneTarget.querySelector('.adult-details-container')
    if (!box) return

    box.replaceChildren()
    const name = document.createElement('div')
    name.className = 'font-medium'
    name.textContent = String(candidate.name || '')
    box.appendChild(name)

    if (candidate.date_of_birth) {
      const dob = document.createElement('div')
      dob.className = 'text-sm text-gray-600'
      dob.textContent = String(candidate.date_of_birth)
      box.appendChild(dob)
    }
  }

  clearSelection({ dispatch = true } = {}) {
    if (this.hasConstituentIdFieldTarget) this.constituentIdFieldTarget.value = ""

    this._onFileData = {}
    this._adultApplicationContext = null
    this.selectedValue = false
    this.togglePanes()
    this._clearPrefillFields()
    this._hideOnFileSummary()
    this._hideContactMode()
    this._hideVerification()
    this._resetContactMode()
    if (dispatch) this.dispatchSelectionChange()
  }

  createNewApplicant() {
    this.clearSelection({ dispatch: false })
    this.dispatch("createNew", { detail: { createNew: true } })
  }

  /* Contact mode switching ----------------------------------------------- */

  contactModeChanged(event) {
    const mode = event.target.value
    const contactFields = this._getContactFieldElements()

    if (mode === "on_file") {
      // Lock contact fields to on-file values
      contactFields.forEach(el => {
        const key = this._fieldKey(el)
        if (key && this._onFileData[key] !== undefined) {
          el.value = this._onFileData[key] || ""
        }
        el.readOnly = true
        el.classList.add("bg-gray-100", "text-gray-500")
      })
      this._lockRadioGroups(true)
    } else {
      // Unlock fields for editing
      contactFields.forEach(el => {
        el.readOnly = false
        el.classList.remove("bg-gray-100", "text-gray-500")
      })
      this._lockRadioGroups(false)
    }
  }

  verificationChanged(event) {
    this.dispatch("verificationChange", { detail: { verified: event.target.checked } })
  }

  /* Data fetching -------------------------------------------------------- */

  async fetchAdultContext(userId) {
    try {
      const response = await fetch(`/admin/users/${userId}/adult_application_context`, {
        headers: { 'Accept': 'application/json' },
        credentials: 'same-origin'
      })
      if (!response.ok) return

      const data = await response.json()
      if (!data.success) return

      this._applyAdultContext(data)
    } catch (e) {
      console.warn('fetchAdultContext failed', e)
    }
  }

  /**
   * Installs everything a selected adult needs: on-file summary, contact mode, and the verification
   * control submit gating depends on. Shared by the search-driven path and the identity-review path
   * so a selection can never be announced with only some of it in place.
   * @private
   */
  _applyAdultContext(data) {
    this._adultApplicationContext = data
    this._storeOnFileData(data.user)
    // Everything else here is still needed on a retry -- the on-file summary, contact mode,
    // verification control and submit gating all depend on it. Only the field overwrite is skipped,
    // because on a retry the submitted values are the newer ones and silently replacing them with
    // what is on file loses a correction staff had already made once.
    if (!this._restoredFromSubmission) this._autopopulateFields(data.user)
    this._showOnFileSummary(data)
    this._showContactMode()
    this._showVerification()
    this._applyCurrentContactMode()
    this._toggleCopyButtons(data)
  }

  useLastApplicationIncomeInfo() {
    const data = this._adultApplicationContext
    if (!data) return

    setFieldValue('input[name="application[household_size]"]', data.household_size)
    setFieldValue('input[name="application[annual_income]"]', data.annual_income)
  }

  useLastApplicationMedicalProvider() {
    const data = this._adultApplicationContext
    if (!data) return

    setFieldValue('input[name="application[medical_provider_name]"]', data.medical_provider_name)
    setFieldValue('input[name="application[medical_provider_phone]"]', data.medical_provider_phone)
    setFieldValue('input[name="application[medical_provider_fax]"]', data.medical_provider_fax)
    setFieldValue('input[name="application[medical_provider_email]"]', data.medical_provider_email)
  }

  /* Highlight changes before submit -------------------------------------- */

  highlightChanges() {
    const contactFields = this._getContactFieldElements()
    contactFields.forEach(el => {
      const key = this._fieldKey(el)
      if (!key || this._onFileData[key] === undefined) return

      const changed = el.value !== (this._onFileData[key] || "")
      el.classList.toggle("border-l-4", changed)
      el.classList.toggle("border-amber-400", changed)
      el.classList.toggle("pl-2", changed)
    })
  }

  /* Internal helpers ----------------------------------------------------- */

  togglePanes() {
    const hideSearch = this.selectedValue
    if (this.hasSearchPaneTarget) setVisible(this.searchPaneTarget, !hideSearch)
    if (this.hasSelectedPaneTarget) setVisible(this.selectedPaneTarget, hideSearch)
  }

  _storeOnFileData(user) {
    if (!user) return
    this._onFileData = {
      email: user.email || "",
      phone: user.phone || "",
      phone_type: user.phone_type || "",
      physical_address_1: user.physical_address_1 || "",
      physical_address_2: user.physical_address_2 || "",
      city: user.city || "",
      state: user.state || "",
      zip_code: user.zip_code || "",
      communication_preference: user.communication_preference || "",
      preferred_means_of_communication: user.preferred_means_of_communication || "",
      locale: user.locale || ""
    }
  }

  _autopopulateFields(user) {
    if (!user) return

    const fieldMap = {
      'constituent[first_name]': user.first_name,
      'constituent[middle_initial]': user.middle_initial,
      'constituent[last_name]': user.last_name,
      'constituent[date_of_birth]': this._formatDateForInput(user.date_of_birth),
      'constituent[email]': user.email,
      'constituent[phone]': user.phone,
      'constituent[physical_address_1]': user.physical_address_1,
      'constituent[physical_address_2]': user.physical_address_2,
      'constituent[city]': user.city,
      'constituent[state]': user.state,
      'constituent[zip_code]': user.zip_code,
      'constituent[locale]': user.locale,
      'constituent[preferred_means_of_communication]': user.preferred_means_of_communication,
      'constituent[referral_source]': user.referral_source
    }

    Object.entries(fieldMap).forEach(([name, value]) => {
      if (value === undefined || value === null) return
      const el = document.querySelector(`[name="${name}"]`)
      if (!el) return
      el.value = value
      el.dispatchEvent(new Event('input', { bubbles: true }))
      el.dispatchEvent(new Event('change', { bubbles: true }))
    })

    // Handle radio buttons for phone_type
    if (user.phone_type) {
      const radio = document.querySelector(`input[name="constituent[phone_type]"][value="${user.phone_type}"]`)
      if (radio) {
        radio.checked = true
        radio.dispatchEvent(new Event('change', { bubbles: true }))
      }
    }

    // Handle radio buttons for communication_preference
    if (user.communication_preference) {
      const radio = document.querySelector(`input[name="constituent[communication_preference]"][value="${user.communication_preference}"]`)
      if (radio) {
        radio.checked = true
        radio.dispatchEvent(new Event('change', { bubbles: true }))
      }
    }
  }

  _showOnFileSummary(data) {
    if (!this.hasOnFileSummaryTarget) return
    setVisible(this.onFileSummaryTarget, true)

    if (this.hasOnFileSummaryContentTarget) {
      const u = data.user
      const products = data.product_names?.length ? data.product_names.join(', ') : 'No product on file'
      const lastDate = data.last_application_date
        ? new Date(data.last_application_date).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
        : 'None'

      const address = [u.physical_address_1, u.city, u.state].filter(Boolean).join(', ')
        + (u.zip_code ? ` ${u.zip_code}` : '')

      const rows = [
        ['Name', `${u.first_name || ''} ${u.last_name || ''}`],
        ['DOB', this._formatDateForInput(u.date_of_birth) || 'N/A'],
        ['Email', u.email || 'N/A'],
        ['Phone', u.phone || 'N/A'],
        ['Address', address || 'N/A'],
        ['Last App', lastDate],
        ['Products', products]
      ]

      const grid = document.createElement('div')
      grid.className = 'grid grid-cols-2 gap-x-4 gap-y-1 text-sm'
      rows.forEach(([label, value], _i) => {
        const cell = document.createElement('div')
        if (label === 'Address') cell.className = 'col-span-2'
        const bold = document.createElement('span')
        bold.className = 'font-medium text-gray-700'
        bold.textContent = `${label}: `
        cell.appendChild(bold)
        cell.appendChild(document.createTextNode(value))
        grid.appendChild(cell)
      })
      this.onFileSummaryContentTarget.replaceChildren(grid)
    }
  }

  _formatDateForInput(value) {
    if (!value) return ""
    const match = String(value).match(/^(\d{4})-(\d{2})-(\d{2})$/)
    if (!match) return value

    return `${match[2]}/${match[3]}/${match[1]}`
  }

  _hideOnFileSummary() {
    if (this.hasOnFileSummaryTarget) setVisible(this.onFileSummaryTarget, false)
    this._toggleCopyButtons()
  }

  _showContactMode() {
    if (!this.hasContactModeSectionTarget) return

    setVisible(this.contactModeSectionTarget, true)
    this._toggleSectionFieldsDisabled(this.contactModeSectionTarget, false)
  }

  _hideContactMode() {
    if (!this.hasContactModeSectionTarget) return

    setVisible(this.contactModeSectionTarget, false)
    this._toggleSectionFieldsDisabled(this.contactModeSectionTarget, true)
  }

  _showVerification() {
    if (!this.hasVerificationSectionTarget) return

    setVisible(this.verificationSectionTarget, true)
    this._toggleSectionFieldsDisabled(this.verificationSectionTarget, false)
  }

  _hideVerification() {
    if (this.hasVerificationSectionTarget) {
      setVisible(this.verificationSectionTarget, false)
      this._toggleSectionFieldsDisabled(this.verificationSectionTarget, true)
    }
    if (this.hasVerificationCheckboxTarget) this.verificationCheckboxTarget.checked = false
  }

  _resetContactMode() {
    if (!this.hasContactModeRadioTarget) return
    this.contactModeRadioTargets.forEach(radio => {
      radio.checked = radio.value === "update"
    })
    // Ensure fields are unlocked
    this._getContactFieldElements().forEach(el => {
      el.readOnly = false
      el.classList.remove("bg-gray-100", "text-gray-500")
    })
    this._lockRadioGroups(false)
  }

  _applyCurrentContactMode() {
    const selectedMode = this.contactModeRadioTargets.find(radio => radio.checked) || this.contactModeRadioTargets[0]
    if (selectedMode) this.contactModeChanged({ target: selectedMode })
  }

  _toggleCopyButtons(data = null) {
    const context = data || this._adultApplicationContext
    const hasIncomeData = !!(context && (context.household_size || context.annual_income))
    const hasMedicalProviderData = !!(context && (
      context.medical_provider_name ||
      context.medical_provider_phone ||
      context.medical_provider_fax ||
      context.medical_provider_email
    ))

    if (this.hasIncomeCopyButtonTarget) setVisible(this.incomeCopyButtonTarget, hasIncomeData)
    if (this.hasMedicalCopyButtonTarget) setVisible(this.medicalCopyButtonTarget, hasMedicalProviderData)
  }

  _toggleSectionFieldsDisabled(section, disabled) {
    const fields = section?.querySelectorAll('input, select, textarea')
    if (!fields) return

    fields.forEach(field => {
      field.disabled = disabled
    })
  }

  _clearPrefillFields() {
    const fields = [
      'constituent[first_name]', 'constituent[middle_initial]', 'constituent[last_name]',
      'constituent[date_of_birth]', 'constituent[email]', 'constituent[phone]',
      'constituent[physical_address_1]', 'constituent[physical_address_2]',
      'constituent[city]', 'constituent[state]', 'constituent[zip_code]',
      'constituent[locale]', 'constituent[preferred_means_of_communication]',
      'constituent[referral_source]'
    ]

    fields.forEach(name => {
      const el = document.querySelector(`[name="${name}"]`)
      if (el) {
        el.value = ''
        el.readOnly = false
        el.classList.remove("bg-gray-100", "text-gray-500", "border-l-4", "border-amber-400", "pl-2")
      }
    })

    // Reset radio buttons
    ;['constituent[phone_type]', 'constituent[communication_preference]'].forEach(name => {
      document.querySelectorAll(`input[name="${name}"]`).forEach(radio => {
        radio.checked = false
        radio.disabled = false
      })
    })

    // Reset state field default
    const stateEl = document.querySelector('[name="constituent[state]"]')
    if (stateEl) stateEl.value = 'MD'
  }

  _getContactFieldElements() {
    const contactFieldNames = [
      'constituent[email]', 'constituent[phone]',
      'constituent[physical_address_1]', 'constituent[physical_address_2]',
      'constituent[city]', 'constituent[state]', 'constituent[zip_code]',
      'constituent[locale]', 'constituent[preferred_means_of_communication]'
    ]
    return contactFieldNames
      .map(name => document.querySelector(`[name="${name}"]`))
      .filter(Boolean)
  }

  _lockRadioGroups(lock) {
    ;['constituent[phone_type]', 'constituent[communication_preference]'].forEach(name => {
      document.querySelectorAll(`input[name="${name}"]`).forEach(radio => {
        radio.disabled = lock
      })
    })
  }

  _fieldKey(el) {
    const match = el.name?.match(/constituent\[(\w+)\]/)
    return match ? match[1] : null
  }

  dispatchSelectionChange() {
    debouncedDispatch(this, "selectionChange", { selectedValue: this.selectedValue })
  }
}
