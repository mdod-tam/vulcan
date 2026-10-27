// Stand-in for @rails/request.js.
export class FetchRequest {
  constructor(method, url, options = {}) {
    this.method = method
    this.url = url
    this.options = options
  }

  async perform() {
    // Individual tests replace this.
    return { ok: true, status: 200 }
  }
}

export class FetchResponse {
  constructor(response) {
    this.response = response
  }
}

export class RequestInterceptor {}

export const destroy = jest.fn()
export const get = jest.fn()
export const patch = jest.fn()
export const post = jest.fn()
export const put = jest.fn() 