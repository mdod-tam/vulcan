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
    letterTargets: { value: letters }, submitTargets: { value: [submit] }, statusTarget: { value: status }
  })
  jest.clearAllMocks()
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

test('successful download starts the attachment before refreshing the queue', async () => {
  letters[0].checked = true
  const blob = new Blob(['pdf'])
  global.fetch = jest.fn().mockResolvedValue({ ok: true, headers: new Headers({ 'Content-Disposition': 'attachment; filename="letters.zip"' }), blob: () => Promise.resolve(blob) })
  URL.createObjectURL = jest.fn(() => 'blob:download')
  URL.revokeObjectURL = jest.fn()
  const click = jest.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  await controller.download({ preventDefault: jest.fn(), submitter: submit })
  expect(fetch.mock.calls[0][1].body.getAll('letter_ids[]')).toEqual(['1'])
  expect(click).toHaveBeenCalledTimes(1)
  expect(Turbo.visit).toHaveBeenCalledWith(window.location.href, { action: 'replace' })
  expect(click.mock.invocationCallOrder[0]).toBeLessThan(Turbo.visit.mock.invocationCallOrder[0])
  click.mockRestore()
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
  expect(status.textContent).toContain('Refresh the queue to check release status')
  expect(letters[0].checked).toBe(true)
  expect(submit.disabled).toBe(false)
  expect(Turbo.visit).not.toHaveBeenCalled()
})
