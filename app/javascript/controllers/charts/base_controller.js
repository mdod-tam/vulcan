import { Controller } from "@hotwired/stimulus"
import { chartConfig } from "../../services/chart_config"

/**
 * ChartBaseController
 * 
 * Base class for Chart.js controllers that provides common functionality:
 * - Canvas creation with accessibility features
 * - Chart instance cleanup
 * - Error handling
 * - Consistent ARIA labeling
 * - Centralized chart defaults via chart config service
 * - Data validation
 */
class ChartBaseController extends Controller {

  static values = {
    chartHeight: { type: Number, default: 300 }
  }

  connect() {
    this.cleanupExistingChart()
    // Chart.js container positioning is handled by ERB templates
    // Controller only manages chart behavior, not styling

    // Guard: do not attempt to initialize charts in hidden containers
    if (!this.isVisible()) {
      return
    }
  }

  disconnect() {
    this.cleanupExistingChart()
  }

  cleanupExistingChart() {
    if (this.chartInstance) {
      this.chartInstance.destroy()
      this.chartInstance = null
    }
  }

  // Defensive data validation
  validateData(data, context = "chart data") {
    if (!data || typeof data !== "object" || !Object.keys(data).length) {
      this.handleError(`No valid ${context} provided`)
      return false
    }
    return true
  }

  createCanvas(ariaLabel, ariaDesc) {
    const canvas = document.createElement("canvas")

    // With responsive: true, Chart.js handles canvas sizing automatically
    // based on the container's dimensions. Don't set explicit canvas size.
    // The container must have explicit height (set in ERB templates).

    // Add accessibility attributes
    canvas.setAttribute("role", "img")
    canvas.setAttribute("aria-label", ariaLabel)

    // Generate unique ID for aria-describedby with collision prevention
    const baseId = this.element.id || `chart-${Date.now()}`
    const randomSuffix = Math.random().toString(36).substring(2, 6)
    const descId = `chart-desc-${baseId}-${randomSuffix}`
    canvas.setAttribute("aria-describedby", descId)

    // Store for cleanup
    this._descId = descId

    // Create screen reader description
    const desc = document.createElement("p")
    desc.id = descId
    desc.className = "sr-only"
    desc.textContent = ariaDesc

    return { canvas, desc }
  }

  mountCanvas(canvas, desc) {
    // Clear container and mount canvas with description
    this.element.textContent = ""

    // Add fallback content inside canvas for accessibility (Chart.js docs recommendation)
    const fallback = document.createElement("p")
    fallback.textContent = canvas.getAttribute("aria-label") || "Chart data visualization"
    canvas.appendChild(fallback)

    this.element.appendChild(canvas)
    this.element.appendChild(desc)
  }

  getCtx(canvas) {
    try {
      const ctx = canvas.getContext("2d")
      if (!ctx) {
        this.handleError("Canvas context not available")
        return null
      }
      return ctx
    } catch (error) {
      this.handleError("Canvas context failure", error)
      return null
    }
  }

  handleError(msg, err) {
    console.error(msg, err || "Unknown error")
    console.error(`Chart Error: ${msg}`)
    this._showMessage("text-red-500", `Unable to load chart – ${msg}`)
  }

  handleUnavailable() {
    console.warn("Chart.js not available, skipping chart initialization")
    console.warn("Chart unavailable: Chart.js not loaded.")
    this._showMessage("text-gray-500", "Chart unavailable")
  }

  // Simple visibility check used to avoid layout-measure loops
  isVisible() {
    return this.element && this.element.offsetParent !== null
  }

  _showMessage(colorClass, text) {
    // Clear container without wiping out attached controllers
    this.element.textContent = ""

    const div = document.createElement("div")
    div.className = `${colorClass} text-center p-4`
    div.textContent = text

    this.element.appendChild(div)
  }

