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
if (!window._getComputedStylePatched) {
  const originalGetComputedStyle = window.getComputedStyle
  let depth = 0

  window.getComputedStyle = function (element, pseudoElement) {
    // If we detect deep re-entrancy, return a minimal style object to break the loop
    if (depth > 50) {
      return {
        getPropertyValue: (property) => {
          if (property === 'display') return 'block'
          if (property === 'width') return '0px'
          if (property === 'height') return '0px'
          return ''
        },
        display: 'block',
        width: '0px',
        height: '0px'
      }
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
