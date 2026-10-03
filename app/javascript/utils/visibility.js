let _legacyWarned = false;

/**
 * Sets visibility and, when requested, the required and aria-hidden attributes.
 * @param {HTMLElement} element - The element to show/hide
 * @param {boolean} visible - Whether the element should be visible
 * @param {Object} options - Additional options
 * @param {boolean} options.required - Sets required only when true and visible. False removes required.
 * @param {string} options.hiddenClass - CSS class for hiding (default: 'hidden')
 * @param {boolean} options.ariaHidden - The aria-hidden value, independent of visibility
 * @param {boolean} options.inlineStyleFallback - Whether to use inline display fallback (default: true)
 * @returns {HTMLElement|null} The element, or null if it is absent
 */
export function setVisible(element, visible, options = {}) {
  if (!element) {
    console.warn('setVisible: element is null/undefined');
    return null;
  }

  if (!(element instanceof HTMLElement)) {
    console.warn('setVisible: expected HTMLElement, got', element);
    return element;
  }

  const { required, hiddenClass = 'hidden', ariaHidden, inlineStyleFallback = true } = options;

  if (visible) {
    element.classList.remove(hiddenClass);
    // An inline display:none overrides CSS classes.
    if (inlineStyleFallback && element.style.display === 'none') {
      element.style.display = '';
    }
  } else {
    element.classList.add(hiddenClass);
    // The inline style hides sections before CSS loads.
    if (inlineStyleFallback) {
      element.style.display = 'none';
    }
  }

  if (required !== undefined) {
    if (required && visible) {
      element.setAttribute('required', 'required');
    } else {
      element.removeAttribute('required');
    }
  }

  if (ariaHidden !== undefined) {
    element.setAttribute('aria-hidden', ariaHidden.toString());
  }

  return element;
}

/**
 * Adapts the legacy shouldHide argument to setVisible.
 * @deprecated Use setVisible() instead
 * @param {HTMLElement} element - The element to toggle
 * @param {boolean} shouldHide - Whether the element should be hidden
 * @param {Object} options - Additional options
 * @returns {HTMLElement|null} The element, or null if it is absent
 */
export function legacyToggleHidden(element, shouldHide, options = {}) {
  if (!_legacyWarned) {
    const caller = new Error().stack.split("\n")[2] || "";
    console.warn(
      "legacyToggleHidden is deprecated. Use setVisible() instead.",
      caller
    );
    _legacyWarned = true;
  }

  return setVisible(element, !shouldHide, options);
}

/**
 * @param {HTMLElement} element - The element to show
 * @param {Object} options - Additional options
 * @returns {HTMLElement|null} The element, or null if it is absent
 */
export function show(element, options = {}) {
  return setVisible(element, true, options);
}

/**
 * @param {HTMLElement} element - The element to hide
 * @param {Object} options - Additional options
 * @returns {HTMLElement|null} The element, or null if it is absent
 */
export function hide(element, options = {}) {
  return setVisible(element, false, options);
}

/**
 * @param {HTMLElement} element - The element to toggle
 * @param {Object} options - Additional options
 * @returns {HTMLElement|null} The element, or null if it is absent
 */
export function toggle(element, options = {}) {
  if (!element) {
    console.warn('toggle: element is null/undefined');
    return null;
  }

  const { hiddenClass = 'hidden' } = options;
  const isCurrentlyHidden = element.classList.contains(hiddenClass);

  return setVisible(element, isCurrentlyHidden, options);
}

/**
 * Sets an empty field and emits input and change events.
 * @param {string} selector - CSS selector for the field
 * @param {*} value - Value to set
 * @returns {boolean} true if the field is empty and the value is not null or undefined
 */
export function setFieldIfEmpty(selector, value) {
  const el = document.querySelector(selector)
  if (!el || value === undefined || value === null) return false
  if (el.value !== '' && el.value !== null) return false

  el.value = value ?? ''
  el.dispatchEvent(new Event('input', { bubbles: true }))
  el.dispatchEvent(new Event('change', { bubbles: true }))
  return true
}

/**
 * Sets a field and emits input and change events.
 * @param {string} selector - CSS selector for the field
 * @param {*} value - Value to set
 * @returns {boolean} true if the field exists and the value is not null or undefined
 */
export function setFieldValue(selector, value) {
  const el = document.querySelector(selector)
  if (!el || value === undefined || value === null) return false

  el.value = value ?? ''
  el.dispatchEvent(new Event('input', { bubbles: true }))
  el.dispatchEvent(new Event('change', { bubbles: true }))
  return true
}

/**
 * @private Only for testing
 */
export function _resetLegacyWarnings() {
  _legacyWarned = false;
}
