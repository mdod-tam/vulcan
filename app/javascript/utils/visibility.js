/**
 * Visibility Utility
 * 
 * Provides centralized functions for managing element visibility and required attributes.
 * Replaces repetitive classList.toggle + setAttribute/removeAttribute patterns.
 */

let _legacyWarned = false;

/**
 * Sets element visibility and optionally manages required attribute
 * @param {HTMLElement} element - The element to show/hide
 * @param {boolean} visible - Whether the element should be visible
 * @param {Object} options - Additional options
 * @param {boolean} options.required - Whether to set/remove required attribute
 * @param {string} options.hiddenClass - CSS class for hiding (default: 'hidden')
 * @param {boolean} options.ariaHidden - Whether to set aria-hidden attribute
 * @returns {HTMLElement|null} The element for chaining, or null if invalid
 */
export function setVisible(element, visible, options = {}) {
  if (!element) {
    console.warn('setVisible: element is null/undefined');
    return null;
  }

  // Type check for HTMLElement
  if (!(element instanceof HTMLElement)) {
    console.warn('setVisible: expected HTMLElement, got', element);
    return element;
  }

  const { required, hiddenClass = 'hidden', ariaHidden } = options;

  // Toggle visibility - let CSS handle it to maintain screen reader accessibility
  if (visible) {
    element.classList.remove(hiddenClass);
    // Remove inline display that might override CSS classes
    if (element.style.display) {
      element.style.display = '';
    }
  } else {
    element.classList.add(hiddenClass);
    // Don't set inline display:none - let CSS handle it
    // This ensures screen readers can still access content if needed
  }

  // Handle required attribute if specified
  if (required !== undefined) {
    if (required && visible) {
      element.setAttribute('required', 'required');
    } else {
      element.removeAttribute('required');
    }
  }

  // Handle aria-hidden attribute if specified
  if (ariaHidden !== undefined) {
    element.setAttribute('aria-hidden', ariaHidden.toString());
  }

  return element;
}

/**
 * Legacy wrapper for gradual migration from old toggle patterns
 * @deprecated Use setVisible() instead
 * @param {HTMLElement} element - The element to toggle
 * @param {boolean} shouldHide - Whether the element should be hidden
 * @param {Object} options - Additional options
 * @returns {HTMLElement|null} The element for chaining, or null if invalid
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
 * Show an element and optionally make it required
 * @param {HTMLElement} element - The element to show
 * @param {Object} options - Additional options
 * @returns {HTMLElement|null} The element for chaining, or null if invalid
 */
export function show(element, options = {}) {
  return setVisible(element, true, options);
}

/**
 * Hide an element and optionally remove required attribute
 * @param {HTMLElement} element - The element to hide
 * @param {Object} options - Additional options
 * @returns {HTMLElement|null} The element for chaining, or null if invalid
 */
export function hide(element, options = {}) {
  return setVisible(element, false, options);
}

/**
 * Toggle element visibility
 * @param {HTMLElement} element - The element to toggle
 * @param {Object} options - Additional options
 * @returns {HTMLElement|null} The element for chaining, or null if invalid
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
 * Test helper to reset deprecation warning state
 * @private Only for testing
 */
export function _resetLegacyWarnings() {
  _legacyWarned = false;
}
