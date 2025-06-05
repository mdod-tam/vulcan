import ChartBaseController from "./base_controller"
import { applyTargetSafety } from "../../mixins/target_safety"

/**
 * ReportsChartController
 * 
 * Specialized Chart.js controller for reports with visibility event handling.
 * Uses centralized base functionality with data validation and default options.
 */
class ReportsChartController extends ChartBaseController {
  static values = {
    currentData: Object,
    previousData: Object,
    type: String,
    title: String,
    compact: Boolean,
    yAxisLabel: String,
    chartHeight: { type: Number, default: 300 }
  }

  connect() {
    super.connect()
    
    const Chart = this.getChart()
    if (!Chart) {
      return this.handleUnavailable()
    }

    // Validate data before proceeding
    if (!this.validateData(this.currentDataValue, "current data")) {
      return
    }

    // Bind handler for visibility change events
    this.onVisibilityChange = this.onVisibilityChange.bind(this)
    this.element.addEventListener('visibility-changed', this.onVisibilityChange)

    // If already visible on connect, init immediately
    if (this.isVisible() && !this.chartInstance) {
      this.initializeChart()
    }
  }

  disconnect() {
    // Remove event listener
    this.element.removeEventListener('visibility-changed', this.onVisibilityChange)
    
    // Call parent cleanup
    super.disconnect()
  }

  // Stimulus value change callbacks for live updates
  currentDataValueChanged() {
    if (this.chartInstance && this.validateData(this.currentDataValue, "current data")) {
      this.initializeChart()
    }
  }

  previousDataValueChanged() {
    if (this.chartInstance) {
      this.initializeChart()
    }
  }

  onVisibilityChange(event) {
    if (event.detail.visible && !this.chartInstance) {
      this.initializeChart()
    }
  }

  isVisible() {
    // Simple visibility check
    return this.element.offsetParent !== null
  }

  async initializeChart() {
    try {
      // Next animation frame to ensure DOM ready
      await new Promise(r => requestAnimationFrame(r))
      this.renderChart()
    } catch (error) {
      this.handleError("Chart initialization failed", error)
    }
  }

  // Implement recreateChart for base controller resize handling
  recreateChart() {
    if (this.validateData(this.currentDataValue, "current data")) {
      this.renderChart()
    }
  }

  renderChart() {
    const Chart = this.getChart()
    
    // Clean up any existing chart
    this.cleanupExistingChart()

    // Override chartHeightValue based on compact mode
    const height = this.compactValue ? 200 : this.chartHeightValue
    this.chartHeightValue = height
    
    // Create and mount canvas
    const { canvas, desc } = this.createCanvas(
      this.titleValue || "Chart visualization",
      `Chart showing ${this.titleValue || "data comparison"}`
    )
    this.mountCanvas(canvas, desc)

    // Get context and create chart
    const ctx = this.getCtx(canvas)
    if (!ctx) return

    const { labels, currentValues, previousValues } = this.extractData()
    const config = this.buildConfig(Chart, labels, currentValues, previousValues)

    // Create chart directly 
    this.chartInstance = new Chart(ctx, config)
  }

  extractData() {
    const current = this.currentDataValue || {}
    const previous = this.previousDataValue || {}
    const labels = Object.keys(current)
    const currentValues = labels.map(k => {
      const value = Number(current[k] || 0)
      return isNaN(value) ? 0 : value
    })
    const previousValues = labels.map(k => {
      const value = Number(previous[k] || 0)
      return isNaN(value) ? 0 : value
    })
    return { labels, currentValues, previousValues }
  }

  buildConfig(Chart, labels, currentValues, previousValues) {
    const type = this.typeValue === 'horizontalBar' ? 'bar' : this.typeValue
    
    // Use centralized chart configuration
    let baseConfig = this.getConfigForType(type)
    
    // Apply compact mode if needed
    if (this.compactValue) {
      const compactConfig = this.getCompactConfig()
      baseConfig = this.mergeOptions(baseConfig, compactConfig)
    }
    
    // Customize for reports
    const reportOptions = {
      plugins: {
        title: { 
          display: !this.compactValue && !!this.titleValue, 
          text: this.titleValue
        }
      }
    }

    // Configure scales based on chart type
    if (this.typeValue === 'horizontalBar') {
      reportOptions.indexAxis = 'y'
    }
    
    // Add Y-axis label if provided
    if (this.yAxisLabelValue) {
      reportOptions.scales = reportOptions.scales || {}
      reportOptions.scales.y = reportOptions.scales.y || {}
      reportOptions.scales.y.title = {
        display: true,
        text: this.yAxisLabelValue
      }
    }

    const finalOptions = this.mergeOptions(baseConfig, reportOptions)

    // Use centralized dataset creation
    const datasets = this.createDatasets([
      { 
        label: 'Current Fiscal Year', 
        data: currentValues,
        options: {
          backgroundColor: 'rgba(79,70,229,0.8)',
          borderColor: 'rgba(79,70,229,1)'
        }
      },
      { 
        label: 'Previous Fiscal Year', 
        data: previousValues,
        options: {
          backgroundColor: 'rgba(156,163,175,0.8)',
          borderColor: 'rgba(156,163,175,1)'
        }
      }
    ])

    return {
      type,
      data: { labels, datasets },
      options: finalOptions
    }
  }
}

// Apply target safety mixin
applyTargetSafety(ReportsChartController)

export default ReportsChartController
