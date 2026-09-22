import { Application } from '@hotwired/stimulus'
import { Chart } from 'chart.js'
import ChartController from 'controllers/charts/chart_controller'

jest.mock('chart.js', () => ({
  Chart: Object.assign(jest.fn().mockImplementation(() => ({ destroy: jest.fn() })), { register: jest.fn() })
}))

const settle = () => new Promise(resolve => setTimeout(resolve, 0))
let application

async function mount(values = '') {
  document.body.innerHTML = `<p id="description">The same counts are in the table.</p>
    <div data-controller="chart" data-chart-data-value='{"Draft":"5","Approved":3,"Invalid":"x"}' ${values}>
      <canvas data-chart-target="canvas" role="img" aria-label="Applications" aria-describedby="description"></canvas>
    </div>`
  application = Application.start()
  application.register('chart', ChartController)
  await settle()
  return Chart.mock.calls.at(-1)[1]
}

beforeEach(() => Chart.mockClear())
afterEach(async () => {
  document.body.innerHTML = ''
  await settle()
  application.stop()
  jest.restoreAllMocks()
})

test('a construction failure does not cause a second error on disconnect', async () => {
  const failure = new Error('Chart construction failed')
  const handleError = jest.spyOn(Application.prototype, 'handleError').mockImplementation(() => {})
  Chart.mockImplementationOnce(() => { throw failure })
  await mount()
  document.querySelector('[data-controller]').remove()
  await settle()
  expect(handleError.mock.calls.map(([error]) => error)).toEqual([failure])
})

test('connects to the view canvas without replacing accessible markup', async () => {
  const config = await mount('data-chart-title-value="Applications" data-chart-dataset-label-value="FY26"')
  expect(Chart).toHaveBeenCalledTimes(1)
  expect(Chart.mock.calls[0][0]).toBe(document.querySelector('canvas'))
  expect(document.querySelector('canvas').getAttribute('aria-describedby')).toBe('description')
  expect(document.getElementById('description').textContent).toContain('same counts')
  expect(config.type).toBe('bar')
  expect(config.data.labels).toEqual(['Draft', 'Approved', 'Invalid'])
  expect(config.data.datasets[0]).toMatchObject({ label: 'FY26', data: [5, 3, 0] })
  expect(config.options).toMatchObject({ responsive: true, maintainAspectRatio: false })
  expect(config.options.events).toBeUndefined()
  expect(config.options.plugins.title).toEqual({ display: true, text: 'Applications' })
})

test('aligns comparison values by category and retains all-zero comparisons', async () => {
  const config = await mount(`data-chart-comparison-data-value='{"Approved":0,"Draft":0}'
    data-chart-comparison-label-value="FY25"`)
  expect(config.data.datasets[1]).toMatchObject({ label: 'FY25', data: [0, 0, 0] })
})

test('formats currency for the numeric horizontal axis and tooltip', async () => {
  const config = await mount('data-chart-index-axis-value="y" data-chart-format-value="currency" data-chart-y-axis-label-value="Amount in USD"')
  expect(config.options.indexAxis).toBe('y')
  expect(config.options.scales.x.ticks.callback(1200)).toBe('$1,200')
  expect(config.options.scales.x.title).toEqual({ display: true, text: 'Amount in USD' })
  expect(config.options.scales.y?.title).toBeUndefined()
  expect(config.options.plugins.tooltip.callbacks.label({ dataset: { label: 'Total' }, raw: 1200 })).toBe('Total: $1,200')
})

test('compact charts omit legend and title', async () => {
  const config = await mount('data-chart-compact-value="true" data-chart-title-value="Activity"')
  expect(config.options.plugins.legend.display).toBe(false)
  expect(config.options.plugins.title.display).toBe(false)
})

test('empty and hidden charts construct eagerly', async () => {
  const config = await mount('style="display:none"')
  expect(config.data.datasets).toHaveLength(1)
  const element = document.querySelector('[data-controller]')
  element.remove()
  await settle()
  element.setAttribute('data-chart-data-value', '{}')
  document.body.appendChild(element)
  await settle()
  expect(Chart.mock.calls.at(-1)[1].data.labels).toEqual([])
})

test('destroys every disconnected instance once across repeated reconnects', async () => {
  await mount()
  const element = document.querySelector('[data-controller]')
  const canvas = element.querySelector('canvas')
  for (let i = 0; i < 5; i++) {
    const instance = Chart.mock.results.at(-1).value
    element.remove()
    await settle()
    expect(instance.destroy).toHaveBeenCalledTimes(1)
    document.body.appendChild(element)
    await settle()
    expect(element.querySelector('canvas')).toBe(canvas)
  }
  element.remove()
  await settle()
  expect(Chart).toHaveBeenCalledTimes(6)
  Chart.mock.results.forEach(({ value }) => expect(value.destroy).toHaveBeenCalledTimes(1))
})
