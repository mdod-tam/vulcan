import { FetchRequest } from "@rails/request.js"

/**
 * Centralized Rails 8 request service
 * Handles common patterns: abort controllers, error handling, response parsing
 */
export class RailsRequestService {
  constructor() {
    this.activeRequests = new Map()
  }

  /**
   * Perform a Rails request with standard error handling
   * @param {Object} options Request configuration
   * @returns {Promise<Object>} Parsed response data
   */
  async perform({ 
    method = 'get',
    url,
    body = null,
    key = null, // Optional key for tracking/canceling specific requests
    signal = null,
    headers = {},
    onProgress = null
  }) {
    // Cancel existing request with same key if provided
    if (key && this.activeRequests.has(key)) {
      this.cancel(key)
    }

    // Create abort controller if not provided
    const controller = signal ? null : new AbortController()
    const finalSignal = signal || controller.signal

    if (key && controller) {
      this.activeRequests.set(key, controller)
    }

    try {
      const requestOptions = {
        signal: finalSignal,
        headers
      }

      if (body) {
        requestOptions.body = typeof body === 'string' ? body : JSON.stringify(body)
      }

      const request = new FetchRequest(method, url, requestOptions)
      
      // Add progress handler if provided
      if (onProgress && request.delegate) {
        request.delegate.fetchRequestWillStart = (fetchRequest) => {
          if (fetchRequest.request.body) {
            // Track upload progress if possible
            fetchRequest.request.addEventListener('progress', onProgress)
          }
        }
      }

      const response = await request.perform()

      if (!response.ok) {
        const errorData = await this.parseErrorResponse(response)
        throw new RequestError(errorData.error || `HTTP ${response.status}`, response.status, errorData)
      }

      const data = await this.parseSuccessResponse(response)
      
      // Clean up tracking
      if (key && this.activeRequests.has(key)) {
        this.activeRequests.delete(key)
      }

      return { success: true, data, response }

    } catch (error) {
      // Clean up tracking
      if (key && this.activeRequests.has(key)) {
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

  /**
   * Cancel all active requests
   */
  cancelAll() {
    this.activeRequests.forEach(controller => controller.abort())
    this.activeRequests.clear()
  }

  /**
   * Parse successful response based on content type
   */
  async parseSuccessResponse(response) {
    // Always work on a cloned response so that we never attempt to read
    // the original body more than once.  This avoids the
    // "Failed to execute 'text' on 'Response': body stream already read"
    // error that occurs in headless browsers used in our system tests.
    const contentType = response.headers?.get('content-type') || ''

    // If @rails/request.js has already parsed the body it monkey-patches
    // `response.json` with a *Promise*, **not** the original function – we
    // can just await and return that value with no further processing.
    if (response.json && typeof response.json !== 'function') {
      try {
        return await response.json
      } catch (_) {
        // fall through to safe parsing below
      }
    }

    // If the body has already been consumed we can't read it again – return
    // a sensible empty value so callers can handle it gracefully.
    if (response.bodyUsed) {
      return contentType.includes('application/json') ? {} : ''
    }

    // Clone before reading so that we never consume the original body – this
    // keeps us compatible with any other consumer that might also need it.
    const clone = response.clone()

    try {
      if (contentType.includes('application/json')) {
        return await clone.json()
      }

      if (contentType.includes('text/html') || contentType.includes('text/vnd.turbo-stream.html')) {
        return await clone.text()
      }

      // Unknown/other – attempt JSON then text as a fallback.
      try {
        return await clone.json()
      } catch (_) {
        return await clone.text()
      }

    } catch (error) {
      console.warn('RailsRequestService.parseSuccessResponse failed:', error.message)
      return contentType.includes('application/json') ? {} : ''
    }
  }

  /**
   * Parse error response with fallback
   */
  async parseErrorResponse(response) {
    try {
      // Check if response.json is already a Promise (from @rails/request.js)
      if (response.json && typeof response.json !== 'function') {
        // If response.json is already a Promise, await it
        return await response.json
      }
      
      // Standard fetch Response object handling
      const contentType = response.headers?.get('content-type') || ''
      if (contentType.includes('application/json')) {
        return await response.json()
      }
      return { error: `Server error: ${response.status}` }
    } catch (e) {
      return { error: `Server error: ${response.status}` }
    }
  }

  /**
   * Try to show flash message using the new global AppNotifications service.
   * @param {string} message - Message to display
   * @param {string} type - Message type (success, error, warning, info)
   */
  tryShowFlash(message, type = 'error') {
    // With native Rails flash, rely on server-side flash rendering or Turbo Streams.
    // Client-side fallback stays as a no-op except for dev logging.
    if (process.env.NODE_ENV !== 'production') {
      console.debug('RailsRequestService.tryShowFlash noop (server-rendered flash expected):', message, type)
    }
    return false
  }

  /**
   * Enhanced error handling with flash integration
   * @param {Error} error - Error to handle
   * @param {Object} options - Error handling options
   */
  handleError(error, { showFlash = true, logError = true } = {}) {
    if (logError) {
      console.error('Rails request error:', error)
    }

    // Try to show user-friendly flash message
    if (showFlash && error.message) {
      const shown = this.tryShowFlash(error.message, 'error')
      
      // Fallback to console for development if flash not available
      if (!shown && process.env.NODE_ENV !== 'production') {
        console.warn('Flash message not shown (no flash controller):', error.message)
      }
    }
  }
}

/**
 * Custom error class for request errors
 */
export class RequestError extends Error {
  constructor(message, status, data = {}) {
    super(message)
    this.name = 'RequestError'
    this.status = status
    this.data = data
  }
}

// Export singleton instance
export const railsRequest = new RailsRequestService()

// Development-time guard to prevent HTML requests via railsRequest
if (process.env.NODE_ENV !== 'production') {
  const originalPerform = railsRequest.perform.bind(railsRequest)
  railsRequest.perform = async (opts = {}) => {
    const accept = (opts.headers && opts.headers.Accept) || ""
    if (/html/.test(accept)) {
      throw new Error("Use Turbo frames/streams for HTML, not railsRequest. This service is for JSON APIs only.")
    }
    return originalPerform(opts)
  }
}
