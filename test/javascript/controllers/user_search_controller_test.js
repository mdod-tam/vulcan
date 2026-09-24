import UserSearchController from "../../../app/javascript/controllers/admin/user_search_controller"

// Mock the rails request service
jest.mock('../../../app/javascript/services/rails_request', () => ({
  railsRequest: {
    perform: jest.fn(),
    cancel: jest.fn()
  }
}))

// Mock the visibility utility
jest.mock('../../../app/javascript/utils/visibility', () => ({
  setVisible: jest.fn((element, visible) => {
    if (visible) {
      element.classList.remove('hidden')
    } else {
      element.classList.add('hidden')
    }
  })
}))

import { railsRequest } from "../../../app/javascript/services/rails_request"

// Mock fetch
global.fetch = jest.fn()

describe("UserSearchController", () => {
  let controller, fixture
  
  beforeEach(() => {
    // Set up DOM fixture for guardian creation
    document.body.innerHTML = `
      <div id="test-container">
        <input type="text" id="searchInput" placeholder="Search guardians..." />
        
        <div id="searchResults" class="hidden"></div>
        
        <div data-controller="admin-user-search"
             data-admin-user-search-search-url-value="/admin/users/search"
             data-admin-user-search-create-user-url-value="/admin/users"
             data-admin-user-search-role-value="guardian">
          <input type="text" name="guardian_attributes[first_name]" value="" />
          <input type="text" name="guardian_attributes[last_name]" value="" />
          <input type="email" name="guardian_attributes[email]" value="" />
          <input type="tel" name="guardian_attributes[phone]" value="" />
          <input type="text" name="guardian_attributes[physical_address_1]" value="" />
          <input type="text" name="guardian_attributes[city]" value="" />
          <select name="guardian_attributes[state]">
            <option value="MD">Maryland</option>
          </select>
          <input type="text" name="guardian_attributes[zip_code]" value="" />
          <input type="date" name="guardian_attributes[date_of_birth]" value="" />
          <input type="radio" name="guardian_attributes[phone_type]" value="mobile" checked />
          <input type="radio" name="guardian_attributes[communication_preference]" value="email" checked />

          <section id="identityReviewPanel" class="hidden">
            <h4 id="identityReviewHeading" tabindex="-1"></h4>
            <p id="identityReviewBody"></p>
            <ul id="identityReviewCandidates"></ul>
            <div id="identityReviewOverride" class="hidden">
              <button type="button" id="identityReviewOverrideButton">Create a new guardian</button>
            </div>
          </section>
          <p id="identityReviewStatus" aria-live="polite"></p>
          
          <button type="button" id="createButton">Save Guardian</button>
        </div>
        
        <button type="button" id="clearSearchButton">Clear Search</button>
      </div>
    `
    
    fixture = document.querySelector('#test-container')
    
    // Create controller instance directly
    controller = new UserSearchController()
    
    // Mock controller properties using Object.defineProperty
    Object.defineProperty(controller, 'element', {
      value: fixture,
      writable: false,
      configurable: true
    })
    
    // Mock target properties
    Object.defineProperty(controller, 'searchInputTarget', {
      value: fixture.querySelector('#searchInput'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'searchResultsTarget', {
      value: fixture.querySelector('#searchResults'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'guardianFormTarget', {
      value: fixture.querySelector('[data-controller="admin-user-search"]'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'createButtonTarget', {
      value: fixture.querySelector('#createButton'),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'guardianReviewTarget', {
      value: fixture.querySelector('#identityReviewPanel'), configurable: true
    })

    Object.defineProperty(controller, 'clearSearchButtonTarget', {
      value: fixture.querySelector('#clearSearchButton'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'guardianFormFieldTargets', {
      value: Array.from(fixture.querySelectorAll('input[name^="guardian_attributes"], select[name^="guardian_attributes"]')),
      writable: false,
      configurable: true
    })
    
    // Mock the has target methods
    Object.defineProperty(controller, 'hasSearchInputTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasSearchResultsTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasGuardianFormTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasCreateButtonTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasClearSearchButtonTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasGuardianFormFieldTargets', {
      value: true,
      writable: false,
      configurable: true
    })
    
    // Mock data values
    Object.defineProperty(controller, 'searchUrlValue', {
      value: '/admin/users/search',
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'createUserUrlValue', {
      value: '/admin/users',
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'roleValue', {
      value: 'guardian',
      writable: false,
      configurable: true
    })
    
    // Mock the registered controller identifier
    Object.defineProperty(controller, 'identifier', {
      value: 'admin--user-search',
      writable: false,
      configurable: true
    })
    
    // Mock outlet properties (initially no outlets)
    Object.defineProperty(controller, 'hasGuardianPickerOutlet', {
      get: () => false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasFlashOutlet', {
      get: () => false,
      configurable: true
    })
    
    // Mock the dispatch method
    controller.dispatch = jest.fn()
    
    controller.showErrorNotification = jest.fn()
    controller.showSuccessNotification = jest.fn()
    
    // Call connect manually
    controller.connect()
  })
  
  afterEach(() => {
    if (controller && controller.disconnect) {
      controller.disconnect()
    }
    document.body.innerHTML = ""
    jest.clearAllMocks()
  })
  
  // Helper function to mock the guardian picker outlet
  function createMockGuardianPickerOutlet() {
    const mockOutlet = {
      selectGuardian: jest.fn(),
      clearSelection: jest.fn()
    }
    
    // Mock the hasGuardianPickerOutlet getter
    Object.defineProperty(controller, 'hasGuardianPickerOutlet', {
      get: () => true,
      configurable: true
    })
    
    // Mock the guardianPickerOutlet getter
    Object.defineProperty(controller, 'guardianPickerOutlet', {
      get: () => mockOutlet,
      configurable: true
    })
    
    return mockOutlet
  }
  
  describe("guardian creation flow", () => {
    let mockedOutlet
    
    beforeEach(() => {
      mockedOutlet = createMockGuardianPickerOutlet()
      
      // Fill form with test data
      fixture.querySelector('[name="guardian_attributes[first_name]"]').value = "John"
      fixture.querySelector('[name="guardian_attributes[last_name]"]').value = "Doe"
      fixture.querySelector('[name="guardian_attributes[email]"]').value = "john@example.com"
      fixture.querySelector('[name="guardian_attributes[phone]"]').value = "555-1234"
      fixture.querySelector('[name="guardian_attributes[physical_address_1]"]').value = "123 Main St"
      fixture.querySelector('[name="guardian_attributes[city]"]').value = "Baltimore"
      fixture.querySelector('[name="guardian_attributes[zip_code]"]').value = "21201"
      fixture.querySelector('[name="guardian_attributes[date_of_birth]"]').value = "1980-01-01"
    })
    
    it("posts the current guardian fields and uses the successful server selection", async () => {
      const data = { user: { id: 123, first_name: "John", last_name: "Doe" } }
      global.fetch.mockResolvedValue({ ok: true, json: async () => data })
      controller.handleSuccess = jest.fn()
      await controller.createGuardian({ currentTarget: fixture.querySelector('#createButton'), preventDefault: jest.fn() })
      const [url, request] = global.fetch.mock.calls[0]
      expect(url).toBe('/admin/users')
      expect(request.body.get('first_name')).toBe('John')
      expect(request.body.get('email')).toBe('john@example.com')
      expect(controller.handleSuccess).toHaveBeenCalledWith(data)
    })

    it("renders the server review and returns the explicit choice with the current form", async () => {
      global.fetch.mockResolvedValue({
        ok: false, status: 422, text: async () =>
          '<h4 tabindex="-1">Review possible matches</h4><input name="guardian_identity_review_receipt" value="receipt"><textarea name="guardian_identity_rationale">Different guardian</textarea><button name="identity_determination" value="keep_separate">Create new guardian</button>'
      })
      await controller.createGuardian({ currentTarget: fixture.querySelector('#createButton'), preventDefault: jest.fn() })
      expect(document.activeElement.textContent).toBe('Review possible matches')
      expect(fixture.querySelector('[name="guardian_attributes[first_name]"]').value).toBe('John')
      global.fetch.mockResolvedValue({ ok: true, json: async () => ({ user: { id: 123 } }) })
      controller.handleSuccess = jest.fn()
      const choice = controller.guardianReviewTarget.querySelector('button')
      await controller.createGuardian({ currentTarget: choice, preventDefault: jest.fn() })
      const request = global.fetch.mock.calls[1][1]
      expect(request.body.get('identity_review_receipt')).toBe('receipt')
      expect(request.body.get('identity_determination')).toBe('keep_separate')
      expect(request.body.get('identity_rationale')).toBe('Different guardian')
      expect(controller.guardianReviewTarget.children).toHaveLength(0)
    })

    it("restores the clicked button after a transport error", async () => {
      global.fetch.mockRejectedValue(new Error('offline'))
      controller.showGeneralError = jest.fn()
      const button = fixture.querySelector('#createButton')
      const text = button.textContent
      await controller.createGuardian({ currentTarget: button, preventDefault: jest.fn() })
      expect(button.disabled).toBe(false)
      expect(button.textContent).toBe(text)
      expect(controller.showGeneralError).toHaveBeenCalled()
    })

    it('validates required fields, then submits corrected inputs and selects the returned guardian', async () => {
      Element.prototype.scrollIntoView = jest.fn()
      const first = fixture.querySelector('[name="guardian_attributes[first_name]"]')
      first.value = ''
      const event = { currentTarget: fixture.querySelector('#createButton'), preventDefault: jest.fn() }
      await controller.createGuardian(event)
      expect(fetch).not.toHaveBeenCalled()
      expect(document.activeElement).toBe(first)
      expect(fixture.textContent).toContain('First name is required')
      first.value = 'Corrected'
      fetch.mockResolvedValue({ ok: true, json: async () => ({ user: { id: 45, first_name: 'Corrected', last_name: '<Guardian>' } }) })
      await controller.createGuardian(event)
      expect(fetch.mock.calls[0][1].body.get('first_name')).toBe('Corrected')
      expect(fixture.textContent).not.toContain('First name is required')
      expect(mockedOutlet.selectGuardian).toHaveBeenCalledWith('45', expect.stringContaining('Corrected &lt;Guardian&gt;'))
      expect(mockedOutlet.clearSelection).not.toHaveBeenCalled()
    })

    it('submits no-contact flags without inventing contact values', async () => {
      for (const [field, flag] of [['email', 'email_address'], ['phone', 'phone_number']]) {
        fixture.querySelector(`[name="guardian_attributes[${field}]"]`).value = ''
        const checkbox = document.createElement('input')
        checkbox.type = 'checkbox'
        checkbox.name = `guardian_no_${flag}`
        checkbox.checked = true
        fixture.appendChild(checkbox)
      }
      fetch.mockResolvedValue({ ok: true, json: async () => ({ user: { id: 45, first_name: 'John', last_name: 'Doe' } }) })
      await controller.createGuardian({ currentTarget: fixture.querySelector('#createButton'), preventDefault: jest.fn() })
      const body = fetch.mock.calls[0][1].body
      expect(body.get('guardian_no_email_address')).toBe('1')
      expect(body.get('guardian_no_phone_number')).toBe('1')
      expect(body.get('email')).toBeNull()
      expect(body.get('phone')).toBeNull()
    })

    it.each([{ status: 401 }, { redirected: true }])('preserves inputs and restores the button on expired session %j', async response => {
      fetch.mockResolvedValue(response)
      const button = fixture.querySelector('#createButton')
      await controller.createGuardian({ currentTarget: button, preventDefault: jest.fn() })
      expect(fixture.textContent).toContain('Your session expired.')
      expect(fixture.querySelector('[name="guardian_attributes[email]"]').value).toBe('john@example.com')
      expect(button.disabled).toBe(false)
      expect(mockedOutlet.selectGuardian).not.toHaveBeenCalled()
    })

    it("builds correct user display HTML", () => {
      const userData = {
        userEmail: "john@example.com",
        userPhone: "555-1234",
        userAddress1: "123 Main St",
        userCity: "Baltimore",
        userState: "MD",
        userZip: "21201",
        userDependentsCount: "2"
      }
      
      const html = controller.buildUserDisplayHTML("John Doe", userData)
      
      expect(html).toContain("John Doe")
      expect(html).toContain("john@example.com")
      expect(html).toContain("555-1234")
      expect(html).toContain("123 Main St")
      expect(html).toContain("Baltimore, MD, 21201")
    })
    
    it("escapes HTML in user display for security", () => {
      const userData = {
        userEmail: "john@example.com",
        userPhone: "555-1234"
      }
      
      // Test that escapeHtml method works correctly
      const maliciousName = "<script>alert('xss')</script> Doe"
      const escapedName = controller.escapeHtml(maliciousName)
      expect(escapedName).not.toContain("<script>")
      expect(escapedName).toContain("&lt;script&gt;")
      
      // Test that buildUserDisplayHTML uses the escaped name correctly
      const html = controller.buildUserDisplayHTML(escapedName, userData)
      expect(html).not.toContain("<script>")
      expect(html).toContain("&lt;script&gt;")
    })
  })
  
  describe("search functionality", () => {
    it("navigates after the search delay", async () => {
      jest.useFakeTimers()
      const searchInput = fixture.querySelector('#searchInput')
      searchInput.value = "John"
      
      const event = { target: searchInput }
      controller.performSearch(event)
      jest.advanceTimersByTime(300)
      jest.useRealTimers()
      
      // Verify that the turbo frame's src was set to trigger navigation
      // The controller uses the searchResultsTarget directly
      expect(controller.searchResultsTarget.src).toBe(
        '/admin/users/search?q=John&role=guardian&frame_id=searchResults'
      )
    })
    
    it("clears results when search is empty", async () => {
      controller.clearResults = jest.fn()
      
      const searchInput = fixture.querySelector('#searchInput')
      searchInput.value = ""
      
      const event = { target: searchInput }
      await controller.performSearch(event)
      
      expect(controller.clearResults).toHaveBeenCalled()
      expect(railsRequest.perform).not.toHaveBeenCalled()
    })
  })
  
  describe("clearSearchAndShowForm", () => {
    it("clears search input and results but preserves guardian selection", () => {
      const mockedOutlet = createMockGuardianPickerOutlet()
      
      const searchInput = fixture.querySelector('#searchInput')
      searchInput.value = "test search"
      
      controller.clearResults = jest.fn()
      
      controller.clearSearchAndShowForm()
      
      expect(searchInput.value).toBe("")
      expect(controller.clearResults).toHaveBeenCalled()
      // Guardian picker outlet should NOT be cleared
      expect(mockedOutlet.clearSelection).not.toHaveBeenCalled()
    })
  })
})
