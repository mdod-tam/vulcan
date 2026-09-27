jest.mock('@rails/request.js', () => jest.requireActual('@rails/request.js/src/fetch_request'))

import { RailsRequestService, RequestError } from '../../../app/javascript/services/rails_request'

// The installed FetchRequest/FetchResponse run unchanged; only the network is replaced.
function response(body, status = 200, type = 'application/json') {
  let consumed = false
  const read = () => {
    if (consumed) throw new TypeError('Body already consumed')
    consumed = true
    return body
  }
  return {
    status, ok: status >= 200 && status < 300,
    headers: { get: key => key.toLowerCase() === 'content-type' ? type : null },
    json: jest.fn(async () => JSON.parse(read())),
    text: jest.fn(async () => read())
  }
}

let service
beforeEach(() => {
  service = new RailsRequestService()
  window.fetch = jest.fn()
  document.head.innerHTML = '<meta name="csrf-token" content="test-token">'
})
afterEach(() => {
  for (const key of service.activeRequests.keys()) service.cancel(key)
  document.head.innerHTML = ''
  delete window.Turbo
})

test('installed request library sends same-origin CSRF and JSON and caches its parsed response', async () => {
  const raw = response('{"saved":true}')
  fetch.mockResolvedValue(raw)
  const result = await service.perform({ method: 'patch', url: '/save', body: { enabled: false } })
  expect(fetch).toHaveBeenCalledWith('/save', expect.objectContaining({
    method: 'PATCH', credentials: 'same-origin', body: '{"enabled":false}',
    headers: expect.objectContaining({ 'X-CSRF-Token': 'test-token', 'Content-Type': 'application/json' })
  }))
  expect(result).toMatchObject({ success: true, data: { saved: true } })
  expect(await service.parseSuccessResponse(result.response)).toEqual({ saved: true })
  expect(raw.json).toHaveBeenCalledTimes(1)
})

test('keepalive reaches fetch only when requested so unload-time saves can finish', async () => {
  fetch.mockResolvedValue(response('{}'))
  await service.perform({ method: 'patch', url: '/save', body: {}, keepalive: true })
  await service.perform({ method: 'patch', url: '/save', body: {} })
  expect(fetch.mock.calls.map(([, options]) => options.keepalive)).toEqual([true, false])
})

test('HTTP JSON errors preserve their status and validation data', async () => {
  fetch.mockResolvedValue(response('{"errors":{"name":["Required"]}}', 422))
  await expect(service.perform({ url: '/save' })).rejects.toMatchObject({
    name: 'RequestError', status: 422, data: { errors: { name: ['Required'] } }
  })
})

test.each(['abort', 'success', 'failure'])('an older %s cannot erase the newer same-key cancellation handle', async outcome => {
  let firstResolve, firstReject
  fetch.mockImplementationOnce(() => new Promise((resolve, reject) => { firstResolve = resolve; firstReject = reject }))
    .mockImplementationOnce((url, options) => new Promise((resolve, reject) => {
      options.signal.addEventListener('abort', () => reject(new DOMException('Cancelled', 'AbortError')))
    }))
  const first = service.perform({ url: '/old', key: 'field' }).catch(error => error)
  const second = service.perform({ url: '/new', key: 'field' })
  if (outcome === 'success') firstResolve(response('{}'))
  else firstReject(outcome === 'abort' ? new DOMException('Cancelled', 'AbortError') : new Error('offline'))
  await first
  service.cancel('field')
  expect(fetch.mock.calls[1][1].signal.aborted).toBe(true)
  await expect(second).resolves.toEqual({ success: false, aborted: true })
})

test.each([
  ['text/html', '<p>HTML response</p>', '<p>HTML response</p>'],
  ['application/octet-stream', 'raw data', 'raw data'],
  ['application/octet-stream', '{"value":3}', { value: 3 }],
  ['application/json', 'malformed', {}]
])('parses %s without assuming a native fetch response interface', async (type, body, expected) => {
  fetch.mockResolvedValue(response(body, 200, type))
  const result = await service.perform({ url: '/data' })
  expect(result.data).toEqual(expected)
})

test('a Turbo response already read by the library is not read again', async () => {
  window.Turbo = { renderStreamMessage: jest.fn() }
  const raw = response('<turbo-stream></turbo-stream>', 200, 'text/vnd.turbo-stream.html')
  fetch.mockResolvedValue(raw)
  const result = await service.perform({ url: '/data' })
  expect(result.data).toBe('<turbo-stream></turbo-stream>')
  expect(window.Turbo.renderStreamMessage).toHaveBeenCalledWith(result.data)
  expect(raw.text).toHaveBeenCalledTimes(1)
})

test.each(['text/html', 'application/json'])('non-OK malformed %s stays a generic HTTP error', async type => {
  fetch.mockResolvedValue(response('Private server diagnostics', 500, type))
  await expect(service.perform({ url: '/save' })).rejects.toMatchObject({
    name: 'RequestError', status: 500, message: 'Server error: 500', data: { error: 'Server error: 500' }
  })
})

test('network failures stay distinct from cancellation and release their tracking', async () => {
  const error = new TypeError('offline')
  fetch.mockRejectedValue(error)
  await expect(service.perform({ url: '/save', key: 'field' })).rejects.toBe(error)
  expect(service.activeRequests.size).toBe(0)
  expect(() => service.cancel('missing')).not.toThrow()
})

test('caller headers signals and raw string bodies pass through without cross-origin CSRF', async () => {
  const controller = new AbortController()
  fetch.mockResolvedValue(response('{}'))
  await service.perform({ url: 'https://external.test/save', method: 'post', body: 'raw',
    signal: controller.signal, headers: { Accept: 'application/json', 'X-Custom': 'value' } })
  const options = fetch.mock.calls[0][1]
  expect(options.signal).toBe(controller.signal)
  expect(options.body).toBe('raw')
  expect(options.headers).toMatchObject({ Accept: 'application/json', 'X-Custom': 'value' })
  expect(options.headers['X-CSRF-Token']).toBeUndefined()
})

test('RequestError retains an optional data object', () => {
  expect(new RequestError('failed', 500)).toMatchObject({ name: 'RequestError', message: 'failed', status: 500, data: {} })
})
