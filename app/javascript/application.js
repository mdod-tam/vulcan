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

// Fixed-size charts: controllers set canvas width/height before init (see ChartBaseController).
// responsive: false skips Chart.js resize/getMaximumSize on init; do not patch getComputedStyle —
// Chart.js calls it for tooltips/hover (getRelativePosition) and a depth guard returns bogus 0x0 stubs.
Chart.defaults.animation = false
Chart.defaults.responsive = false
Chart.defaults.maintainAspectRatio = false

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
