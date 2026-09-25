import { Application } from '@hotwired/stimulus'
import AutosaveController from 'controllers/forms/autosave_controller'
import { railsRequest, RequestError } from '../../../app/javascript/services/rails_request'

jest.mock('../../../app/javascript/services/rails_request', () => {
  class RequestError extends Error {
    constructor(message, status, data) { super(message); this.status = status; this.data = data }
  }
  return { railsRequest: { perform: jest.fn() }, RequestError }
})

const saved = request => ({ success: true, data: { success: true, outcome: 'saved', revision: request.body.autosave_revision, current_revision: request.body.autosave_revision, value: request.body.field_value } })
const settle = async () => { for (let i = 0; i < 10; i++) await Promise.resolve() }
let application, form

beforeEach(async () => {
  jest.useFakeTimers()
  railsRequest.perform.mockReset().mockImplementation(async request => saved(request))
  document.body.innerHTML = `<form action="/applications" data-controller="autosave"
    data-action="input->autosave#fieldInput change->autosave#fieldChange focusout->autosave#fieldLeave submit->autosave#prepareSubmission turbo:submit-start->autosave#submissionStarted turbo:submit-end->autosave#submissionEnded"
    data-autosave-url-value="/applications/autosave_field?user_id=7"
    data-autosave-debounce-wait-value="1000"
    data-autosave-saving-text-value="Saving draft…"
    data-autosave-saved-text-value="Draft saved"
    data-autosave-failed-text-value="Some changes are not saved yet."
    data-autosave-unsaved-text-value="Use Save Application.">
    <input type="hidden" name="autosave_context" value="0194504e-7920-4c00-b289-bd47348794b6" data-autosave-target="context">
    <input type="hidden" name="autosave_revision" value="0" data-autosave-target="revision">
    <div data-autosave-target="status" role="status" aria-live="polite"></div>
    <div><input id="size" name="application[household_size]" value="3" aria-describedby="size_help"></div>
    <div><input id="income" name="application[annual_income]" value="12345"></div>
    <div><input id="resident" type="checkbox" name="application[maryland_resident]" value="1"></div>
    <div><select id="locale" name="constituent[locale]" data-no-autosave="true"><option>en</option><option>es</option></select></div>
    <input id="upload" name="application[income_proof]" type="file">
    <input id="off" name="application[alternate_contact_name]" disabled>
    <input id="save" type="submit" name="save_draft" value="Save Application">
    <input id="submit" type="submit" name="submit_application" value="Submit Application">
  </form>`
  application = Application.start()
  application.register('autosave', AutosaveController)
  await settle()
  form = document.querySelector('form')
})

afterEach(async () => {
  document.body.innerHTML = ''
  await settle()
  application.stop()
  jest.clearAllTimers()
  jest.useRealTimers()
})

const field = id => document.getElementById(id)
const status = () => form.querySelector('[data-autosave-target="status"]').textContent
const sent = () => railsRequest.perform.mock.calls.map(([request]) => [request.body.field_name, request.body.field_value])

function type(id, value) {
  field(id).value = value
  field(id).dispatchEvent(new Event('input', { bubbles: true }))
}
const change = id => field(id).dispatchEvent(new Event('change', { bubbles: true }))
const leave = id => field(id).dispatchEvent(new FocusEvent('focusout', { bubbles: true }))
async function advance(ms) { jest.advanceTimersByTime(ms); await settle() }
function held() {
  let resolve, reject, request
  railsRequest.perform.mockImplementationOnce(options => {
    request = options
    return new Promise((res, rej) => { resolve = res; reject = rej })
  })
  return { resolve: () => resolve(saved(request)), reject: error => reject(error) }
}

test('typing saves the latest value once after a pause, to the URL the page names', async () => {
  type('size', '4')
  await advance(500)
  type('size', '45')
  await advance(999)
  expect(railsRequest.perform).not.toHaveBeenCalled()
  await advance(1)
  expect(railsRequest.perform).toHaveBeenCalledTimes(1)
  expect(railsRequest.perform.mock.calls[0][0]).toMatchObject({
    method: 'patch', url: '/applications/autosave_field?user_id=7', keepalive: true,
    body: { field_name: 'application[household_size]', field_value: '45' }
  })
  expect(status()).toBe('Draft saved')
  await advance(3000)
  expect(status()).toBe('')
})

test('leaving an edited field saves it now; leaving an untouched or already-saved field sends nothing', async () => {
  leave('income')
  await advance(2000)
  expect(railsRequest.perform).not.toHaveBeenCalled()

  type('size', '5')
  leave('size')
  await advance(0)
  expect(sent()).toEqual([['application[household_size]', '5']])

  leave('size')
  await advance(2000)
  expect(railsRequest.perform).toHaveBeenCalledTimes(1)
})

