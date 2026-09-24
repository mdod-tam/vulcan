import { Application } from '@hotwired/stimulus'
import ChartToggleController from 'controllers/charts/toggle_controller'

test('shows and hides the existing region while keeping button state accessible', async () => {
  document.body.innerHTML = `<div data-controller="chart-toggle">
    <button data-chart-toggle-target="button" data-action="chart-toggle#toggle"
      aria-expanded="false" aria-controls="monthly-chart">Show Chart</button>
    <div id="monthly-chart" data-chart-toggle-target="chart" class="hidden"><canvas></canvas></div>
  </div>`
  const application = Application.start()
  application.register('chart-toggle', ChartToggleController)
  await new Promise(resolve => setTimeout(resolve, 0))
  const button = document.querySelector('button')
  const chart = document.getElementById('monthly-chart')
  const canvas = chart.firstChild
  for (let i = 0; i < 2; i++) {
    button.click()
    expect(chart).not.toHaveClass('hidden')
    expect(button).toHaveAttribute('aria-expanded', 'true')
    expect(button.textContent).toBe('Hide Chart')
    button.click()
    expect(chart).toHaveClass('hidden')
    expect(button).toHaveAttribute('aria-expanded', 'false')
    expect(button.textContent).toBe('Show Chart')
  }
  expect(button).toHaveAttribute('aria-controls', chart.id)
  expect(chart.firstChild).toBe(canvas)
  document.body.innerHTML = ''
  application.stop()
})
