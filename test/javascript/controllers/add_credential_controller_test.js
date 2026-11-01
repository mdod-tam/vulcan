import { Application } from '@hotwired/stimulus'
import { waitFor } from '@testing-library/dom'
import AddCredentialController from 'controllers/auth/add_credential_controller'
import { railsRequest } from '../../../app/javascript/services/rails_request'
import { registerWebAuthn } from '../../../app/javascript/auth'

jest.mock('../../../app/javascript/services/rails_request', () => ({
  railsRequest: { perform: jest.fn(), cancel: jest.fn() }
}))
jest.mock('../../../app/javascript/auth', () => ({ registerWebAuthn: jest.fn() }))

let application, controller, form, nickname, button, feedback

beforeEach(async () => {
  document.body.innerHTML = `<form action="/options" data-controller="add-credential"
    data-action="submit->add-credential#register"
    data-add-credential-callback-url-value="/credentials/webauthn">
    <input data-add-credential-target="nicknameInput" value="My Laptop">
    <button data-add-credential-target="submitButton">Continue</button>
    <div role="alert" class="hidden" data-add-credential-target="statusMessage"></div>
  </form>`
  application = Application.start()
  application.register('add-credential', AddCredentialController)
  await waitFor(() => expect(application.controllers).toHaveLength(1))
  controller = application.controllers[0]
  form = document.querySelector('form')
  nickname = form.querySelector('input')
  button = form.querySelector('button')
  feedback = form.querySelector('[role="alert"]')
  railsRequest.perform.mockReset().mockResolvedValue({ success: true, data: { challenge: 'challenge' } })
  registerWebAuthn.mockReset()
  jest.spyOn(console, 'error').mockImplementation(() => {})
})

afterEach(() => {
  application.stop()
  document.body.innerHTML = ''
  jest.restoreAllMocks()
})

test('shows a rejected registration and allows retry with the same name', async () => {
  registerWebAuthn.mockResolvedValueOnce({ success: false, message: 'Registration failed. Please try again.' })
    .mockResolvedValueOnce({ success: true })

  await controller.register({ preventDefault: jest.fn() })

  expect(feedback).not.toHaveClass('hidden')
  expect(feedback).toHaveTextContent('Registration failed. Please try again.')
  expect(button).toBeEnabled()
  expect(nickname).toHaveValue('My Laptop')
  expect(nickname).not.toHaveClass('border-danger-500')

  await controller.register({ preventDefault: jest.fn() })
  expect(registerWebAuthn).toHaveBeenCalledTimes(2)
  expect(feedback).toHaveClass('hidden')
})

test('shows an options request failure and restores the form', async () => {
  railsRequest.perform.mockRejectedValue(new Error('Network error. Please try again.'))

  await controller.register({ preventDefault: jest.fn() })

  expect(feedback).not.toHaveClass('hidden')
  expect(feedback).toHaveTextContent('Network error. Please try again.')
  expect(button).toBeEnabled()
  expect(nickname).toHaveValue('My Laptop')
  expect(registerWebAuthn).not.toHaveBeenCalled()
})
