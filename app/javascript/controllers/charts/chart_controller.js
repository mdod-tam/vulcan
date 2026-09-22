import { Controller } from "@hotwired/stimulus"
import {
  Chart, BarController, BarElement, CategoryScale, LinearScale, Title, Tooltip, Legend
} from "chart.js"

Chart.register(BarController, BarElement, CategoryScale, LinearScale, Title, Tooltip, Legend)

export default class extends Controller {
  static targets = ["canvas"]
  static values = {
    data: Object,
    comparisonData: Object,
    datasetLabel: { type: String, default: "Current Fiscal Year" },
    comparisonLabel: { type: String, default: "Previous Fiscal Year" },
    title: String,
    compact: Boolean,
    yAxisLabel: String,
    format: { type: String, default: "number" },
    indexAxis: { type: String, default: "x" }
  }

  connect() {
    const labels = Object.keys(this.dataValue)
    const datasets = [{
      label: this.datasetLabelValue,
      data: labels.map(label => Number(this.dataValue[label]) || 0),
      backgroundColor: "rgba(79, 70, 229, 0.8)",
      borderColor: "rgb(79, 70, 229)",
      borderWidth: 2
    }]
    if (Object.keys(this.comparisonDataValue).length) {
      datasets.push({
        label: this.comparisonLabelValue,
        data: labels.map(label => Number(this.comparisonDataValue[label]) || 0),
        backgroundColor: "rgba(156, 163, 175, 0.8)",
        borderColor: "rgb(156, 163, 175)",
        borderWidth: 2
      })
    }

    const format = value => {
      const number = Number(value).toLocaleString()
      return this.formatValue === "currency" ? `$${number}` : number
    }
    const valueAxis = this.indexAxisValue === "y" ? "x" : "y"
    const options = {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      indexAxis: this.indexAxisValue,
      plugins: {
        legend: { display: !this.compactValue },
        title: { display: !this.compactValue && !!this.titleValue, text: this.titleValue },
        tooltip: { callbacks: { label: context => `${context.dataset.label}: ${format(context.raw)}` } }
      },
      scales: {
        [valueAxis]: { beginAtZero: true, ticks: { callback: format } }
      }
    }
    options.scales.y = {
      ...options.scales.y,
      title: { display: !!this.yAxisLabelValue, text: this.yAxisLabelValue }
    }
    this.chart = new Chart(this.canvasTarget, { type: "bar", data: { labels, datasets }, options })
  }

  disconnect() {
    this.chart.destroy()
    this.chart = null
  }
}
