import { Application } from '@hotwired/stimulus'
import ApplicationModalController from 'controllers/ui/application_modal_controller'

test('successful modal submit closes and replaces the current Turbo visit; failure stays open', async () => {
  document.body.innerHTML = `<div data-controller="application-modal"
    data-action="turbo:submit-end->application-modal#handleFormSubmit"><dialog><form></form></dialog></div>`
  window.Turbo = { visit: jest.fn() }
  const application = Application.start()
  application.register('application-modal', ApplicationModalController)
  await new Promise(resolve => setTimeout(resolve, 0))
  const dialog = document.querySelector('dialog')
  dialog.close = jest.fn()
  const form = document.querySelector('form')
  form.dispatchEvent(new CustomEvent('turbo:submit-end', { bubbles: true, detail: { success: false } }))
  expect(dialog.close).not.toHaveBeenCalled()
  expect(Turbo.visit).not.toHaveBeenCalled()
  form.dispatchEvent(new CustomEvent('turbo:submit-end', { bubbles: true, detail: { success: true } }))
  expect(dialog.close).toHaveBeenCalledTimes(1)
  expect(Turbo.visit).toHaveBeenCalledWith(window.location.href, { action: 'replace' })
  document.body.innerHTML = ''
  application.stop()
  delete window.Turbo
})
