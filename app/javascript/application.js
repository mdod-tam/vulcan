// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import * as ActiveStorage from "@rails/activestorage"
import * as WebAuthnJSON from "@github/webauthn-json"
import Auth from "./auth"
// Toast notifications removed in favor of native Rails flash messages

// Chart.js setup following official documentation
// Tree-shaken imports for production optimization
import {
  Chart,
  BarController,
  LineController,
  PolarAreaController,
  DoughnutController,
  RadarController,
  BarElement,
  LineElement,
  PointElement,
  ArcElement,
  CategoryScale,
  LinearScale,
  RadialLinearScale,
  Title,
  Tooltip,
  Legend
} from 'chart.js'

// Register required components per Chart.js docs
Chart.register(
  BarController,
  LineController,
  PolarAreaController,
  DoughnutController,
  RadarController,
  BarElement,
  LineElement,
  PointElement,
  ArcElement,
  CategoryScale,
  LinearScale,
  RadialLinearScale,
  Title,
  Tooltip,
  Legend
)

// Minimal configuration - disable responsive to prevent DOM calculation recursion
Chart.defaults.animation = false
Chart.defaults.responsive = false
Chart.defaults.maintainAspectRatio = false

// Override getComputedStyle to prevent infinite recursion in Chart.js (enabled globally)
// Note: The depth counter is safe because JavaScript is single-threaded and getComputedStyle
// is synchronous. Recursive calls increment/decrement atomically with no async interleaving.
if (!window._getComputedStylePatched) {
  const originalGetComputedStyle = window.getComputedStyle
  let depth = 0
  const MAX_RECURSION_DEPTH = 50

  // Comprehensive stub implementing CSSStyleDeclaration interface
  // Used as fallback when max recursion depth is exceeded to prevent stack overflow
  const createStubStyle = () => {
    const defaults = {
      display: 'block',
      visibility: 'visible',
      position: 'static',
      width: '0px',
      height: '0px',
      minWidth: '0px',
      minHeight: '0px',
      maxWidth: 'none',
      maxHeight: 'none',
      top: 'auto',
      right: 'auto',
      bottom: 'auto',
      left: 'auto',
      margin: '0px',
      marginTop: '0px',
      marginRight: '0px',
      marginBottom: '0px',
      marginLeft: '0px',
      padding: '0px',
      paddingTop: '0px',
      paddingRight: '0px',
      paddingBottom: '0px',
      paddingLeft: '0px',
      border: '0px none rgb(0, 0, 0)',
      borderWidth: '0px',
      borderStyle: 'none',
      borderColor: 'rgb(0, 0, 0)',
      fontSize: '16px',
      fontFamily: 'sans-serif',
      fontWeight: '400',
      fontStyle: 'normal',
      lineHeight: 'normal',
      color: 'rgb(0, 0, 0)',
      backgroundColor: 'rgba(0, 0, 0, 0)',
      opacity: '1',
      overflow: 'visible',
      overflowX: 'visible',
      overflowY: 'visible',
      boxSizing: 'content-box',
      zIndex: 'auto',
      transform: 'none',
      transition: 'none',
      textAlign: 'start',
      verticalAlign: 'baseline',
      float: 'none',
      clear: 'none'
    }

    // Convert camelCase to kebab-case for property lookup
    const toKebab = (str) => str.replace(/([A-Z])/g, '-$1').toLowerCase()
    // Convert kebab-case to camelCase for property lookup
    const toCamel = (str) => str.replace(/-([a-z])/g, (_, c) => c.toUpperCase())

    // Build kebab-case lookup map
    const kebabDefaults = {}
    for (const key of Object.keys(defaults)) {
      kebabDefaults[toKebab(key)] = defaults[key]
    }

    const keys = Object.keys(defaults)

    return {
      ...defaults,
      getPropertyValue(property) {
        const camelKey = toCamel(property)
        return defaults[camelKey] ?? kebabDefaults[property] ?? ''
      },
      getPropertyPriority() {
        return ''
      },
      item(index) {
        return keys[index] ?? ''
      },
      length: keys.length,
      [Symbol.iterator]() {
        return keys[Symbol.iterator]()
      }
    }
  }

  window.getComputedStyle = function (element, pseudoElement) {
    if (depth > MAX_RECURSION_DEPTH) {
      if (process.env?.NODE_ENV !== 'production') {
        console.warn('[Chart.js recursion guard] Max depth exceeded, returning stub styles')
      }
      return createStubStyle()
    }

    depth += 1
    try {
      return originalGetComputedStyle.call(window, element, pseudoElement)
    } finally {
      depth -= 1
    }
  }

  window._getComputedStylePatched = true
}

// Make Chart available globally for controllers
window.Chart = Chart

import "./controllers"

// Make WebAuthnJSON and Auth available globally if needed for debugging, or remove if not
window.WebAuthnJSON = WebAuthnJSON
window.Auth = Auth

if (process.env?.NODE_ENV !== 'production') {
  console.log("Application.js loaded - Chart.js enabled")
}

ActiveStorage.start()
