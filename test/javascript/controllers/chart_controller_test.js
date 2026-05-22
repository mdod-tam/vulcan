import ReportsChartController from 'controllers/charts/reports_chart_controller';

// Mock the global Chart object and its instance
const mockChartInstance = {
  destroy: jest.fn(),
  update: jest.fn(),
  data: {
    labels: [],
    datasets: [{ data: [] }, { data: [] }],
  },
};
window.Chart = jest.fn().mockImplementation(() => mockChartInstance);
window.requestAnimationFrame = (cb) => {
  if (cb) cb();
  return 1;
};

// JSDOM doesn't implement getContext, so we mock it.
HTMLCanvasElement.prototype.getContext = () => ({
  clearRect: () => {},
  fillRect: () => {},
});

describe('ReportsChartController', () => {
  let element;
  let controller;

  const currentSnapshot = { Draft: 5, 'In progress': 10, Approved: 3 };
  const previousSnapshot = { Draft: 2, 'In progress': 8, Approved: 1 };

  beforeEach(async () => {
    jest.clearAllMocks();

    document.body.innerHTML = `
      <p id="reports-chart-desc" class="sr-only">FY26 application status snapshot chart.</p>
      <div
        aria-describedby="reports-chart-desc"
        data-reports-chart-current-data-value='${JSON.stringify(currentSnapshot)}'
        data-reports-chart-previous-data-value='${JSON.stringify(previousSnapshot)}'
        data-reports-chart-current-dataset-label-value="FY26"
        data-reports-chart-previous-dataset-label-value="FY25"
        data-reports-chart-type-value="bar"
        data-reports-chart-title-value="FY26 Application Status Snapshot"
      ></div>
    `;
    element = document.querySelector('div[data-reports-chart-current-data-value]');

    Object.defineProperty(element, 'clientWidth', { value: 400, configurable: true });
    Object.defineProperty(element, 'offsetParent', { value: document.body, configurable: true });

    controller = new ReportsChartController();

    Object.defineProperty(controller, 'element', { value: element, configurable: true });
    Object.defineProperty(controller, 'currentDataValue', {
      value: JSON.parse(element.dataset.reportsChartCurrentDataValue),
      configurable: true,
      writable: true
    });
    Object.defineProperty(controller, 'previousDataValue', {
      value: JSON.parse(element.dataset.reportsChartPreviousDataValue),
      configurable: true,
      writable: true
    });
    Object.defineProperty(controller, 'typeValue', { value: element.dataset.reportsChartTypeValue, configurable: true, writable: true });
    Object.defineProperty(controller, 'titleValue', { value: element.dataset.reportsChartTitleValue, configurable: true, writable: true });
    Object.defineProperty(controller, 'currentDatasetLabelValue', {
      value: element.dataset.reportsChartCurrentDatasetLabelValue,
      configurable: true,
      writable: true
    });
    Object.defineProperty(controller, 'previousDatasetLabelValue', {
      value: element.dataset.reportsChartPreviousDatasetLabelValue,
      configurable: true,
      writable: true
    });
    Object.defineProperty(controller, 'compactValue', { value: false, configurable: true, writable: true });
    Object.defineProperty(controller, 'yAxisLabelValue', { value: '', configurable: true, writable: true });

    await controller.initializeChart();
  });

  it('creates a canvas and instantiates a chart', () => {
    const canvas = element.querySelector('canvas');
    expect(canvas).not.toBeNull();
    expect(canvas.getAttribute('aria-describedby')).toBe('reports-chart-desc');
    expect(window.Chart).toHaveBeenCalledTimes(1);
    const config = window.Chart.mock.calls[0][1];
    expect(config.data.datasets[0].label).toBe('FY26');
    expect(config.data.datasets[1].label).toBe('FY25');
  });

  it('destroys the chart instance on disconnect', () => {
    controller.disconnect();
    expect(mockChartInstance.destroy).toHaveBeenCalledTimes(1);
  });

  it('updates the chart when data values change', () => {
    mockChartInstance.update.mockClear();

    controller.currentDataValue = { Draft: 6, 'In progress': 11, Approved: 4 };
    controller.currentDataValueChanged();

    expect(mockChartInstance.update).toHaveBeenCalledWith('none');
    expect(controller.chartInstance.data.datasets[0].data).toEqual([6, 11, 4]);
  });

  it('keeps a provided previous dataset when all previous values are zero', () => {
    controller.previousDataValue = { Draft: 0, 'In progress': 0, Approved: 0 };
    controller.recreateChart();

    const lastCall = window.Chart.mock.calls[window.Chart.mock.calls.length - 1];
    const config = lastCall[1];
    expect(config.data.datasets).toHaveLength(2);
    expect(config.data.datasets[1].label).toBe('FY25');
    expect(config.data.datasets[1].data).toEqual([0, 0, 0]);
  });
});
