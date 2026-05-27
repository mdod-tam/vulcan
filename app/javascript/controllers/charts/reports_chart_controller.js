import ChartBaseController from "./base_controller"

/**
 * ReportsChartController
 * 
 * Specialized Chart.js controller for reports with visibility event handling.
 * Uses centralized base functionality with data validation and default options.
 */
class ReportsChartController extends ChartBaseController {
  static initQueue = Promise.resolve()

  static values = {
    currentData: Object,
    previousData: Object,
    type: String,
    title: String,
    compact: Boolean,
    yAxisLabel: String,
    currentDatasetLabel: { type: String, default: "Current Fiscal Year" },
    previousDatasetLabel: { type: String, default: "Previous Fiscal Year" }
  }

  connect() {
    this.connected = true
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

    this.scheduleInitialization()
  }

  disconnect() {
    this.connected = false
    this.element.removeEventListener('visibility-changed', this.onVisibilityChange)
    this.cancelDeferredInitialization()
    super.disconnect()
  }

  scheduleInitialization() {
    if (!this.connected || this.chartInstance) {
      return
    }

    if (this.isVisible()) {
      this.initializeChart()
      return
    }

    this.cancelDeferredInitialization()
    this.onTurboRender = () => {
      if (!this.connected || this.chartInstance || !this.isVisible()) {
        return
      }
      this.initializeChart()
    }
    document.addEventListener('turbo:render', this.onTurboRender)
    document.addEventListener('turbo:load', this.onTurboRender)

    this.visibilityRetryTimer = window.setTimeout(() => {
      if (!this.connected || this.chartInstance || !this.isVisible()) {
        return
      }
      this.initializeChart()
    }, 50)
  }

  cancelDeferredInitialization() {
    if (this.onTurboRender) {
      document.removeEventListener('turbo:render', this.onTurboRender)
      document.removeEventListener('turbo:load', this.onTurboRender)
      this.onTurboRender = null
    }

    if (this.visibilityRetryTimer) {
      window.clearTimeout(this.visibilityRetryTimer)
      this.visibilityRetryTimer = null
    }
  }

  // Stimulus value change callbacks for live updates
  currentDataValueChanged() {
    if (this.chartInstance && this.validateData(this.currentDataValue, "current data")) {
      this.updateChartData()
    }
  }

  previousDataValueChanged() {
    if (this.chartInstance) {
      this.updateChartData()
    }
  }

  onVisibilityChange(event) {
    if (event.detail.visible && this.connected && !this.chartInstance) {
      this.initializeChart()
    }
  }

  async initializeChart() {
    if (!this.connected || this.chartInstance) {
      return
    }

    this.cancelDeferredInitialization()

    const run = async () => {
      await new Promise(r => requestAnimationFrame(r))
      if (!this.connected) {
        return
      }
      if (!this.isVisible()) {
        this.scheduleInitialization()
        return
      }
      this.renderChart()
    }

    // Serialize inits without letting one failure reject the shared queue for all
    // other charts (a rejected .then() skips subsequent work on that chain).
    const task = ReportsChartController.initQueue
      .catch(() => {})
      .then(run)

    ReportsChartController.initQueue = task.catch(() => {})

    try {
      await task
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

  // Update existing chart with new data (Chart.js best practice)
  updateChartData() {
    if (!this.chartInstance) {
      return
    }

    const { labels, currentValues, previousValues } = this.extractData()
    
    // Update chart data directly per Chart.js docs
    this.chartInstance.data.labels = labels
    this.chartInstance.data.datasets[0].data = currentValues
    if (this.chartInstance.data.datasets[1]) {
      this.chartInstance.data.datasets[1].data = previousValues
    }
    
    // Call update() to render changes (with no animation for performance)
    this.chartInstance.update('none')
  }

  renderChart() {
    const Chart = this.getChart()
    
    // Clean up any existing chart
    this.cleanupExistingChart()

    // Container sizing is handled by ERB templates
    // Compact mode should be handled in the template, not JavaScript
    
    // Create and mount canvas
    const describedById = this.externalDescriptionId()
    const fallbackDesc = `Chart showing ${this.titleValue || "data comparison"}`
    const externalDescText = describedById
      ? document.getElementById(describedById)?.textContent?.trim()
      : null

    const { canvas, desc } = this.createCanvas(
      this.titleValue || "Chart visualization",
      externalDescText || fallbackDesc,
      { describedById }
    )
    this.mountCanvas(canvas, desc)
    this.applyContainerDimensions(canvas)

    // Get context and create chart
    const ctx = this.getCtx(canvas)
    if (!ctx) return

    const { labels, currentValues, previousValues } = this.extractData()
    const config = this.buildConfig(Chart, labels, currentValues, previousValues)

    // Create chart instance
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
      events: [],
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
    
    const cartesian = type === 'bar' || type === 'line'
    if (cartesian && this.yAxisLabelValue) {
      reportOptions.scales = reportOptions.scales || {}
      reportOptions.scales.y = reportOptions.scales.y || {}
      reportOptions.scales.y.title = {
        display: true,
        text: this.yAxisLabelValue
      }
    }

    const finalOptions = this.mergeOptions(baseConfig, reportOptions)

    const datasetSpecs = [
      {
        label: this.currentDatasetLabelValue,
        data: currentValues,
        options: {
          backgroundColor: 'rgba(79,70,229,0.8)',
          borderColor: 'rgba(79,70,229,1)'
        }
      }
    ]

    const hasPrevious = Object.keys(this.previousDataValue || {}).length > 0
    if (hasPrevious) {
      datasetSpecs.push({
        label: this.previousDatasetLabelValue,
        data: previousValues,
        options: {
          backgroundColor: 'rgba(156,163,175,0.8)',
          borderColor: 'rgba(156,163,175,1)'
        }
      })
    }

    const datasets = this.createDatasets(datasetSpecs)

    return {
      type,
      data: { labels, datasets },
      options: finalOptions
    }
  }
}

// Apply target safety mixin

export default ReportsChartController
