import '@testing-library/jest-dom';

expect.extend({
  toHaveClass(received, className) {
    const pass = received.classList.contains(className);
    if (pass) {
      return {
        message: () => `expected ${received} not to have class "${className}"`,
        pass: true,
      };
    } else {
      return {
        message: () => `expected ${received} to have class "${className}"`,
        pass: false,
      };
    }
  },
});

// Keep console output out of the test log.
global.console = {
  ...console,
  log: jest.fn(),
  error: jest.fn(),
  warn: jest.fn(),
};