test('checkboxes save their checked state on change, and blank values are saved as blank', async () => {
  field('resident').checked = true
  change('resident')
  type('income', '')
  change('income')
  await advance(0)
  field('resident').checked = false
  change('resident')
  await advance(0)
  expect(sent()).toEqual([
    ['application[maryland_resident]', true],
    ['application[annual_income]', ''],
    ['application[maryland_resident]', false]
  ])
})

test('excluded, file and disabled fields are never sent', async () => {
  change('locale')
  change('upload')
  type('off', 'Pat')
  change('off')
  field('off').disabled = false
  await advance(2000)
  expect(railsRequest.perform).not.toHaveBeenCalled()
})

test('saves run one at a time, so a second field waits for the first response', async () => {
  const first = held()
  type('size', '4')
  change('size')
  type('income', '500')
  change('income')
  await advance(0)
  expect(sent()).toEqual([['application[household_size]', '4']])
  expect(status()).toBe('Saving draft…')

  first.resolve()
  await settle()
  expect(sent()).toEqual([['application[household_size]', '4'], ['application[annual_income]', '500']])
  expect(status()).toBe('Draft saved')
})

test('an edit made while its save is in flight is saved afterwards', async () => {
  const first = held()
  type('size', '4')
  change('size')
  await advance(0)
  type('size', '6')
  change('size')
  first.resolve()
  await advance(0)
  expect(sent()).toEqual([['application[household_size]', '4'], ['application[household_size]', '6']])
})

test('a rejected value is shown on its field and keeps the failure visible until that field saves', async () => {
  railsRequest.perform.mockRejectedValueOnce(
    new RequestError('Unprocessable', 422, { errors: { 'application[household_size]': ['Must be a valid integer'] } })
  )
  type('size', '4x')
  change('size')
  await advance(0)

  const error = document.getElementById('size-autosave-error')
  expect(error.textContent).toBe('Must be a valid integer')
  expect(field('size').getAttribute('aria-invalid')).toBe('true')
  expect(field('size').getAttribute('aria-describedby')).toBe('size_help size-autosave-error')
  expect(status()).toBe('Some changes are not saved yet.')

  type('income', '700')
  change('income')
  await advance(4000)
  expect(status()).toBe('Some changes are not saved yet.')

  type('size', '4')
  change('size')
  await advance(0)
  expect(error.textContent).toBe('')
  expect(field('size').hasAttribute('aria-invalid')).toBe(false)
  expect(status()).toBe('Draft saved')
})

test('a failed request keeps the edit pending, so leaving the field sends it again', async () => {
  railsRequest.perform.mockRejectedValueOnce(new TypeError('Failed to fetch'))
  type('size', '4')
  change('size')
  await advance(0)
  expect(status()).toBe('Some changes are not saved yet.')

  leave('size')
  await advance(0)
  expect(sent()).toEqual([['application[household_size]', '4'], ['application[household_size]', '4']])
  expect(status()).toBe('Draft saved')
})

test('leaving the page sends every unsent edit at once with keepalive and cancels nothing in flight', async () => {
  held()
  type('size', '4')
  change('size')
  await advance(0)
  type('income', '900')
  field('resident').checked = true
  change('resident')

  form.removeAttribute('data-controller')
  await settle()

  const calls = railsRequest.perform.mock.calls.map(([request]) => request)
  expect(calls.map(request => [request.body.field_name, request.body.field_value, request.keepalive])).toEqual([
    ['application[household_size]', '4', true],
    ['application[annual_income]', '900', true],
    ['application[maryland_resident]', true, true]
  ])
  await advance(5000)
  expect(railsRequest.perform).toHaveBeenCalledTimes(3)
})

test('pagehide sends unsent edits before a full page unload', async () => {
  type('income', '900')
  window.dispatchEvent(new Event('pagehide'))
  await settle()
  expect(railsRequest.perform.mock.calls[0][0]).toMatchObject({
    keepalive: true, body: { field_name: 'application[annual_income]', field_value: '900' }
  })
  await advance(2000)
  expect(railsRequest.perform).toHaveBeenCalledTimes(1)
})

test('an older acknowledgement cannot report saved while a newer edit is pending', async () => {
  const first = held()
  type('size', '4')
  change('size')
  await advance(0)
  type('size', '7')
  first.resolve()
  await settle()
  expect(status()).not.toBe('Draft saved')
  await advance(1000)
  expect(sent()).toEqual([['application[household_size]', '4'], ['application[household_size]', '7']])
  expect(status()).toBe('Draft saved')
})

test('a request already in flight has unload protection without resending it', async () => {
  held()
  type('size', '4')
  change('size')
  await advance(0)
  window.dispatchEvent(new Event('pagehide'))
  expect(railsRequest.perform).toHaveBeenCalledTimes(1)
  expect(railsRequest.perform.mock.calls[0][0].keepalive).toBe(true)
})

