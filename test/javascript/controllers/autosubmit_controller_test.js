import AutosubmitController from 'controllers/admin/autosubmit_controller'

let controllers

function connect(form) {
  const controller = new AutosubmitController()
  Object.defineProperties(controller, {
    element: { value: form },
    delayValue: { value: 150 }
  })
  const requestSubmit = jest.spyOn(form, 'requestSubmit').mockImplementation(() => {})
  form.addEventListener('input', event => controller.search(event))
  controller.connect()
  controllers.push(controller)
  return { controller, requestSubmit }
}

function fixture(value = '', insideFrame = true) {
  const form = `<form data-turbo-frame="results"><input id="q" value="${value}"><a href="/applications" id="clear">Clear filters</a></form>`
  document.body.innerHTML = insideFrame ? `<turbo-frame id="results">${form}</turbo-frame>` : `${form}<turbo-frame id="results"></turbo-frame>`
  const frame = document.getElementById('results')
  const field = document.getElementById('q')
  return { frame, field, ...connect(document.querySelector('form')) }
}

async function replaceFrame(frame, controller, value) {
  const newFrame = document.createElement('turbo-frame')
  newFrame.innerHTML = `<form data-turbo-frame="results"><input id="q" value="${value}"></form>`
  let next
  const render = jest.fn((current, incoming) => {
    controller.disconnect()
    current.replaceChildren(...incoming.childNodes)
    next = connect(current.querySelector('form'))
  })
  const event = new CustomEvent('turbo:before-frame-render', { detail: { newFrame, render } })
  frame.dispatchEvent(event)
  await event.detail.render(frame, newFrame)
  return { ...next, render, wrappedRender: event.detail.render }
}

beforeEach(() => {
  controllers = []
  jest.useFakeTimers()
  jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => { callback(); return 0 })
})

afterEach(() => {
  controllers.forEach(controller => controller.disconnect())
  document.body.innerHTML = ''
  jest.useRealTimers()
  jest.restoreAllMocks()
})

test('submits once after typing and cancels pending submission on disconnect', () => {
  const { controller, requestSubmit } = fixture()
  controller.search()
  jest.advanceTimersByTime(100)
  controller.search()
  jest.advanceTimersByTime(150)
  expect(requestSubmit).toHaveBeenCalledTimes(1)
  controller.search()
  controller.disconnect()
  jest.runAllTimers()
  expect(requestSubmit).toHaveBeenCalledTimes(1)
})

test('frame replacement retains the focused search field and selection without submitting again', async () => {
  const { frame, field, controller } = fixture('Sorting')
  field.focus()
  field.setSelectionRange(2, 5, 'forward')
  controller.search({ target: field })
  jest.advanceTimersByTime(150)

  const next = await replaceFrame(frame, controller, 'Sorting')
  const replacement = document.getElementById('q')
  expect(document.activeElement).toBe(replacement)
  expect([replacement.selectionStart, replacement.selectionEnd]).toEqual([2, 5])
  jest.advanceTimersByTime(150)
  expect(next.requestSubmit).not.toHaveBeenCalled()
})

test('newer typed text survives an older response and the replacement form submits it', async () => {
  const { frame, field, controller, requestSubmit } = fixture('Sort')
  field.focus()
  controller.search({ target: field })
  jest.advanceTimersByTime(150)
  field.value = 'Sorting'
  field.setSelectionRange(7, 7)
  controller.search({ target: field })

  const next = await replaceFrame(frame, controller, 'Sort')
  const replacement = document.getElementById('q')
  expect(replacement.value).toBe('Sorting')
  expect(document.activeElement).toBe(replacement)
  expect(replacement.selectionStart).toBe(7)
  jest.advanceTimersByTime(150)
  expect(requestSubmit).toHaveBeenCalledTimes(1)
  expect(next.requestSubmit).toHaveBeenCalledTimes(1)
})

test('Clear filters navigation accepts server values and does not restore the old search', async () => {
  const { frame, field, controller } = fixture('Sorting')
  field.focus()
  controller.search({ target: field })
  document.getElementById('clear').focus()

  const next = await replaceFrame(frame, controller, '')
  expect(document.getElementById('q').value).toBe('')
  expect(document.activeElement).not.toBe(document.getElementById('q'))
  expect(next.wrappedRender).toBe(next.render)
  jest.advanceTimersByTime(150)
  expect(next.requestSubmit).not.toHaveBeenCalled()
})

test('forms outside their target frame keep their input without a render override', async () => {
  const { frame, field, controller } = fixture('Sorting', false)
  field.focus()
  const newFrame = document.createElement('turbo-frame')
  newFrame.innerHTML = '<p>New results</p>'
  const render = (current, incoming) => current.replaceChildren(...incoming.childNodes)
  const event = new CustomEvent('turbo:before-frame-render', { detail: { newFrame, render } })

  frame.dispatchEvent(event)
  expect(event.detail.render).toBe(render)
  event.detail.render(frame, newFrame)
  expect(document.activeElement).toBe(field)
  expect(field.value).toBe('Sorting')
  controller.disconnect()
})
