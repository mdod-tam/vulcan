import { Application } from '@hotwired/stimulus'
import AccessibilityAnnouncerController from 'controllers/ui/accessibility_announcer_controller'

test('each consumer owns its region and cancels pending announcements at disconnect', async () => {
  document.body.innerHTML = '<form id="one" data-controller="announcer"></form><form id="two" data-controller="announcer"></form>'
  const application = Application.start()
  application.register('announcer', AccessibilityAnnouncerController)
  await new Promise(resolve => setTimeout(resolve, 0))
  jest.useFakeTimers()
  const firstElement = document.getElementById('one')
  const secondElement = document.getElementById('two')
  const first = application.getControllerForElementAndIdentifier(firstElement, 'announcer')
  const second = application.getControllerForElementAndIdentifier(secondElement, 'announcer')
  first.announce('obsolete')
  second.announce('current')
  first.disconnect()
  jest.advanceTimersByTime(100)
  expect(firstElement.querySelector('[aria-live]')).toBeNull()
  expect(secondElement.querySelector('[aria-live]').textContent).toBe('current')
  second.disconnect()
  expect(jest.getTimerCount()).toBe(0)
  jest.useRealTimers()
  document.body.innerHTML = ''
  application.stop()
})
