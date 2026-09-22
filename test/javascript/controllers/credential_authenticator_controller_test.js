import { Application } from '@hotwired/stimulus'
import { waitFor } from '@testing-library/dom'
import * as WebAuthnJSON from '@github/webauthn-json'
import Auth from '../../../app/javascript/auth'
import CredentialAuthenticatorController from 'controllers/auth/credential_authenticator_controller'

jest.mock('@github/webauthn-json', () => ({ get: jest.fn(), create: jest.fn() }))

const messages = {
  preparing: 'Preparing verification', verified: 'Verified', optionsError: 'Could not start verification. Try again.',
  failed: 'Verification failed. Try again.', networkError: 'Check your connection.', timedOut: 'Please try again.',
  NotAllowedError: 'Verification cancelled. Try again.'
}
const response = (status, body) => ({ ok: status < 400, status, json: jest.fn().mockResolvedValue(body) })
const options = { challenge: 'challenge', allowCredentials: [] }
let application, button, feedback
const originalFetch = global.fetch

beforeEach(async () => {
  document.body.innerHTML = `<div data-controller="credential-authenticator" data-credential-authenticator-verification-url-value="/verify?locale=es">
    <form action="/options" data-credential-authenticator-target="webauthnForm">
      <button type="button" data-credential-authenticator-target="verificationButton"
        data-action="click->credential-authenticator#startVerification" aria-describedby="feedback">Verify</button>
      <p id="feedback" data-credential-authenticator-target="feedback" role="status" aria-live="polite"></p>
    </form></div>`
  document.querySelector('div').dataset.credentialAuthenticatorMessagesValue = JSON.stringify(messages)
  application = Application.start()
  application.register('credential-authenticator', CredentialAuthenticatorController)
  await waitFor(() => expect(application.controllers).toHaveLength(1))
  button = document.querySelector('button')
  feedback = document.getElementById('feedback')
  global.fetch = jest.fn().mockResolvedValueOnce(response(200, options))
  WebAuthnJSON.get.mockReset().mockResolvedValue({ id: 'credential' })
})

afterEach(() => {
  document.body.innerHTML = ''
  application.stop()
  global.fetch = originalFetch
})

test('shows pending state, prevents overlapping attempts, and permits retry after cancellation', async () => {
  let cancel
  WebAuthnJSON.get.mockReturnValueOnce(new Promise((_, reject) => { cancel = reject }))
  button.click()
  await waitFor(() => expect(WebAuthnJSON.get).toHaveBeenCalledTimes(1))
  expect(feedback).toHaveTextContent(messages.preparing)
  expect(button).toBeDisabled()
  expect(button).toHaveAttribute('aria-disabled', 'true')
  button.click()
  expect(fetch).toHaveBeenCalledTimes(1)
  cancel(new DOMException('Device detail', 'NotAllowedError'))
  await waitFor(() => expect(feedback).toHaveTextContent(messages.NotAllowedError))
  expect(button).toBeEnabled()
  expect(button).toHaveAttribute('aria-disabled', 'false')

  fetch.mockResolvedValueOnce(response(200, { ...options, challenge: 'new-challenge' }))
    .mockResolvedValueOnce(response(200, {}))
  button.click()
  await waitFor(() => expect(feedback).toHaveTextContent(messages.verified))
  expect(WebAuthnJSON.get.mock.calls[1][0].publicKey.challenge).toBe('new-challenge')
  expect(fetch).toHaveBeenLastCalledWith('/verify?locale=es', expect.objectContaining({ method: 'POST' }))
})

test.each(['options', 'verification'])('hides internal %s endpoint errors behind localized feedback', async (stage) => {
  const error = '<img src=x onerror=alert(1)> Please sign in again.'
  if (stage === 'options') fetch.mockReset()
  fetch.mockResolvedValueOnce(response(422, { error, details: 'Private diagnostic' }))
  button.click()
  await waitFor(() => expect(feedback.textContent).toBe(stage === 'options' ? messages.optionsError : messages.failed))
  expect(feedback.querySelector('img')).toBeNull()
  expect(feedback.textContent).not.toContain('Private diagnostic')
  expect(button).toBeEnabled()
})

