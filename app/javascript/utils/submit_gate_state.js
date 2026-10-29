// Submit-gate primitives shared by the forms that hold their primary submit button disabled
// until every visible, enabled requirement is satisfied. paper_application_controller and
// final_submit_gate_controller compose this module the way they compose documentUploadBlocker:
// each caller injects its visibility rule, so tests can bypass layout-dependent visibility.

const REQUIRED_CONTROL_SELECTOR =
  'input[required]:not([type="radio"]):not([type="hidden"]):not([type="submit"]):not([type="button"]):not([type="reset"]), select[required], textarea[required]'

export function elementIsVisible(element) {
  return !!(element.offsetParent || element.getClientRects().length)
}

function enabledVisibleFields(root, selector, isVisible = elementIsVisible) {
  return Array.from(root.querySelectorAll(selector))
    .filter((field) => !field.disabled && isVisible(field))
}

function fieldInvalid(field) {
  if ((field.type || "").toLowerCase() === "file") {
    return field.required && (!field.files || field.files.length === 0)
  }

  if (typeof field.checkValidity === "function") {
    return !field.checkValidity()
  }

  return String(field.value || "").trim() === ""
}

export function blockingRequiredControls(root, isVisible = elementIsVisible) {
  return enabledVisibleFields(root, REQUIRED_CONTROL_SELECTOR, isVisible)
    .filter((field) => fieldInvalid(field))
}

export function blockingRadioGroups(root, isVisible = elementIsVisible) {
  const radios = enabledVisibleFields(root, 'input[type="radio"][required]', isVisible)
  const names = [...new Set(radios.map((radio) => radio.name).filter(Boolean))]

  return names
    .map((name) => radios.filter((radio) => radio.name === name))
    .filter((group) => group.length > 0 && !group.some((radio) => radio.checked))
}

export function blockingCheckboxGroups(root, isVisible = elementIsVisible) {
  return Array.from(root.querySelectorAll("[data-requires-one-checkbox]"))
    .filter((group) => isVisible(group))
    .filter((group) => {
      const checkboxes = Array.from(group.querySelectorAll('input[type="checkbox"]'))
        .filter((field) => !field.disabled && isVisible(field))
      return checkboxes.length > 0 && !checkboxes.some((field) => field.checked)
    })
}

// Label text collapses to single spaces so a multi-part label renders as one readable
// sentence instead of the template's raw indentation.
function displayText(text) {
  return text ? text.replace(/\s+/g, " ").trim() : null
}

// The accessible name of a single control: its own label, then an explicit aria-label.
function controlName(element) {
  if (!element) return null

  return displayText(element.labels?.[0]?.textContent) ||
    displayText(element.getAttribute("aria-label")) ||
    element.name || null
}

// A grouped decision is named by its fieldset legend, because a member label names only
// one option ("Hearing" does not explain an entirely unchecked disability-type group).
export function groupLabel(element) {
  if (!element) return null

  return displayText(element.closest("fieldset")?.querySelector(":scope > legend")?.textContent) ||
    controlName(element)
}

// A standalone requirement is named by its own label: that text is the exact outstanding
// item ("I authorize the release and sharing of my disability-related information",
// "Provider Name"), which is what a blocked submitter needs. The legend is only a fallback
// for an unlabeled control.
export function controlLabel(element) {
  return controlName(element) || groupLabel(element)
}

export function incompleteGroupLabels(root, isVisible = elementIsVisible) {
  const labels = [
    ...blockingRequiredControls(root, isVisible).map(controlLabel),
    ...blockingRadioGroups(root, isVisible).map((group) => groupLabel(group[0])),
    ...blockingCheckboxGroups(root, isVisible).map(groupLabel)
  ]
  return [...new Set(labels.filter(Boolean))]
}

// Forms may supply a detail template ("Still needed: %{items}."); without one the base
// message survives untouched so the JavaScript never bypasses a view's message copy.
// Items drop one trailing period so a sentence-punctuated label never double-punctuates
// the rendered list.
export function formatIncompleteMessage(baseMessage, detailTemplate, labels) {
  if (!detailTemplate || labels.length === 0) return baseMessage

  const items = labels.map((label) => label.replace(/\.$/, "")).join(", ")
  return `${baseMessage} ${detailTemplate.replace("%{items}", items)}`
}
