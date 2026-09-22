import AutosubmitController from 'controllers/admin/autosubmit_controller'

test('submits once after typing and cancels pending submission on disconnect', () => {
  jest.useFakeTimers()
  const controller = new AutosubmitController()
  const requestSubmit = jest.fn()
  Object.defineProperties(controller, {
    element: { value: { requestSubmit } },
    delayValue: { value: 150 }
  })
  controller.connect()
  controller.search()
  jest.advanceTimersByTime(100)
  controller.search()
  jest.advanceTimersByTime(150)
  expect(requestSubmit).toHaveBeenCalledTimes(1)
  controller.search()
  controller.disconnect()
  jest.runAllTimers()
  expect(requestSubmit).toHaveBeenCalledTimes(1)
  jest.useRealTimers()
})
