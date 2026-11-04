import { Application } from '@hotwired/stimulus'
import ApplicationModalController from 'controllers/ui/application_modal_controller'

test('only a successful named application edit closes and refreshes its summary frame', async () => {
  document.body.innerHTML = `<div data-controller="application-modal"
    data-action="turbo:submit-end->application-modal#handleFormSubmit">
    <turbo-frame id="user-application-summary" data-refresh-url="/admin/users/9"></turbo-frame>
    <dialog><form data-application-modal-summary-frame="user-application-summary"></form></dialog></div>`
  window.Turbo = { visit: jest.fn() }
  const application = Application.start()
  application.register('application-modal', ApplicationModalController)
  await new Promise(resolve => setTimeout(resolve, 0))
  const dialog = document.querySelector('dialog')
  dialog.close = jest.fn()
  const form = document.querySelector('form')
  const submit = success => form.dispatchEvent(new CustomEvent('turbo:submit-end', { bubbles: true, detail: { success } }))
  submit(false)
  expect(dialog.close).not.toHaveBeenCalled()
  submit(true)
  expect(dialog.close).toHaveBeenCalledTimes(1)
  expect(document.querySelector('turbo-frame').src).toBe('/admin/users/9')
  expect(Turbo.visit).not.toHaveBeenCalled()
  delete form.dataset.applicationModalSummaryFrame
  submit(true)
  expect(dialog.close).toHaveBeenCalledTimes(1)
  document.body.innerHTML = ''
  application.stop()
  delete window.Turbo
})
