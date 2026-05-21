import { Application } from "@hotwired/stimulus"
import ChartToggleController from "controllers/charts/toggle_controller"

describe("ChartToggleController", () => {
  let application
  let controller
  let element
  let chartElement
  let buttonElement

  beforeEach(() => {
    // Set up DOM
    document.body.innerHTML = `
      <div data-controller="chart-toggle">
        <button type="button" 
                data-chart-toggle-target="button"
                data-action="chart-toggle#toggle">
          Show Chart
        </button>
        <div id="monthly-totals-chart" data-chart-toggle-target="chart" class="hidden">
          <div data-controller="chart" id="nested-chart"></div>
        </div>
      </div>
    `

    // Set up Stimulus controller
    application = Application.start()
    application.register("chart-toggle", ChartToggleController)

    element = document.querySelector("[data-controller='chart-toggle']")
    chartElement = element.querySelector("[data-chart-toggle-target='chart']")
    buttonElement = element.querySelector("[data-chart-toggle-target='button']")
  })

  test("initializes with correct ARIA attributes", () => {
    // The connect method should set initial ARIA attributes
    expect(buttonElement.getAttribute("aria-expanded")).toBe("false")
    expect(buttonElement.getAttribute("aria-controls")).toBe("monthly-totals-chart")
  })

  test("toggles chart visibility when button is clicked", () => {
    // Get the controller instance that was automatically created
    const controller = application.getControllerForElementAndIdentifier(element, "chart-toggle")

    // Chart should be hidden initially
    expect(chartElement).toHaveClass("hidden")
    expect(buttonElement.textContent.trim()).toBe("Show Chart")

    // Manually call the toggle method
    controller.toggle()

    // Chart should be visible
    expect(chartElement.classList.contains("hidden")).toBe(false)
    expect(buttonElement.textContent.trim()).toBe("Hide Chart")
    expect(buttonElement.getAttribute("aria-expanded")).toBe("true")

    // Call the toggle method again
    controller.toggle()

    // Chart should be hidden again
    expect(chartElement.classList.contains("hidden")).toBe(true)
    expect(buttonElement.textContent.trim()).toBe("Show Chart")
    expect(buttonElement.getAttribute("aria-expanded")).toBe("false")
  })

  test("maintains accessibility attributes when toggling", () => {
    // Initial state
    expect(buttonElement.getAttribute("aria-expanded")).toBe("false")

    // Show chart
    buttonElement.click()

    // Check accessibility attributes
    expect(buttonElement.getAttribute("aria-expanded")).toBe("true")
    expect(buttonElement.getAttribute("aria-controls")).toBe("monthly-totals-chart")

    // Hide chart
    buttonElement.click()

    // Check accessibility attributes again
    expect(buttonElement.getAttribute("aria-expanded")).toBe("false")
    expect(buttonElement.getAttribute("aria-controls")).toBe("monthly-totals-chart")
  })

  test("dispatches visibility-changed to nested chart controller when revealing chart", () => {
    const chartControllerEl = element.querySelector('[data-controller~="chart"]')
    const handler = jest.fn()
    chartControllerEl.addEventListener("visibility-changed", handler)

    const toggleController = application.getControllerForElementAndIdentifier(element, "chart-toggle")
    toggleController.toggle()

    expect(handler).toHaveBeenCalledTimes(1)
    expect(handler.mock.calls[0][0].detail).toEqual({ visible: true })
  })
})
