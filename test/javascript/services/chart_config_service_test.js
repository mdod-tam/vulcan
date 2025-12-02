import { ChartConfigService } from '../../../app/javascript/services/chart_config';

describe('ChartConfigService', () => {
  let service;

  beforeEach(() => {
    service = new ChartConfigService();
  });

  describe('getBaseConfig', () => {
    it('returns a base configuration with responsiveness disabled', () => {
      const config = service.getBaseConfig();
      expect(config).toEqual({
        responsive: false,
        maintainAspectRatio: false,
      });
    });
  });

  describe('getConfigForType', () => {
    it('returns the base config merged with bar chart options', () => {
      const config = service.getConfigForType('bar');
      expect(config).toEqual({
        responsive: false,
        maintainAspectRatio: false,
        scales: { y: { beginAtZero: true } },
      });
    });

    it('returns the base config merged with line chart options', () => {
      const config = service.getConfigForType('line');
      expect(config).toEqual({
        responsive: false,
        maintainAspectRatio: false,
        scales: { y: { beginAtZero: true } },
      });
    });

    it('returns the base config merged with doughnut chart options', () => {
      const config = service.getConfigForType('doughnut');
      expect(config).toEqual({
        responsive: false,
        maintainAspectRatio: false,
        cutout: '60%',
      });
    });

    it('returns only the base config for an unknown type', () => {
      const config = service.getConfigForType('unknown');
      expect(config).toEqual({
        responsive: false,
        maintainAspectRatio: false,
      });
    });
  });

  describe('createDataset', () => {
    it('creates a dataset with default styling', () => {
      const dataset = service.createDataset('My Label', [1, 2, 3]);
      expect(dataset).toEqual({
        label: 'My Label',
        data: [1, 2, 3],
        backgroundColor: 'rgba(79, 70, 229, 0.8)',
        borderColor: 'rgba(79, 70, 229, 1)',
        borderWidth: 2,
      });
    });

    it('allows custom options to override defaults', () => {
      const dataset = service.createDataset('My Label', [1, 2, 3], {
        backgroundColor: 'red',
        borderWidth: 5,
      });
      expect(dataset.backgroundColor).toBe('red');
      expect(dataset.borderWidth).toBe(5);
    });
  });

  describe('createDatasets', () => {
    it('creates multiple datasets with alternating colors', () => {
      const datasets = service.createDatasets([
        { label: 'A', data: [1] },
        { label: 'B', data: [2] },
      ]);
      expect(datasets).toHaveLength(2);
      expect(datasets[0].backgroundColor).toBe('rgba(79, 70, 229, 0.8)');
      expect(datasets[1].backgroundColor).toBe('rgba(156, 163, 175, 0.8)');
    });

    it('merges dataset-specific options', () => {
      const datasets = service.createDatasets([
        { label: 'A', data: [1], options: { tension: 0.5 } },
      ]);
      expect(datasets[0].tension).toBe(0.5);
    });
  });

  describe('getCompactConfig', () => {
    it('returns a configuration for compact charts', () => {
      const config = service.getCompactConfig();
      expect(config).toEqual({
        plugins: { legend: { display: false } },
      });
    });
  });

  describe('mergeOptions', () => {
    it('merges multiple objects into one', () => {
      const merged = service.mergeOptions({ a: 1 }, { b: 2 }, { a: 3 });
      expect(merged).toEqual({ a: 3, b: 2 });
    });

    it('deeply merges nested objects', () => {
      const merged = service.mergeOptions(
        { scales: { y: { beginAtZero: true } } },
        { scales: { y: { title: { display: true, text: 'Value' } } } }
      );
      expect(merged).toEqual({
        scales: {
          y: {
            beginAtZero: true,
            title: { display: true, text: 'Value' }
          }
        }
      });
    });

    it('replaces arrays instead of merging them', () => {
      const merged = service.mergeOptions(
        { data: [1, 2, 3] },
        { data: [4, 5] }
      );
      expect(merged).toEqual({ data: [4, 5] });
    });

    it('handles null values correctly', () => {
      const merged = service.mergeOptions(
        { a: { b: 1 } },
        { a: null }
      );
      expect(merged).toEqual({ a: null });
    });
  });

  describe('formatters', () => {
    it('provides a currency formatter', () => {
      expect(service.formatters.currency(1234.5)).toBe('$1,234.5');
    });
  });
});