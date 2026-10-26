import { Application } from '@hotwired/stimulus'
import ModalController from 'controllers/ui/modal_controller'

let application

const render = async ({ autoOpen = false } = {}) => {
  document.body.innerHTML = `
    <dialog data-controller="modal" ${autoOpen ? 'data-modal-auto-open-value="true"' : ''} data-user-id="7"
            data-action="click->modal#clickOutside cancel->modal#guardCancel close->modal#onClose">
      <form><button type="button" data-action="modal#close">Cancel</button></form>
      <p hidden data-modal-unknown-outcome>Outcome unknown</p>
    </dialog>
  `
  const dialog = document.querySelector('dialog')
  dialog.showModal = jest.fn(() => { dialog.open = true })
  dialog.close = jest.fn(() => { dialog.open = false })
  application = Application.start()
  application.register('modal', ModalController)
  await new Promise(resolve => setTimeout(resolve, 0))
  return dialog
}

const submitEvent = (type, detail = {}) => new CustomEvent(type, { bubbles: true, detail })

afterEach(() => {
  application.stop()
  document.body.innerHTML = ''
})

test('a server-rendered dialog opens itself when it connects', async () => {
  const dialog = await render({ autoOpen: true })

  expect(dialog.showModal).toHaveBeenCalledTimes(1)
})

test('while the form is submitting, Cancel, Escape, and the backdrop cannot dismiss the dialog', async () => {
  const dialog = await render({ autoOpen: true })
  const form = dialog.querySelector('form')

  form.dispatchEvent(submitEvent('turbo:submit-start'))
  dialog.querySelector('button').click()
  const escape = new Event('cancel', { cancelable: true })
  dialog.dispatchEvent(escape)
  dialog.dispatchEvent(new MouseEvent('click', { bubbles: true }))

  expect(dialog.close).not.toHaveBeenCalled()
  expect(escape.defaultPrevented).toBe(true)

  form.dispatchEvent(submitEvent('turbo:submit-end', { success: false, fetchResponse: {} }))
  dialog.querySelector('button').click()
  expect(dialog.close).toHaveBeenCalledTimes(1)
})

test('a failed submission with a response keeps the dialog open; success closes it', async () => {
  const dialog = await render({ autoOpen: true })
  const form = dialog.querySelector('form')

  form.dispatchEvent(submitEvent('turbo:submit-end', { success: false, fetchResponse: {} }))
  expect(dialog.close).not.toHaveBeenCalled()
  expect(dialog.querySelector('[data-modal-unknown-outcome]').hidden).toBe(true)

  form.dispatchEvent(submitEvent('turbo:submit-end', { success: true, fetchResponse: {} }))
  expect(dialog.close).toHaveBeenCalledTimes(1)
})

test('a submission with no response reports an unknown outcome instead of claiming failure', async () => {
  const dialog = await render({ autoOpen: true })

  dialog.querySelector('form').dispatchEvent(submitEvent('turbo:submit-end', { success: false }))

  expect(dialog.querySelector('[data-modal-unknown-outcome]').hidden).toBe(false)
  expect(dialog.close).not.toHaveBeenCalled()
})

test('closing announces which dialog closed', async () => {
  const dialog = await render()
  const closed = jest.fn()
  window.addEventListener('modal:closed', closed)

  dialog.dispatchEvent(new Event('close'))

  expect(closed).toHaveBeenCalledTimes(1)
  expect(closed.mock.calls[0][0].detail.dialog).toBe(dialog)
  window.removeEventListener('modal:closed', closed)
})