function unloadCanceled() {
  const event = new Event('beforeunload', { cancelable: true })
  window.dispatchEvent(event)
  return event.defaultPrevented
}
function submitEvent(name, success) {
  form.dispatchEvent(new CustomEvent(name, { bubbles: true, cancelable: true, detail: { success } }))
}

test('the unload warning covers pending and failed edits and disappears after confirmation', async () => {
  expect(unloadCanceled()).toBe(false)
  const request = held()
  type('size', '4')
  expect(unloadCanceled()).toBe(true)
  await advance(1000)
  request.reject(new TypeError('Network failed'))
  await settle()
  expect(unloadCanceled()).toBe(true)
  leave('size')
  await advance(0)
  expect(unloadCanceled()).toBe(false)
})

test('full-form-only changes require Save Application and do not send autosaves', async () => {
  field('locale').value = 'es'
  change('locale')
  await advance(1000)
  expect(railsRequest.perform).not.toHaveBeenCalled()
  expect(status()).toBe('Use Save Application.')
  expect(unloadCanceled()).toBe(true)
  field('locale').value = 'en'
  change('locale')
  expect(unloadCanceled()).toBe(false)
})

test('departure sends the newer revision while an older save remains active', async () => {
  const first = held()
  type('size', '4')
  change('size')
  await advance(0)
  type('size', '7')
  window.dispatchEvent(new Event('pagehide'))
  await settle()
  expect(railsRequest.perform.mock.calls.map(([r]) => r.body.autosave_revision)).toEqual([1, 2])
  first.resolve()
  await settle()
  expect(sent()).toEqual([['application[household_size]', '4'], ['application[household_size]', '7']])
  expect(field('size').value).toBe('7')
  expect(status()).toBe('Draft saved')
})

test('malformed success is not a confirmed save', async () => {
  railsRequest.perform.mockResolvedValueOnce({ success: true, data: {} })
  type('size', '4')
  await advance(1000)
  expect(status()).toBe('Some changes are not saved yet.')
  expect(unloadCanceled()).toBe(true)
})

test('submission captures a later revision and freezes controls without clearing edits early', async () => {
  type('size', '4')
  submitEvent('submit')
  expect(form.querySelector('[name="autosave_revision"]').value).toBe('2')
  submitEvent('turbo:submit-start')
  expect(field('size').disabled).toBe(true)
  expect(field('save').disabled).toBe(true)
  expect(field('submit').disabled).toBe(true)
  await advance(1000)
  expect(railsRequest.perform).not.toHaveBeenCalled()
  expect(unloadCanceled()).toBe(true)
  submitEvent('turbo:submit-end', true)
  expect(field('size').disabled).toBe(false)
  expect(field('save').disabled).toBe(false)
  expect(field('submit').disabled).toBe(false)
  expect(field('off').disabled).toBe(true)
  expect(unloadCanceled()).toBe(false)
  window.dispatchEvent(new Event('pagehide'))
  expect(railsRequest.perform).not.toHaveBeenCalled()
})

test('failed submission restores controls and retains pending edits without starting saves', async () => {
  type('size', '4')
  submitEvent('submit')
  submitEvent('turbo:submit-start')
  submitEvent('turbo:submit-end', false)
  await advance(1000)
  expect(field('size').disabled).toBe(false)
  expect(field('size').value).toBe('4')
  expect(unloadCanceled()).toBe(true)
  expect(railsRequest.perform).not.toHaveBeenCalled()
  leave('size')
  await advance(0)
  expect(status()).toBe('Use Save Application.')
})

test('a restored snapshot retries its original revision and shows a superseding server value', async () => {
  type('size', '4')
  const snapshot = form.cloneNode(true)
  document.body.innerHTML = ''
  await settle()
  railsRequest.perform.mockClear().mockImplementationOnce(async request => ({
    success: true, data: { success: true, outcome: 'superseded', revision: request.body.autosave_revision, current_revision: 8, value: 7 }
  }))
  document.body.appendChild(snapshot)
  form = snapshot
  await settle()
  await advance(0)
  expect(railsRequest.perform.mock.calls[0][0].body.autosave_revision).toBe(1)
  expect(field('size').value).toBe('7')
  type('size', '8')
  await advance(1000)
  expect(railsRequest.perform.mock.calls[1][0].body.autosave_revision).toBe(9)
})

test('a failed form render disconnect does not flush the pending form snapshot', async () => {
  type('size', '4')
  submitEvent('submit')
  submitEvent('turbo:submit-start')
  document.body.innerHTML = ''
  await settle()
  await advance(2000)
  expect(railsRequest.perform).not.toHaveBeenCalled()
})

test('native validation refusal leaves the pending edit available to autosave', async () => {
  type('size', '4')
  field('income').required = true
  field('income').value = ''
  expect(form.checkValidity()).toBe(false)
  form.requestSubmit()
  await advance(1000)
  expect(sent()).toEqual([['application[household_size]', '4']])
  expect(field('size').disabled).toBe(false)
})
