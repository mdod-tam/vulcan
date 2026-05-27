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
    Object.defineProperty(element, 'clientHeight', { value: 300, configurable: true });
    Object.defineProperty(element, 'offsetParent', { value: document.body, configurable: true });
    element.getBoundingClientRect = () => ({ width: 400, height: 300, top: 0, left: 0, right: 400, bottom: 300 });

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

    controller.connected = true;
    await controller.initializeChart();
  });

  it('creates a canvas and instantiates a chart', () => {
    const canvas = element.querySelector('canvas');
    expect(canvas).not.toBeNull();
    expect(canvas.width).toBe(400);
    expect(canvas.height).toBe(300);
    expect(canvas.getAttribute('aria-describedby')).toBe('reports-chart-desc');
    expect(window.Chart).toHaveBeenCalledTimes(1);
    const config = window.Chart.mock.calls[0][1];
    expect(config.data.datasets[0].label).toBe('FY26');
    expect(config.data.datasets[1].label).toBe('FY25');
    expect(config.options.events).toEqual([]);
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

  it('still initializes later charts when an earlier queued init fails', async () => {
    ReportsChartController.initQueue = Promise.resolve();

    const secondElement = document.createElement('div');
    Object.assign(secondElement.dataset, {
      reportsChartCurrentDataValue: JSON.stringify({ Created: 1 }),
      reportsChartPreviousDataValue: JSON.stringify({}),
      reportsChartTypeValue: 'bar',
      reportsChartTitleValue: 'Second chart'
    });
    Object.defineProperty(secondElement, 'clientWidth', { value: 200, configurable: true });
    Object.defineProperty(secondElement, 'clientHeight', { value: 150, configurable: true });
    secondElement.getBoundingClientRect = () => ({
      width: 200, height: 150, top: 0, left: 0, right: 200, bottom: 150
    });
    document.body.appendChild(secondElement);

    const failingController = new ReportsChartController();
    Object.defineProperty(failingController, 'element', { value: element, configurable: true });
    Object.defineProperty(failingController, 'currentDataValue', {
      value: currentSnapshot, configurable: true, writable: true
    });
    Object.defineProperty(failingController, 'previousDataValue', {
      value: previousSnapshot, configurable: true, writable: true
    });
    Object.defineProperty(failingController, 'typeValue', { value: 'bar', configurable: true, writable: true });
    Object.defineProperty(failingController, 'titleValue', { value: 'Fails', configurable: true, writable: true });
    Object.defineProperty(failingController, 'compactValue', { value: false, configurable: true, writable: true });
    Object.defineProperty(failingController, 'yAxisLabelValue', { value: '', configurable: true, writable: true });
    failingController.connected = true;
    failingController.renderChart = () => {
      throw new Error('boom')
    };

    const secondController = new ReportsChartController();
    Object.defineProperty(secondController, 'element', { value: secondElement, configurable: true });
    Object.defineProperty(secondController, 'currentDataValue', {
      value: { Created: 1 }, configurable: true, writable: true
    });
    Object.defineProperty(secondController, 'previousDataValue', {
      value: {}, configurable: true, writable: true
    });
    Object.defineProperty(secondController, 'typeValue', { value: 'bar', configurable: true, writable: true });
    Object.defineProperty(secondController, 'titleValue', { value: 'Second chart', configurable: true, writable: true });
    Object.defineProperty(secondController, 'compactValue', { value: false, configurable: true, writable: true });
    Object.defineProperty(secondController, 'yAxisLabelValue', { value: '', configurable: true, writable: true });
    secondController.connected = true;

    await failingController.initializeChart();
    await secondController.initializeChart();

    expect(secondElement.querySelector('canvas')).not.toBeNull();
    expect(window.Chart.mock.calls.length).toBeGreaterThan(1);
  });

  it('does not render after disconnect while init is queued', async () => {
    ReportsChartController.initQueue = Promise.resolve();

    let rafCallback = null;
    window.requestAnimationFrame = (cb) => {
      rafCallback = cb;
      return 1;
    };

    const pendingController = new ReportsChartController();
    Object.defineProperty(pendingController, 'element', { value: element, configurable: true });
    Object.defineProperty(pendingController, 'currentDataValue', {
      value: currentSnapshot, configurable: true, writable: true
    });
    Object.defineProperty(pendingController, 'previousDataValue', {
      value: previousSnapshot, configurable: true, writable: true
    });
    Object.defineProperty(pendingController, 'typeValue', { value: 'bar', configurable: true, writable: true });
    Object.defineProperty(pendingController, 'titleValue', { value: 'Pending', configurable: true, writable: true });
    Object.defineProperty(pendingController, 'compactValue', { value: false, configurable: true, writable: true });
    Object.defineProperty(pendingController, 'yAxisLabelValue', { value: '', configurable: true, writable: true });
    pendingController.connected = true;
    pendingController.chartInstance = null;

    const renderSpy = jest.spyOn(pendingController, 'renderChart');
    const scheduleSpy = jest.spyOn(pendingController, 'scheduleInitialization');

    const initPromise = pendingController.initializeChart();

    while (!rafCallback) {
      await Promise.resolve();
    }

    pendingController.disconnect();
    expect(pendingController.connected).toBe(false);

    rafCallback();
    await initPromise;

    expect(renderSpy).not.toHaveBeenCalled();
    expect(scheduleSpy).not.toHaveBeenCalled();

    renderSpy.mockRestore();
    scheduleSpy.mockRestore();
    window.requestAnimationFrame = (cb) => {
      if (cb) cb();
      return 1;
    };
  });
});
