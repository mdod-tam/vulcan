// Mock @rails/request.js using a factory function to avoid hoisting issues  
jest.mock('@rails/request.js', () => {
  const mockPerform = jest.fn()
  const mockFetchRequestConstructor = jest.fn().mockImplementation(() => ({
    perform: mockPerform
  }))
  
  return {
    FetchRequest: mockFetchRequestConstructor,
    // Export the mocks for test access
    __mockPerform: mockPerform,
    __mockConstructor: mockFetchRequestConstructor
  }
})

import { RailsRequestService, RequestError } from '../../../app/javascript/services/rails_request'

// Get the mocks from the module
const mockModule = require('@rails/request.js')
const mockPerform = mockModule.__mockPerform
const mockFetchRequestConstructor = mockModule.__mockConstructor

describe('RailsRequestService', () => {
  let service
  let mockResponse

  beforeEach(() => {
    service = new RailsRequestService()
    mockResponse = {
      ok: true,
      status: 200,
      headers: {
        get: jest.fn()
      },
      json: jest.fn(),
      text: jest.fn(),
      clone: jest.fn(),
      bodyUsed: false
    }
    
    // Make clone return a copy of the response
    mockResponse.clone.mockReturnValue({
      ...mockResponse,
      clone: jest.fn() // Clone should also be cloneable
    })
    
    // Reset mocks
    mockFetchRequestConstructor.mockClear()
    mockPerform.mockClear()
    
    // Clear active requests
    service.activeRequests.clear()
    
    // Mock console methods
    global.console.error = jest.fn()
    global.console.debug = jest.fn()
    global.console.warn = jest.fn()
  })

  afterEach(() => {
    // Clean up any remaining active requests
    service.cancelAll()
  })

  describe('constructor', () => {
    it('initializes with empty activeRequests Map', () => {
      const newService = new RailsRequestService()
      expect(newService.activeRequests).toBeInstanceOf(Map)
      expect(newService.activeRequests.size).toBe(0)
    })
  })

  describe('perform', () => {
    beforeEach(() => {
      mockPerform.mockResolvedValue(mockResponse)
    })

    it('performs a basic GET request', async () => {
      mockResponse.headers.get.mockReturnValue('application/json')
      const clonedResponse = {
        json: jest.fn().mockResolvedValue({ data: 'test' }),
        text: jest.fn()
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      const result = await service.perform({ url: '/api/test' })

      expect(mockFetchRequestConstructor).toHaveBeenCalledWith(
        'get',
        '/api/test',
        expect.objectContaining({
          signal: expect.any(AbortSignal),
          headers: {}
        })
      )
      expect(result.success).toBe(true)
      expect(result.data).toEqual({ data: 'test' })
    })

    it('performs a POST request with JSON body', async () => {
      const requestBody = { name: 'test', value: 123 }
      mockResponse.headers.get.mockReturnValue('application/json')
      const clonedResponse = {
        json: jest.fn().mockResolvedValue({ success: true }),
        text: jest.fn()
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      await service.perform({
        method: 'post',
        url: '/api/create',
        body: requestBody
      })

      expect(mockFetchRequestConstructor).toHaveBeenCalledWith(
        'post',
        '/api/create',
        expect.objectContaining({
          body: JSON.stringify(requestBody)
        })
      )
    })

    it('performs a request with string body (no JSON conversion)', async () => {
      const requestBody = 'raw string data'
      mockResponse.headers.get.mockReturnValue('text/html')
      const clonedResponse = {
        json: jest.fn(),
        text: jest.fn().mockResolvedValue('<div>success</div>')
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      await service.perform({
        method: 'patch',
        url: '/api/update',
        body: requestBody
      })

      expect(mockFetchRequestConstructor).toHaveBeenCalledWith(
        'patch',
        '/api/update',
        expect.objectContaining({
          body: requestBody
        })
      )
    })

    it('includes custom headers', async () => {
      const customHeaders = { 'X-Custom': 'value', 'Accept': 'application/json' }
      mockResponse.headers.get.mockReturnValue('application/json')
      const clonedResponse = {
        json: jest.fn().mockResolvedValue({}),
        text: jest.fn()
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      await service.perform({
        url: '/api/test',
        headers: customHeaders
      })

      expect(mockFetchRequestConstructor).toHaveBeenCalledWith(
        'get',
        '/api/test',
        expect.objectContaining({
          headers: customHeaders
        })
      )
    })

    it('tracks requests with keys for cancellation', async () => {
      mockResponse.headers.get.mockReturnValue('application/json')
      const clonedResponse = {
        json: jest.fn().mockResolvedValue({}),
        text: jest.fn()
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      const requestPromise = service.perform({
        url: '/api/test',
        key: 'test-request'
      })

      // Request should be tracked while in progress
      expect(service.activeRequests.has('test-request')).toBe(true)

      await requestPromise

      // Request should be cleaned up after completion
      expect(service.activeRequests.has('test-request')).toBe(false)
    })

    it('cancels existing request with same key', async () => {
      const abortSpy = jest.fn()
      const mockController = { abort: abortSpy }
      service.activeRequests.set('duplicate-key', mockController)

      mockResponse.headers.get.mockReturnValue('application/json')
      const clonedResponse = {
        json: jest.fn().mockResolvedValue({}),
        text: jest.fn()
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      await service.perform({
        url: '/api/test',
        key: 'duplicate-key'
      })

      expect(abortSpy).toHaveBeenCalled()
    })

    it('uses provided AbortSignal instead of creating new one', async () => {
      const customController = new AbortController()
      const customSignal = customController.signal

      mockResponse.headers.get.mockReturnValue('application/json')
      const clonedResponse = {
        json: jest.fn().mockResolvedValue({}),
        text: jest.fn()
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      await service.perform({
        url: '/api/test',
        signal: customSignal
      })

      expect(mockFetchRequestConstructor).toHaveBeenCalledWith(
        'get',
        '/api/test',
        expect.objectContaining({
          signal: customSignal
        })
      )
    })

    it('defaults to text parsing for unknown content types', async () => {
      mockResponse.headers.get.mockReturnValue('application/octet-stream')
      const clonedResponse = {
        json: jest.fn().mockRejectedValue(new Error('Not JSON')),
        text: jest.fn().mockResolvedValue('raw data')
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      const result = await service.perform({ url: '/api/test' })

      expect(result.data).toBe('raw data')
    })

    it('handles @rails/request.js response where json is already a Promise', async () => {
      // Simulate @rails/request.js response structure
      const railsResponse = {
        ok: true,
        status: 200,
        headers: { get: () => 'application/json' },
        json: Promise.resolve({ message: 'success from rails request' }),
        bodyUsed: false,
        clone: jest.fn()
      }
      
      mockPerform.mockResolvedValue(railsResponse)

      const result = await service.perform({ url: '/api/test' })

      expect(result.data).toEqual({ message: 'success from rails request' })
    })

    it('handles @rails/request.js response where text is already a Promise', async () => {
      // For HTML responses, the implementation will check if bodyUsed is true first,
      // then fall through to clone() and use clone.text()
      // Since we're testing the @rails/request.js case where text is a Promise,
      // we need to ensure the response looks like it came from @rails/request.js
      const railsResponse = {
        ok: true,
        status: 200,
        headers: { get: () => 'text/html' },
        text: Promise.resolve('<div>HTML from rails request</div>'),
        bodyUsed: false,
        clone: jest.fn().mockReturnValue({
          json: jest.fn().mockRejectedValue(new Error('Not JSON')),
          text: jest.fn().mockResolvedValue('<div>HTML from rails request</div>')
        })
      }
      
      mockPerform.mockResolvedValue(railsResponse)

      const result = await service.perform({ url: '/api/test' })

      // The implementation will use clone().text() for HTML responses
      expect(result.data).toBe('<div>HTML from rails request</div>')
      expect(railsResponse.clone).toHaveBeenCalled()
    })
  })

  describe('error handling', () => {
    it('throws RequestError for HTTP error responses', async () => {
      mockResponse.ok = false
      mockResponse.status = 422
      mockResponse.headers.get.mockReturnValue('application/json')
      mockResponse.json.mockResolvedValue({
        error: 'Validation failed',
        errors: { name: ['is required'] }
      })

      mockPerform.mockResolvedValue(mockResponse)

      await expect(service.perform({ url: '/api/test' }))
        .rejects
        .toThrow(RequestError)

      try {
        await service.perform({ url: '/api/test' })
      } catch (error) {
        expect(error.status).toBe(422)
        expect(error.data).toEqual({
          error: 'Validation failed',
          errors: { name: ['is required'] }
        })
      }
    })

    it('handles AbortError gracefully', async () => {
      const abortError = new Error('The operation was aborted')
      abortError.name = 'AbortError'

      mockPerform.mockRejectedValue(abortError)

      const result = await service.perform({ url: '/api/test' })

      expect(result.success).toBe(false)
      expect(result.aborted).toBe(true)
    })

    it('cleans up tracked requests on error', async () => {
      const error = new Error('Network error')
      mockPerform.mockRejectedValue(error)

      await expect(service.perform({
        url: '/api/test',
        key: 'error-request'
      })).rejects.toThrow(error)

      expect(service.activeRequests.has('error-request')).toBe(false)
    })
  })

  describe('response parsing', () => {
    beforeEach(() => {
      mockPerform.mockResolvedValue(mockResponse)
    })

    it('parses JSON responses', async () => {
      mockResponse.headers.get.mockReturnValue('application/json')
      const clonedResponse = {
        json: jest.fn().mockResolvedValue({ message: 'success' }),
        text: jest.fn()
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      const result = await service.perform({ url: '/api/test' })

      expect(result.data).toEqual({ message: 'success' })
      expect(clonedResponse.json).toHaveBeenCalled()
    })

    it('parses HTML responses', async () => {
      mockResponse.headers.get.mockReturnValue('text/html')
      const clonedResponse = {
        json: jest.fn(),
        text: jest.fn().mockResolvedValue('<div>Hello</div>')
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      const result = await service.perform({ url: '/api/test' })

      expect(result.data).toBe('<div>Hello</div>')
      expect(clonedResponse.text).toHaveBeenCalled()
    })

    it('parses Turbo Stream responses', async () => {
      mockResponse.headers.get.mockReturnValue('text/vnd.turbo-stream.html')
      const clonedResponse = {
        json: jest.fn(),
        text: jest.fn().mockResolvedValue('<turbo-stream action="replace">...</turbo-stream>')
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      const result = await service.perform({ url: '/api/test' })

      expect(result.data).toBe('<turbo-stream action="replace">...</turbo-stream>')
      expect(clonedResponse.text).toHaveBeenCalled()
    })

    it('defaults to text parsing for unknown content types', async () => {
      mockResponse.headers.get.mockReturnValue('application/octet-stream')
      const clonedResponse = {
        json: jest.fn().mockRejectedValue(new Error('Not JSON')),
        text: jest.fn().mockResolvedValue('raw data')
      }
      mockResponse.clone.mockReturnValue(clonedResponse)

      const result = await service.perform({ url: '/api/test' })

      expect(result.data).toBe('raw data')
    })
  })

  describe('cancel', () => {
    it('cancels a tracked request by key', () => {
      const abortSpy = jest.fn()
      const mockController = { abort: abortSpy }
      service.activeRequests.set('test-request', mockController)

      service.cancel('test-request')

      expect(abortSpy).toHaveBeenCalled()
      expect(service.activeRequests.has('test-request')).toBe(false)
    })

    it('does nothing for non-existent keys', () => {
      expect(() => service.cancel('non-existent')).not.toThrow()
    })
  })

  describe('cancelAll', () => {
    it('cancels all active requests', () => {
      const abortSpy1 = jest.fn()
      const abortSpy2 = jest.fn()
      const mockController1 = { abort: abortSpy1 }
      const mockController2 = { abort: abortSpy2 }

      service.activeRequests.set('request1', mockController1)
      service.activeRequests.set('request2', mockController2)

      service.cancelAll()

      expect(abortSpy1).toHaveBeenCalled()
      expect(abortSpy2).toHaveBeenCalled()
      expect(service.activeRequests.size).toBe(0)
    })
  })

  describe('parseErrorResponse', () => {
    it('parses JSON error responses', async () => {
      const errorResponse = {
        headers: { get: () => 'application/json' },
        json: jest.fn().mockResolvedValue({ error: 'Bad request' })
      }

      const result = await service.parseErrorResponse(errorResponse)

      expect(result).toEqual({ error: 'Bad request' })
    })

    it('returns generic error for non-JSON responses', async () => {
      const errorResponse = {
        status: 500,
        headers: { get: () => 'text/html' }
      }

      const result = await service.parseErrorResponse(errorResponse)

      expect(result).toEqual({ error: 'Server error: 500' })
    })

    it('handles JSON parsing errors gracefully', async () => {
      const errorResponse = {
        status: 422,
        headers: { get: () => 'application/json' },
        json: jest.fn().mockRejectedValue(new Error('Invalid JSON'))
      }

      const result = await service.parseErrorResponse(errorResponse)

      expect(result).toEqual({ error: 'Server error: 422' })
    })

    it('handles @rails/request.js error response where json is already a Promise', async () => {
      const errorResponse = {
        status: 422,
        headers: { get: () => 'application/json' },
        json: Promise.resolve({ error: 'Validation failed from rails request' })
      }

      const result = await service.parseErrorResponse(errorResponse)

      expect(result).toEqual({ error: 'Validation failed from rails request' })
    })
  })

  describe('tryShowFlash', () => {
    it('is a no-op and returns false (native Rails flash)', () => {
      const result = service.tryShowFlash('Test message', 'error')
      expect(result).toBe(false)
    })
  })

  describe('handleError', () => {
    let tryShowFlashSpy

    beforeEach(() => {
      tryShowFlashSpy = jest.spyOn(service, 'tryShowFlash').mockReturnValue(true)
    })

    afterEach(() => {
      tryShowFlashSpy.mockRestore()
    })

    it('logs error when logError is true', () => {
      const error = new Error('Test error')

      service.handleError(error, { logError: true })

      expect(global.console.error).toHaveBeenCalledWith('Rails request error:', error)
    })

    it('does not log error when logError is false', () => {
      const error = new Error('Test error')

      service.handleError(error, { logError: false })

      expect(global.console.error).not.toHaveBeenCalled()
    })

    it('shows flash message when showFlash is true and error has message', () => {
      const error = new Error('Test error message')

      service.handleError(error, { showFlash: true })

      expect(tryShowFlashSpy).toHaveBeenCalledWith('Test error message', 'error')
    })

    it('does not show flash when showFlash is false', () => {
      const error = new Error('Test error message')

      service.handleError(error, { showFlash: false })

      expect(tryShowFlashSpy).not.toHaveBeenCalled()
    })

    it('warns in development when flash message fails to show', () => {
      // Mock development environment
      const originalEnv = process.env.NODE_ENV
      process.env.NODE_ENV = 'development'

      tryShowFlashSpy.mockReturnValue(false)
      const error = new Error('Test error message')

      service.handleError(error, { showFlash: true })

      expect(global.console.warn).toHaveBeenCalledWith(
        'Flash message not shown (no flash controller):',
        'Test error message'
      )

      // Restore environment
      process.env.NODE_ENV = originalEnv
    })
  })
})

describe('RequestError', () => {
  it('creates error with message, status, and data', () => {
    const error = new RequestError('Test error', 422, { field: 'invalid' })

    expect(error.message).toBe('Test error')
    expect(error.name).toBe('RequestError')
    expect(error.status).toBe(422)
    expect(error.data).toEqual({ field: 'invalid' })
  })

  it('defaults data to empty object', () => {
    const error = new RequestError('Test error', 500)

    expect(error.data).toEqual({})
  })
}) 