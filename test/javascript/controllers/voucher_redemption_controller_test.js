import { Application } from '@hotwired/stimulus'
import VoucherRedemptionController from 'controllers/forms/voucher_redemption_controller'

let application

const render = async (checked = false) => {
  document.body.innerHTML = `
    <form data-controller="voucher-redemption" data-action="submit->voucher-redemption#submit">
      <input type="checkbox" ${checked ? 'checked' : ''} data-product-name="Keyboard product" data-voucher-redemption-target="product" data-action="change->voucher-redemption#update">
      <button data-voucher-redemption-target="submit">Redeem</button>
      <div data-voucher-redemption-target="warning" class="hidden">Choose a product</div>
      <div data-voucher-redemption-target="summary" class="hidden"><ul data-voucher-redemption-target="list"></ul></div>
    </form>`
  application = Application.start()
  application.register('voucher-redemption', VoucherRedemptionController)
  await Promise.resolve()
  return document.querySelector('input')
}

afterEach(() => {
  application.stop()
  document.body.innerHTML = ''
})

test('connects to a restored selection and permits changing it after retry', async () => {
  const product = await render(true)
  const button = document.querySelector('button')
  expect(button).not.toBeDisabled()
  expect(document.querySelector('li')).toHaveTextContent('Keyboard product')

  product.checked = false
  product.dispatchEvent(new Event('change'))
  expect(button).toBeDisabled()

  product.checked = true
  product.dispatchEvent(new Event('change'))
  expect(button).not.toBeDisabled()
})

test('blocks an unselected submit and safely displays a product name as text', async () => {
  const product = await render()
  const form = document.querySelector('form')
  const event = new Event('submit', { cancelable: true })
  form.dispatchEvent(event)
  expect(event.defaultPrevented).toBe(true)
  expect(product).toHaveFocus()

  product.dataset.productName = '<img src=x onerror=alert(1)>'
  product.checked = true
  product.dispatchEvent(new Event('change'))
  expect(document.querySelector('li').textContent).toBe('<img src=x onerror=alert(1)>')
  expect(document.querySelector('img')).toBeNull()
})
