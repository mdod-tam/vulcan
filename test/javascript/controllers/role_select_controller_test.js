import { Application } from '@hotwired/stimulus'
import RoleSelectController from 'controllers/admin/role_select_controller'
import { railsRequest } from '../../../app/javascript/services/rails_request'

jest.mock('../../../app/javascript/services/rails_request', () => ({
  railsRequest: { perform: jest.fn(), cancel: jest.fn() }
}))

const WARNING = 'Converting this vendor to another role may lose their W9 and transaction history. Convert anyway?'
let application

const render = async ({ currentRole, warning }) => {
  document.body.innerHTML = `
    <div data-controller="role-select"
         data-role-select-update-role-url-value="/admin/users/1/update_role"
         data-role-select-update-capabilities-url-value="/admin/users/1/update_capabilities"
         data-role-select-current-role-value="${currentRole}"
         ${warning ? `data-role-select-conversion-warning-value="${warning}"` : ''}>
      <select data-role-select-target="select" data-action="change->role-select#roleChanged">
        <option value="Users::Vendor">Vendor</option>
        <option value="Users::Constituent">Constituent</option>
        <option value="Users::Trainer">Trainer</option>
      </select>
    </div>
  `
  application = Application.start()
  application.register('role-select', RoleSelectController)
  await Promise.resolve()
  const select = document.querySelector('select')
  select.value = currentRole
  return select
}

const choose = (select, role) => {
  select.value = role
  select.dispatchEvent(new Event('change'))
}

beforeEach(() => {
  railsRequest.perform.mockReset().mockResolvedValue({ success: false })
  jest.spyOn(window, 'confirm')
})

afterEach(() => {
  application.stop()
  jest.restoreAllMocks()
})

test('converting a vendor asks first; cancelling keeps the vendor role and sends nothing', async () => {
  window.confirm.mockReturnValue(false)
  const select = await render({ currentRole: 'Users::Vendor', warning: WARNING })

  choose(select, 'Users::Constituent')

  expect(window.confirm).toHaveBeenCalledWith(WARNING)
  expect(select.value).toBe('Users::Vendor')
  expect(railsRequest.perform).not.toHaveBeenCalled()
})

test('converting a vendor proceeds once the admin confirms', async () => {
  window.confirm.mockReturnValue(true)
  const select = await render({ currentRole: 'Users::Vendor', warning: WARNING })

  choose(select, 'Users::Trainer')

  expect(railsRequest.perform).toHaveBeenCalledWith(expect.objectContaining({
    method: 'patch', url: '/admin/users/1/update_role', body: { role: 'Users::Trainer' }
  }))
})

test('changing a non-vendor role does not ask', async () => {
  const select = await render({ currentRole: 'Users::Trainer' })

  choose(select, 'Users::Constituent')

  expect(window.confirm).not.toHaveBeenCalled()
  expect(railsRequest.perform).toHaveBeenCalledWith(expect.objectContaining({ body: { role: 'Users::Constituent' } }))
})
