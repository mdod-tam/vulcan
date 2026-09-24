import { Application } from '@hotwired/stimulus'
import UserSearchController from 'controllers/admin/user_search_controller'

const settle = async () => { for (let i = 0; i < 6; i++) await Promise.resolve() }
let application, element, input, controller, navigate

beforeEach(async () => {
  jest.useFakeTimers()
  document.body.innerHTML = `<div data-controller="admin-user-search"
    data-admin-user-search-search-url-value="/admin/users/search"
    data-admin-user-search-role-value="guardian">
    <input data-admin-user-search-target="searchInput" data-action="input->admin-user-search#performSearch">
    <turbo-frame id="guardian_search_results" data-admin-user-search-target="searchResults"></turbo-frame>
    <button data-action="admin-user-search#clearSearchAndShowForm">Clear</button>
  </div>`
  application = Application.start()
  application.register('admin-user-search', UserSearchController)
  await settle()
  element = document.querySelector('[data-controller]')
  input = element.querySelector('input')
  controller = application.getControllerForElementAndIdentifier(element, 'admin-user-search')
  navigate = jest.spyOn(controller, 'navigateToSearch')
})

afterEach(async () => {
  document.body.innerHTML = ''
  await settle()
  application.stop()
  jest.useRealTimers()
})

function type(value) {
  input.value = value
  input.dispatchEvent(new Event('input', { bubbles: true }))
}

test.each(['guardian', 'constituent'])('one trailing frame navigation for a %s typing burst', role => {
  controller.roleValue = role
  type(' J')
  jest.advanceTimersByTime(100)
  type(' Jo')
  jest.advanceTimersByTime(100)
  type(' John ')
  jest.advanceTimersByTime(299)
  expect(navigate).not.toHaveBeenCalled()
  jest.advanceTimersByTime(1)
  expect(navigate).toHaveBeenCalledTimes(1)
  expect(element.querySelector('turbo-frame').src).toBe(`/admin/users/search?q=John&role=${role}&frame_id=guardian_search_results`)
})

test('clear cancels a queued search and preserves selected guardian', () => {
  type('John')
  element.querySelector('button').click()
  jest.advanceTimersByTime(300)
  expect(navigate).not.toHaveBeenCalled()
  expect(input.value).toBe('')
  expect(element.querySelector('turbo-frame').hasAttribute('src')).toBe(false)
})

test('disconnect cancels queued work and reconnect has one event path', async () => {
  type('obsolete')
  element.remove()
  await settle()
  jest.advanceTimersByTime(300)
  expect(navigate).not.toHaveBeenCalled()
  for (let i = 0; i < 3; i++) {
    document.body.append(element)
    await settle()
    type('new search')
    jest.advanceTimersByTime(300)
    expect(navigate).toHaveBeenCalledTimes(i + 1)
    element.remove()
    await settle()
  }
})