test.each(['network', 'missing challenge', 'invalid JSON'])('options %s failure gives retry guidance', async (failure) => {
  fetch.mockReset()
  if (failure === 'network') fetch.mockRejectedValue(new TypeError('Failed to fetch'))
  if (failure === 'missing challenge') fetch.mockResolvedValue(response(200, {}))
  if (failure === 'invalid JSON') fetch.mockResolvedValue({ ok: false, json: async () => { throw new SyntaxError('HTML') } })
  button.click()
  await waitFor(() => expect(feedback).toHaveTextContent(messages.optionsError))
  expect(button).toBeEnabled()
  expect(WebAuthnJSON.get).not.toHaveBeenCalled()
})

test.each(['network', 'timeout', 'HTML'])('verification %s failure uses safe localized guidance', async (failure) => {
  if (failure === 'network') fetch.mockRejectedValueOnce(new TypeError('Internal network detail'))
  if (failure === 'timeout') fetch.mockRejectedValueOnce(new DOMException('Internal timeout detail', 'AbortError'))
  if (failure === 'HTML') fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => { throw new SyntaxError('Internal HTML') } })
  button.click()
  const expected = { network: messages.networkError, timeout: messages.timedOut, HTML: messages.failed }[failure]
  await waitFor(() => expect(feedback).toHaveTextContent(expected))
  expect(feedback.textContent).not.toContain('Internal')
  expect(button).toBeEnabled()
})

test('uses the rendered locale for browser failures', async () => {
  document.querySelector('div').dataset.credentialAuthenticatorMessagesValue = JSON.stringify({
    ...messages, NotAllowedError: 'La verificación se canceló. Inténtelo de nuevo.'
  })
  WebAuthnJSON.get.mockRejectedValueOnce(new DOMException('Cancelled', 'NotAllowedError'))
  button.click()
  await waitFor(() => expect(feedback).toHaveTextContent('La verificación se canceló. Inténtelo de nuevo.'))
})

test.each(['verification_failed', 'unknown_code'])('maps server code %s without showing verifier details', async (error_code) => {
  document.querySelector('div').dataset.credentialAuthenticatorMessagesValue = JSON.stringify({
    ...messages, verification_failed: 'Translated failure'
  })
  fetch.mockResolvedValueOnce(response(422, { error_code, error: 'Credential not found', details: 'Internal verifier detail' }))
  button.click()
  await waitFor(() => expect(feedback).toHaveTextContent(error_code === 'verification_failed' ? 'Translated failure' : messages.failed))
  expect(feedback.textContent).not.toContain('Credential')
})

test('existing helper callers without messages retain their feedback and result contract', async () => {
  WebAuthnJSON.get.mockRejectedValueOnce(new DOMException('Cancelled', 'NotAllowedError'))
  const result = await Auth.verifyWebAuthnCredential(options, '/verify', feedback)
  expect(result).toEqual({ success: false, message: 'The operation was cancelled or timed out.', details: 'Cancelled' })
  expect(feedback).toHaveTextContent(result.message)
})


test('distinguishes a verified key from a failed sign-in session', async () => {
  const session_failed = 'Your key was verified, but sign-in failed. Please sign in again.'
  document.querySelector('div').dataset.credentialAuthenticatorMessagesValue = JSON.stringify({ ...messages, session_failed })
  fetch.mockResolvedValueOnce(response(422, { error_code: 'session_failed', error: 'Unable to create session' }))
  button.click()
  await waitFor(() => expect(feedback).toHaveTextContent(session_failed))
  expect(button).toBeEnabled()
})

test('logs non-JSON HTTP failures without exposing or rereading the response body', async () => {
  const log = jest.spyOn(console, 'error').mockImplementation(() => {})
  log.mockClear()
  const text = jest.fn().mockRejectedValue(new TypeError('Body has already been consumed'))
  try {
    const result = await Auth.handleResponse({
      ok: false, status: 500, text,
      json: async () => { throw new SyntaxError('Private proxy HTML') }
    }, messages)
    expect(result.message).toBe(messages.failed)
    expect(log).toHaveBeenCalledWith(expect.stringContaining('500'))
    expect(JSON.stringify(log.mock.calls)).not.toContain('Private')
    expect(text).not.toHaveBeenCalled()
  } finally {
    log.mockRestore()
  }
})
