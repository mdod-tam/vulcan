import PrintReleaseController from 'controllers/ui/print_release_controller'
import { Turbo } from '@hotwired/turbo-rails'

jest.mock('@hotwired/turbo-rails', () => ({ Turbo: { visit: jest.fn(), renderStreamMessage: jest.fn() } }))

let controller, form, letters, all, submit, status
beforeEach(() => {
  document.body.innerHTML = '<form action="/download"><input type="checkbox"><input type="checkbox" name="letter_ids[]" value="1"><input type="checkbox" name="letter_ids[]" value="2"><button>Download</button><p></p></form>'
  form = document.querySelector('form')
  ;[all, ...letters] = form.querySelectorAll('input')
  submit = form.querySelector('button')
  status = form.querySelector('p')
  controller = new PrintReleaseController()
  Object.defineProperties(controller, {
    element: { value: form }, allTarget: { value: all }, hasAllTarget: { value: true },
    letterTargets: { value: letters }, submitTargets: { value: [submit] }, statusTarget: { value: status },
    batchValue: { value: true, configurable: true }
  })
  jest.clearAllMocks()
})

test('single letter forms enable download without batch checkboxes', () => {
  Object.defineProperty(controller, 'batchValue', { value: false })
  controller.connect()
  expect(submit.disabled).toBe(false)
})

test('restored selection is retained, partial selection is announced, and select all can clear it', () => {
  letters[0].checked = true
  controller.connect()
  expect(all.indeterminate).toBe(true)
  expect(submit.disabled).toBe(false)
  all.checked = true
  controller.selectAll()
  expect(letters.every(letter => letter.checked)).toBe(true)
  expect(all.indeterminate).toBe(false)
  all.checked = false
  controller.selectAll()
  expect(letters.some(letter => letter.checked)).toBe(false)
  expect(submit.disabled).toBe(true)
})

test('successful download starts the attachment before opening the exact batch', async () => {
  letters[0].checked = true
  const blob = new Blob(['pdf'])
  const headers = new Headers({ 'Content-Disposition': 'attachment; filename="letters.zip"', 'Content-Location': '/batch?ids=1' })
  global.fetch = jest.fn().mockResolvedValue({ ok: true, headers, blob: () => Promise.resolve(blob) })
  URL.createObjectURL = jest.fn(() => 'blob:download')
  URL.revokeObjectURL = jest.fn()
  const click = jest.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  await controller.download({ preventDefault: jest.fn(), submitter: submit })
  expect(fetch.mock.calls[0][1].body.getAll('letter_ids[]')).toEqual(['1'])
  expect(click).toHaveBeenCalledTimes(1)
  expect(Turbo.visit).toHaveBeenCalledWith('/batch?ids=1', { action: 'replace' })
  expect(click.mock.invocationCallOrder[0]).toBeLessThan(Turbo.visit.mock.invocationCallOrder[0])
  click.mockRestore()
})

test('mail action counts selected letters and stays disabled if one cannot be mailed', () => {
  submit.dataset.countLabel = 'Mark {count} in outgoing mail'
  submit.dataset.mail = 'true'
  letters[0].dataset.canMail = 'true'
  letters[0].checked = true
  controller.selectionChanged()
  expect(submit.textContent).toBe('Mark 1 in outgoing mail')
  expect(submit.disabled).toBe(false)

  letters[1].checked = true
  controller.selectionChanged()
  expect(submit.disabled).toBe(true)
  expect(submit.textContent).toBe('Mark 2 in outgoing mail')
})

test('server refusal renders preserved selections and does not download or navigate', async () => {
  global.fetch = jest.fn().mockResolvedValue({ ok: false, headers: new Headers({ 'Content-Type': 'text/vnd.turbo-stream.html' }), text: () => Promise.resolve('<turbo-stream>refusal</turbo-stream>') })
  await controller.download({ preventDefault: jest.fn(), submitter: submit })
  expect(Turbo.renderStreamMessage).toHaveBeenCalledWith('<turbo-stream>refusal</turbo-stream>')
  expect(Turbo.visit).not.toHaveBeenCalled()
  expect(submit.disabled).toBe(false)
})

test('lost response explains uncertainty and allows retry without clearing selected letters', async () => {
  letters[0].checked = true
  global.fetch = jest.fn().mockRejectedValue(new Error('connection lost'))
  await controller.download({ preventDefault: jest.fn(), submitter: submit })
  expect(status.textContent).toContain('Refresh to check release status before retrying')
  expect(letters[0].checked).toBe(true)
  expect(submit.disabled).toBe(false)
  expect(Turbo.visit).not.toHaveBeenCalled()
})
