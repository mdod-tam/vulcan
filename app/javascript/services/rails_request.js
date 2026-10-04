import { FetchRequest } from "@rails/request.js"

/**
 * Shares request cancellation, error handling, and response parsing.
 */
export class RailsRequestService {
  constructor() {
    this.activeRequests = new Map()
  }

  /**
   * Returns a success envelope or an aborted result. HTTP and network failures raise errors.
   * @param {Object} options Request configuration
   * @returns {Promise<Object>} Success, data, and response, or success: false and aborted: true
   */
  async perform({ 
    method = 'get',
    url,
    body = null,
    key = null, // Tracks cancellation when the service owns the AbortController
    signal = null,
    headers = {},
    keepalive = false // Permits the request to continue after the page unloads
  }) {
    if (key && this.activeRequests.has(key)) {
      this.cancel(key)
    }

    const controller = signal ? null : new AbortController()
    const finalSignal = signal || controller.signal

    if (key && controller) {
      this.activeRequests.set(key, controller)
    }

    try {
      const requestOptions = {
        signal: finalSignal,
        headers,
        keepalive
      }

      if (body) {
        requestOptions.body = typeof body === 'string' ? body : JSON.stringify(body)
      }

      const request = new FetchRequest(method, url, requestOptions)
      
      const response = await request.perform()

      if (!response.ok) {
        const errorData = await this.parseErrorResponse(response)
        throw new RequestError(errorData?.error || `HTTP ${response.statusCode}`, response.statusCode, errorData)
      }

      const data = await this.parseSuccessResponse(response)
      
      if (key && this.activeRequests.get(key) === controller) {
        this.activeRequests.delete(key)
      }

      return { success: true, data, response }

    } catch (error) {
      if (key && this.activeRequests.get(key) === controller) {
        this.activeRequests.delete(key)
      }

      if (error.name === 'AbortError') {
        return { success: false, aborted: true }
      }

      throw error
    }
  }

  /**
   * Cancel a tracked request
   * @param {string} key Request key
   */
  cancel(key) {
    const controller = this.activeRequests.get(key)
    if (controller) {
      controller.abort()
      this.activeRequests.delete(key)
    }
  }

  async parseSuccessResponse(response) {
    // FetchResponse caches its body promises, including text already read by Turbo.
    const isJson = /^application\/.*json$/.test(response.contentType)
    try {
      if (isJson) return await response.json

      const text = await response.text
      if (response.contentType.startsWith('text/')) return text
      try {
        return JSON.parse(text)
      } catch (_) {
        return text
      }
    } catch (error) {
      console.warn('RailsRequestService.parseSuccessResponse failed:', error.message)
      return isJson ? {} : ''
    }
  }

  async parseErrorResponse(response) {
    if (/^application\/.*json$/.test(response.contentType)) {
      try {
        return await response.json
      } catch (_) {
        // A proxy or malformed body must not expose server details as feedback.
      }
    }
    return { error: `Server error: ${response.statusCode}` }
  }
}

export class RequestError extends Error {
  constructor(message, status, data = {}) {
    super(message)
    this.name = 'RequestError'
    this.status = status
    this.data = data
  }
}

export const railsRequest = new RailsRequestService()

// Outside production, reject lowercase html in the singleton's explicit Accept header.
if (process.env.NODE_ENV !== 'production') {
  const originalPerform = railsRequest.perform.bind(railsRequest)
  railsRequest.perform = async (opts = {}) => {
    const accept = (opts.headers && opts.headers.Accept) || ""
    if (/html/.test(accept)) {
      throw new Error("railsRequest rejects an explicit Accept header containing lowercase html outside production.")
    }
    return originalPerform(opts)
  }
}
