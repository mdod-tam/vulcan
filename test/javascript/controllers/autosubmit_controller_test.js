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
  form.querySelector('#clear')?.addEventListener('click', event => {
    controller.discardSearch(event)
    event.preventDefault()
  })
  controller.connect()
  controllers.push(controller)
  return { controller, requestSubmit }
}

function fixture(value = '', insideFrame = true) {
  const form = `<form data-turbo-frame="results">
    <input id="q" name="q" value="${value}">
    <input id="managing_guardian_q" name="managing_guardian_q" value="">
    <input type="hidden" name="filter" value="disability_certs_to_review">
    <select id="status" name="status" data-autosubmit-clear-param="filter">
      <option value="awaiting_dcf">Awaiting certification</option>
    </select>
    <select id="date_range" name="date_range"><option value="last_30">Last 30 days</option></select>
    <a href="/applications" id="clear" data-action="click->autosubmit#discardSearch">Clear filters</a>
  </form>`
  document.body.innerHTML = insideFrame ? `<turbo-frame id="results">${form}</turbo-frame>` : `${form}<turbo-frame id="results"></turbo-frame>`
  const frame = document.getElementById('results')
  const field = document.getElementById('q')
  return { frame, field, ...connect(document.querySelector('form')) }
}

async function replaceFrame(frame, controller, value, { guardian = '', responseTarget = 'form', url } = {}) {
  const newFrame = document.createElement('turbo-frame')
  newFrame.innerHTML = `<form data-turbo-frame="results"><input id="q" name="q" value="${value}"><input id="managing_guardian_q" name="managing_guardian_q" value="${guardian}"></form>`
  let next
  const render = jest.fn((current, incoming) => {
    controller.disconnect()
    current.replaceChildren(...incoming.childNodes)
    next = connect(current.querySelector('form'))
  })
  const response = new CustomEvent('turbo:before-fetch-response', { bubbles: true })
  const responseElement = responseTarget === 'form' ? controller.element : frame
  const requestUrl = new URL(url || `https://example.test/applications?q=${encodeURIComponent(value)}`)
  responseElement.dispatchEvent(new CustomEvent('turbo:before-fetch-request', { bubbles: true, detail: { url: requestUrl } }))
  newFrame.querySelector('#q').setAttribute('value', requestUrl.searchParams.get('q') || '')
  newFrame.querySelector('#managing_guardian_q').setAttribute('value', requestUrl.searchParams.get('managing_guardian_q') ?? guardian)
  responseElement.dispatchEvent(response)
  const event = new CustomEvent('turbo:before-frame-render', { detail: { newFrame, render } })
  frame.dispatchEvent(event)
  await event.detail.render(frame, newFrame)
  return { ...next, render, wrappedRender: event.detail.render, requestUrl }
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

test('pending search text survives moving focus to another field during an older response', async () => {
  const { frame, field, controller, requestSubmit } = fixture('Sort')
  field.focus()
  controller.search({ target: field })
  jest.advanceTimersByTime(150)
  field.value = 'Sorting'
  controller.search({ target: field })
  document.getElementById('managing_guardian_q').focus()

  const next = await replaceFrame(frame, controller, 'Sort')

  expect(document.getElementById('q').value).toBe('Sorting')
  expect(document.activeElement.id).toBe('managing_guardian_q')
  jest.advanceTimersByTime(150)
  expect(requestSubmit).toHaveBeenCalledTimes(1)
  expect(next.requestSubmit).toHaveBeenCalledTimes(1)
})

test('both edited search fields survive an older response and submit together once', async () => {
  const { frame, field, controller } = fixture('Sort')
  controller.search({ target: field })
  jest.advanceTimersByTime(150)
  field.value = 'Sorting'
  controller.search({ target: field })
  const guardian = document.getElementById('managing_guardian_q')
  guardian.value = 'Guardian'
  guardian.focus()
  controller.search({ target: guardian })

  const next = await replaceFrame(frame, controller, 'Sort')

  expect(document.getElementById('q').value).toBe('Sorting')
  expect(document.getElementById('managing_guardian_q').value).toBe('Guardian')
  expect(document.activeElement.id).toBe('managing_guardian_q')
  jest.advanceTimersByTime(150)
  expect(next.requestSubmit).toHaveBeenCalledTimes(1)
})

test('an edit back to the original text survives without keeping focus in the form', async () => {
  const { frame, field, controller } = fixture('Sort')
  field.focus()
  field.value = 'Sorting'
  controller.search({ target: field })
  jest.advanceTimersByTime(150)
  field.value = 'Sort'
  controller.search({ target: field })
  field.blur()

  const next = await replaceFrame(frame, controller, 'Sorting')

  expect(document.getElementById('q').value).toBe('Sort')
  expect(document.activeElement).toBe(document.body)
  jest.advanceTimersByTime(150)
  expect(next.requestSubmit).toHaveBeenCalledTimes(1)
})

test.each(['Sorting', ''])('sort navigation submits the current search edit %p without a second form request', async value => {
  const { frame, field, controller, requestSubmit } = fixture('Sort')
  field.value = value
  controller.search({ target: field })
  const guardian = document.getElementById('managing_guardian_q')
  guardian.value = 'Guardian'
  controller.search({ target: guardian })

  const next = await replaceFrame(frame, controller, 'Sort', {
    responseTarget: 'frame', url: 'https://example.test/applications?q=Sort&sort=applicant&direction=asc'
  })

  expect(next.requestUrl.searchParams.get('q')).toBe(value)
  expect(next.requestUrl.searchParams.get('managing_guardian_q')).toBe('Guardian')
  expect(next.requestUrl.searchParams.get('sort')).toBe('applicant')
  expect(next.requestUrl.searchParams.get('direction')).toBe('asc')
  expect(document.getElementById('q').value).toBe(value)
  expect(document.getElementById('managing_guardian_q').value).toBe('Guardian')
  jest.advanceTimersByTime(150)
  expect(requestSubmit).not.toHaveBeenCalled()
  expect(next.requestSubmit).not.toHaveBeenCalled()
})

test('Clear filters navigation accepts server values and does not restore the old search', async () => {
  const { frame, field, controller } = fixture('Sorting')
  field.focus()
  controller.search({ target: field })
  document.getElementById('clear').focus()
  document.getElementById('clear').click()

  const next = await replaceFrame(frame, controller, '', { responseTarget: 'frame' })
  expect(document.getElementById('q').value).toBe('')
  expect(document.activeElement).not.toBe(document.getElementById('q'))
  jest.advanceTimersByTime(150)
  expect(next.requestSubmit).not.toHaveBeenCalled()
})

test('Clear filters discards older edits despite an interleaved form response and search focus', async () => {
  const { frame, field, controller } = fixture('Sort')
  field.focus()
  field.value = 'Sorting'
  controller.search({ target: field })
  document.getElementById('clear').click()
  frame.addEventListener('turbo:before-fetch-response', event => {
    if (event.target === frame) {
      controller.element.dispatchEvent(new CustomEvent('turbo:before-fetch-response', { bubbles: true }))
    }
  })

  const next = await replaceFrame(frame, controller, '', { responseTarget: 'frame' })

  expect(document.getElementById('q').value).toBe('')
  jest.advanceTimersByTime(150)
  expect(next.requestSubmit).not.toHaveBeenCalled()
})

test('link navigation cancels the queued search while its response is pending and later typing still submits', () => {
  const { frame, field, controller, requestSubmit } = fixture('Sort')
  field.value = 'Sorting'
  controller.search({ target: field })

  const url = new URL('https://example.test/applications?q=Sort&sort=applicant')
  frame.dispatchEvent(new CustomEvent('turbo:before-fetch-request', { bubbles: true, detail: { url } }))
  jest.advanceTimersByTime(150)
  expect(requestSubmit).not.toHaveBeenCalled()
  expect(url.searchParams.get('q')).toBe('Sorting')

  field.value = 'New search'
  controller.search({ target: field })
  jest.advanceTimersByTime(150)
  expect(requestSubmit).toHaveBeenCalledTimes(1)
})

test('Clear filters cancels pending search for a form outside its frame', () => {
  const { frame, field, controller, requestSubmit } = fixture('Sort', false)
  field.value = 'Sorting'
  controller.search({ target: field })
  document.getElementById('clear').click()
  const url = new URL('https://example.test/applications')
  frame.dispatchEvent(new CustomEvent('turbo:before-fetch-request', { bubbles: true, detail: { url } }))

  jest.advanceTimersByTime(150)
  expect(url.searchParams.has('q')).toBe(false)
  expect(requestSubmit).not.toHaveBeenCalled()
})

test('opening Clear filters in another tab does not discard the current form search', () => {
  const { field, controller, requestSubmit } = fixture('Sort')
  field.value = 'Sorting'
  controller.search({ target: field })
  document.getElementById('clear').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, ctrlKey: true }))

  jest.advanceTimersByTime(150)
  expect(requestSubmit).toHaveBeenCalledTimes(1)
  expect(controller.searchFields.has(field)).toBe(true)
})

test('changing status clears its declared queue while other filter changes keep it', () => {
  const { controller, requestSubmit } = fixture('Sorting')
  const form = controller.element
  controller.submit({ target: form.elements.date_range })
  expect(new FormData(form).get('filter')).toBe('disability_certs_to_review')

  controller.submit({ target: form.elements.status })
  const parameters = new FormData(form)
  expect(parameters.has('filter')).toBe(false)
  expect(parameters.get('status')).toBe('awaiting_dcf')
  expect(parameters.get('q')).toBe('Sorting')
  expect(parameters.get('date_range')).toBe('last_30')
  expect(requestSubmit).toHaveBeenCalledTimes(2)
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