  // Helper method to get Chart.js with global instance (ensures patches apply)
  getChart() {
    // Use globally configured Chart instance to ensure our patches apply
    return window.Chart
  }

  // Use centralized chart configuration service
  getDefaultOptions() {
    return chartConfig.getBaseConfig()
  }

  // Get type-specific configuration from service
  getConfigForType(type, customOptions = {}) {
    return chartConfig.getConfigForType(type, customOptions)
  }

  // Create datasets using centralized service
  createDataset(label, data, options = {}) {
    return chartConfig.createDataset(label, data, options)
  }

  // Create multiple datasets with automatic color assignment
  createDatasets(datasets) {
    return chartConfig.createDatasets(datasets)
  }

  // Get formatters from service
  get formatters() {
    return chartConfig.formatters
  }

  // Simple merge helper for chart options
  mergeOptions(defaultOptions, customOptions) {
    return chartConfig.mergeOptions(defaultOptions, customOptions)
  }

  // Get compact configuration
  getCompactConfig() {
    return chartConfig.getCompactConfig()
  }

  // ===========================================================================
  // SHARED CHART INSTANCE CREATION
  // ===========================================================================

  /**
   * Create a chart instance with standardized configuration
   * @param {string} type - Chart type (line, bar, doughnut, etc.)
   * @param {Object} data - Chart data object
   * @param {Object} customOptions - Custom options to merge
   * @param {Object} accessibility - Accessibility options
   * @returns {Object|null} - Chart instance or null if failed
   */
  createChartInstance(type, data, { customOptions = {}, accessibility = {} } = {}) {
    const Chart = this.getChart()
    if (!Chart) {
      this.handleUnavailable()
      return null
    }

    // Validate required data
    if (!this.validateData(data, `${type} chart data`)) {
      return null
    }

    // Set up accessibility
    const ariaLabel = accessibility.label || `${type} chart`
    const ariaDesc = accessibility.description || `Interactive ${type} chart displaying data`

    // Create canvas and description
    const { canvas, desc } = this.createCanvas(ariaLabel, ariaDesc)
    const ctx = this.getCtx(canvas)
    if (!ctx) return null

    // Get configuration for chart type
    const baseConfig = this.getConfigForType(type, customOptions)

    // Build final configuration
    const config = {
      type,
      data,
      options: baseConfig
    }

    try {
      // Create chart instance
      const chartInstance = new Chart(ctx, config)

      // Mount to DOM
      this.mountCanvas(canvas, desc)

      // Store reference for cleanup
      this.chartInstance = chartInstance

      if (process.env.NODE_ENV !== 'production') {
        console.log(`${type} chart created successfully`)
      }

      return chartInstance

    } catch (error) {
      this.handleError(`Failed to create ${type} chart`, error)
      return null
    }
  }

  /**
   * Update existing chart with new data (Rails 8 server-driven approach)
   * @param {Object} newData - New data from server
   */
  updateChartData(newData) {
    if (!this.chartInstance) {
      console.warn('No chart instance to update')
      return
    }

    if (!this.validateData(newData, 'chart update data')) {
      return
    }

    try {
      // Update chart data
      this.chartInstance.data = newData
      this.chartInstance.update('none') // No animation for server updates

      if (process.env.NODE_ENV !== 'production') {
        console.log('Chart data updated from server')
      }

    } catch (error) {
      this.handleError('Failed to update chart data', error)
    }
  }


  /**
   * Recreate chart with current data and configuration
   * Called during resize or when chart needs to be rebuilt
   */
  recreateChart() {
    if (!this.chartInstance) {
      console.warn('No chart instance to recreate')
      return
    }

    // Store current data and type
    const currentData = this.chartInstance.data
    const currentType = this.chartInstance.config.type

    // Clean up existing chart
    this.cleanupExistingChart()

    // Recreate with same data and type
    this.createChartInstance(currentType, currentData)
  }
}

// Apply target safety mixin

export default ChartBaseController
