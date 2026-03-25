import { Controller } from "@hotwired/stimulus"
import { setVisible, setFieldValue } from "../../utils/visibility"
import { debouncedDispatch } from "../../utils/debounce"

// Manages adult applicant search-and-select for paper applications.
// Mirrors guardian_picker_controller pattern but adds contact mode switching,
// on-file data tracking, and changed-field highlighting.
export default class extends Controller {
  static targets = [
    "searchPane",
    "selectedPane",
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

  clearSelection() {
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
    this.dispatchSelectionChange()
  }

  createNewApplicant() {
    this.clearSelection()
    // Dispatch event so applicant-type controller can show the adult info section
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

      this._adultApplicationContext = data
      this._storeOnFileData(data.user)
      this._autopopulateFields(data.user)
      this._showOnFileSummary(data)
      this._showContactMode()
      this._showVerification()
      this._applyCurrentContactMode()
      this._toggleCopyButtons(data)
    } catch (e) {
      console.warn('fetchAdultContext failed', e)
    }
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
      'constituent[date_of_birth]': user.date_of_birth,
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
        ['DOB', u.date_of_birth || 'N/A'],
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
