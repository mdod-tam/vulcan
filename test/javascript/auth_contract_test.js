import Auth, { registerWebAuthn, verifyWebAuthn } from '../../app/javascript/auth'
import * as WebAuthnJSON from '@github/webauthn-json'

jest.mock('@github/webauthn-json', () => ({ get: jest.fn(), create: jest.fn() }))

beforeEach(() => {
  jest.useFakeTimers()
  global.fetch = jest.fn()
  WebAuthnJSON.create.mockReset()
  WebAuthnJSON.get.mockReset()
})
afterEach(() => { jest.useRealTimers(); jest.restoreAllMocks() })

test('registration retains callback path nickname and feedback callback', async () => {
  const credential = { id: 'key', response: { attestationObject: 'attestation' } }
  WebAuthnJSON.create.mockResolvedValue(credential)
  fetch.mockResolvedValue({ ok: true, status: 200, json: async () => ({ registered: true }) })
  const feedback = jest.fn()
  const options = { challenge: 'challenge' }
  const result = await registerWebAuthn('/credentials/webauthn?credential_nickname=Office', options, 'Office', feedback)
  expect(WebAuthnJSON.create).toHaveBeenCalledWith({ publicKey: options })
  expect(fetch).toHaveBeenCalledWith('/credentials/webauthn', expect.objectContaining({
    method: 'POST', credentials: 'same-origin', body: JSON.stringify({ ...credential, credential_nickname: 'Office' })
  }))
  expect(result).toEqual({ success: true, data: { registered: true } })
  expect(feedback).toHaveBeenCalledWith('Preparing to register security key...', false)
})

test('verification retains the fallback WebAuthn endpoint', async () => {
  WebAuthnJSON.get.mockResolvedValue({ id: 'key' })
  fetch.mockResolvedValue({ ok: true, status: 200, json: async () => ({ verified: true }) })
  await verifyWebAuthn({ challenge: 'challenge' }, null, jest.fn())
  expect(fetch.mock.calls[0][0]).toBe('/two_factor_authentication/verify/webauthn')
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ two_factor_authentication: { id: 'key' } })
})

test('the 15 second timeout aborts the request and retains localized timeout feedback', async () => {
  fetch.mockImplementation((url, options) => new Promise((resolve, reject) => {
    options.signal.addEventListener('abort', () => reject(new DOMException('timeout', 'AbortError')))
  }))
  const pending = Auth.sendRequest('/verify', 'POST', {}, { timedOut: 'Tiempo agotado' })
  await jest.advanceTimersByTimeAsync(14999)
  expect(fetch.mock.calls[0][1].signal.aborted).toBe(false)
  await jest.advanceTimersByTimeAsync(1)
  await expect(pending).resolves.toMatchObject({ success: false, message: 'Tiempo agotado' })
  expect(fetch.mock.calls[0][1].signal.aborted).toBe(true)
})

test('502 and 503 use the existing bounded backoff before a successful response', async () => {
  fetch.mockResolvedValueOnce({ status: 502 }).mockResolvedValueOnce({ status: 503 })
    .mockResolvedValue({ status: 200, ok: true, json: async () => ({ verified: true }) })
  const pending = Auth.sendRequest('/verify', 'POST')
  await jest.advanceTimersByTimeAsync(499)
  expect(fetch).toHaveBeenCalledTimes(1)
  await jest.advanceTimersByTimeAsync(1)
  expect(fetch).toHaveBeenCalledTimes(2)
  await jest.advanceTimersByTimeAsync(1000)
  await expect(pending).resolves.toMatchObject({ success: true })
  expect(fetch).toHaveBeenCalledTimes(3)
  expect(jest.getTimerCount()).toBe(0)
})
