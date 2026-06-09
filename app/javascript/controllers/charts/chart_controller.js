// chart_controller.js

import ChartBaseController from "./base_controller"

/**
 * Chart Controller (v3)
 *
 * Builds on ChartBaseController; charts use fixed sizing (responsive: false) and
 * lazy-init via visibility-changed when nested inside chart-toggle.
 */
export default class extends ChartBaseController {
  static values = {
    data: Object,
    type: { type: String, default: "bar" },
    format: { type: String, default: "number" },
    ariaLabel: { type: String, default: "Chart visualization" },
    ariaDescription: { type: String, default: "Chart data is available in the table above" },
    datasetLabel: { type: String, default: "Monthly Total" }
  }

  connect() {
    super.connect()

    this.onVisibilityChange = this.onVisibilityChange.bind(this)
    this.element.addEventListener("visibility-changed", this.onVisibilityChange)

    const Chart = this.getChart()
    if (!Chart) {
      return this.handleUnavailable()
    }

    if (!this.isVisible()) {
      return
    }

    if (!this.validateData(this.dataValue)) {
      return
    }

    try {
      this.createChart()
    } catch (error) {
      this.handleError("Error initializing chart", error)
    }
  }

  disconnect() {
    this.element.removeEventListener("visibility-changed", this.onVisibilityChange)
    super.disconnect()
  }

  onVisibilityChange(event) {
    if (event.detail?.visible && !this.chartInstance && this.validateData(this.dataValue)) {
      this.createChart()
    }
  }

  // When the dataValue changes, destroy/recreate the chart
  dataValueChanged() {
    if (this.chartInstance && this.validateData(this.dataValue)) {
      this.cleanupExistingChart()
      this.createChart()
    }
  }

  // Called by the base‐controller's debounced resize handler
  recreateChart() {
    if (this.validateData(this.dataValue)) {
      // Destroy first to avoid overflows, then redraw at new width
      this.cleanupExistingChart()
      this.createChart()
    }
  }

  createChart() {
    const Chart = this.getChart()

    // 1) Create a new <canvas> (sized to the current container)
    // 2) Mount it (wipes any previous chart + description)
    const describedById = this.externalDescriptionId()
    const { canvas, desc } = this.createCanvas(
      this.ariaLabelValue,
      this.ariaDescriptionValue,
      { describedById }
    )

    // IMPORTANT: Mount the canvas FIRST, before creating the chart
    // This ensures the canvas is in the DOM when Chart.js initializes
    this.mountCanvas(canvas, desc)
    this.applyContainerDimensions(canvas)

    // 3) Grab the 2D drawing context
    const ctx = this.getCtx(canvas)
    if (!ctx) {
      return
    }

    // 4) Turn string values into numbers (with fallback to 0)
    const numericData = this.prepareChartData()

    const currencyFormat = this.formatValue === "currency"
    const formatValue = (value) => {
      const n = Number(value)
      if (currencyFormat) return "$" + n.toLocaleString()
      return n.toLocaleString()
    }

    const customOptions = {
      responsive: false,
      maintainAspectRatio: false,
      animation: false,
      plugins: {
        legend: {
          display: true,
          labels: { font: { size: 14 } }
        },
        tooltip: {
          enabled: true,
          callbacks: {
            label: (context) => formatValue(context.raw)
          },
          bodyFont: { size: 14 },
          titleFont: { size: 16 }
        }
      }
    }

    if (this.typeValue === "bar" || this.typeValue === "line") {
      customOptions.scales = {
        y: {
          beginAtZero: true,
          ticks: {
            callback: (value) => formatValue(value),
            font: { size: 14 }
          },
          title: currencyFormat ? {
            display: true,
            text: "Amount in USD",
            font: { size: 16, weight: "bold" }
          } : { display: false }
        },
        x: {
          ticks: { font: { size: 14 } },
          title: { display: false }
        }
      }
    }

    // 6) Merge with base options
    const baseOptions = this.getDefaultOptions()
    const finalOptions = this.mergeOptions(baseOptions, customOptions)

    // 7) Finally instantiate the Chart
    try {
      this.chartInstance = new Chart(ctx, {
        type: this.typeValue,
        data: {
          labels: Object.keys(numericData),
          datasets: [
            {
              label: this.datasetLabelValue,
              data: Object.values(numericData),
              backgroundColor: "rgba(79, 70, 229, 0.7)",
              borderColor: "rgba(79, 70, 229, 1)",
              borderWidth: 2
            }
          ]
        },
        options: finalOptions
      })
    } catch (error) {
      console.error("Failed to create chart instance:", error)
      this.handleError("Failed to create chart", error)
    }
  }

  prepareChartData() {
    const data = this.dataValue || {}
    const numericData = {}

    Object.keys(data).forEach((key) => {
      const parsed = parseFloat(data[key])
      numericData[key] = isNaN(parsed) ? 0 : parsed
    })

    return numericData
  }
}
