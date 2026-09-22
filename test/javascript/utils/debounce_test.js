import { debounce } from 'utils/debounce'

beforeEach(() => jest.useFakeTimers())
afterEach(() => jest.useRealTimers())

test('runs once after the last call with its arguments and receiver', () => {
  const fn = jest.fn()
  const receiver = { run: debounce(fn, 100) }
  receiver.run('first')
  jest.advanceTimersByTime(90)
  receiver.run('last', 2)
  jest.advanceTimersByTime(99)
  expect(fn).not.toHaveBeenCalled()
  jest.advanceTimersByTime(1)
  expect(fn).toHaveBeenCalledTimes(1)
  expect(fn).toHaveBeenCalledWith('last', 2)
  expect(fn.mock.contexts[0]).toBe(receiver)
})

test('cancel prevents a pending call and permits reuse', () => {
  const fn = jest.fn()
  const run = debounce(fn, 20)
  run('canceled')
  run.cancel()
  jest.runAllTimers()
  expect(fn).not.toHaveBeenCalled()
  run('next')
  jest.runAllTimers()
  expect(fn).toHaveBeenCalledWith('next')
})

test('separate debounced functions do not cancel one another', () => {
  const first = jest.fn()
  const second = jest.fn()
  debounce(first, 10)()
  debounce(second, 20)()
  jest.advanceTimersByTime(10)
  expect(first).toHaveBeenCalledTimes(1)
  expect(second).not.toHaveBeenCalled()
  jest.advanceTimersByTime(10)
  expect(second).toHaveBeenCalledTimes(1)
})
