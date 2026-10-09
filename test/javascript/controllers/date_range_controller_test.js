import { Application } from '@hotwired/stimulus'
import DateRangeController from 'controllers/forms/date_range_controller'

let application

const render = async (name, value) => {
  document.body.innerHTML = `
    <form data-controller="date-range">
      <select name="${name}" data-action="change->date-range#toggleCustomRange">
        <option value="today" ${value === 'today' ? 'selected' : ''}>Today</option>
        <option value="custom" ${value === 'custom' ? 'selected' : ''}>Custom Range</option>
      </select>
      <div class="hidden" style="display: none" data-date-range-target="customRange"><input value="13/45/2026"></div>
      <div class="hidden" style="display: none" data-date-range-target="customRange"><input value="10/09/2026"></div>
    </form>`
  application = Application.start()
  application.register('date-range', DateRangeController)
  await Promise.resolve()
  return document.querySelector('select')
}

afterEach(() => {
  application.stop()
  document.body.innerHTML = ''
})

test.each(['period', 'date_range'])('restores the custom fields for the live %s picker without clearing typed dates', async name => {
  const select = await render(name, 'custom')
  const fields = [...document.querySelectorAll('[data-date-range-target="customRange"]')]

  fields.forEach(field => {
    expect(field).not.toHaveClass('hidden')
    expect(field.style.display).toBe('')
  })
  expect(fields[0].querySelector('input').value).toBe('13/45/2026')

  select.value = 'today'
  select.dispatchEvent(new Event('change'))
  fields.forEach(field => expect(field).toHaveClass('hidden'))

  select.value = 'custom'
  select.dispatchEvent(new Event('change'))
  fields.forEach(field => expect(field).not.toHaveClass('hidden'))
  expect(fields[0].querySelector('input').value).toBe('13/45/2026')
})
