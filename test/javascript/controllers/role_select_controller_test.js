import { Application } from '@hotwired/stimulus'
import RoleSelectController from 'controllers/admin/role_select_controller'

const WARNING = 'Converting this vendor to another role may lose their W9 and transaction history. Convert anyway?'
let application

const render = async ({ currentRole, warning }) => {
  document.body.innerHTML = `
    <form method="post" data-controller="role-select" data-role-select-user-id-value="7"
          data-role-select-update-role-url-value="/admin/users/7/update_role"
          data-role-select-update-capabilities-url-value="/admin/users/7/update_capabilities"
          data-role-select-current-role-value="${currentRole}"
          data-action="turbo:submit-start->role-select#lock turbo:submit-end->role-select#unlock modal:closed@window->role-select#restore"
          ${warning ? `data-role-select-conversion-warning-value="${warning}"` : ''}>
      <input type="hidden" name="operation_id" data-role-select-target="operation">
      <input type="hidden" name="role" data-role-select-target="role">
      <input type="hidden" name="capability" data-role-select-target="capabilityField">
      <input type="hidden" name="enabled" data-role-select-target="enabled">
      <select data-role-select-target="select" data-action="change->role-select#roleChanged">
        <option value="Users::Vendor">Vendor</option>
        <option value="Users::Constituent">Constituent</option>
        <option value="Users::Trainer">Trainer</option>
      </select>
      <input type="checkbox" data-role-select-target="capability" data-capability="can_train"
             data-action="click->role-select#toggleCapability">
      <input type="checkbox" checked disabled data-from-role="true" data-role-select-target="capability" data-capability="can_evaluate">
    </form>
  `
  const form = document.querySelector('form')
  form.requestSubmit = jest.fn()
  application = Application.start()
  application.register('role-select', RoleSelectController)
  await Promise.resolve()
  const select = document.querySelector('select')
  select.value = currentRole
  return { form, select }
}

const choose = (select, role) => {
  select.value = role
  select.dispatchEvent(new Event('change'))
}

const submitted = (form) => Object.fromEntries(new FormData(form))

beforeEach(() => {
  jest.spyOn(window, 'confirm')
})

afterEach(() => {
  application.stop()
  jest.restoreAllMocks()
})

test('converting a vendor asks first; cancelling keeps the vendor role and submits nothing', async () => {
  window.confirm.mockReturnValue(false)
  const { form, select } = await render({ currentRole: 'Users::Vendor', warning: WARNING })

  choose(select, 'Users::Constituent')

  expect(window.confirm).toHaveBeenCalledWith(WARNING)
  expect(select.value).toBe('Users::Vendor')
  expect(form.requestSubmit).not.toHaveBeenCalled()
})

test('converting a vendor submits the role form once the admin confirms', async () => {
  window.confirm.mockReturnValue(true)
  const { form, select } = await render({ currentRole: 'Users::Vendor', warning: WARNING })

  choose(select, 'Users::Trainer')

  expect(form.requestSubmit).toHaveBeenCalledTimes(1)
  expect(form.action).toMatch(/\/admin\/users\/7\/update_role$/)
  expect(submitted(form)).toMatchObject({ role: 'Users::Trainer', capability: '', enabled: '' })
  expect(submitted(form).operation_id).toBeTruthy()
})

test('changing a non-vendor role does not ask and uses a new operation id each time', async () => {
  const { form, select } = await render({ currentRole: 'Users::Trainer' })

  choose(select, 'Users::Constituent')
  const first = submitted(form).operation_id
  choose(select, 'Users::Trainer')

  expect(window.confirm).not.toHaveBeenCalled()
  expect(form.requestSubmit).toHaveBeenCalledTimes(2)
  expect(submitted(form).operation_id).not.toBe(first)
})

test('toggling a capability submits the capability form with the new state', async () => {
  const { form } = await render({ currentRole: 'Users::Trainer' })
  const toggle = document.querySelector('[data-capability="can_train"]')

  toggle.click()

  expect(form.action).toMatch(/\/admin\/users\/7\/update_capabilities$/)
  expect(submitted(form)).toMatchObject({ role: '', capability: 'can_train', enabled: 'true' })
  expect(form.requestSubmit).toHaveBeenCalledTimes(1)
})

test('controls are disabled while the form is submitting and role-provided ones stay disabled afterwards', async () => {
  const { form, select } = await render({ currentRole: 'Users::Trainer' })
  const [grantable, fromRole] = document.querySelectorAll('input[type=checkbox]')

  form.dispatchEvent(new Event('turbo:submit-start', { bubbles: true }))
  expect([select.disabled, grantable.disabled, fromRole.disabled]).toEqual([true, true, true])

  form.dispatchEvent(new Event('turbo:submit-end', { bubbles: true }))
  expect([select.disabled, grantable.disabled, fromRole.disabled]).toEqual([false, false, true])
})

test("dismissing this user's confirmation dialog restores the stored controls; another user's does not", async () => {
  const { select } = await render({ currentRole: 'Users::Trainer' })
  const toggle = document.querySelector('[data-capability="can_train"]')
  toggle.checked = true
  select.value = 'Users::Constituent'

  window.dispatchEvent(new CustomEvent('modal:closed', { detail: { dialog: { dataset: { userId: '99' } } } }))
  expect(toggle.checked).toBe(true)

  window.dispatchEvent(new CustomEvent('modal:closed', { detail: { dialog: { dataset: { userId: '7' } } } }))
  expect(toggle.checked).toBe(false)
  expect(select.value).toBe('Users::Vendor')
})
