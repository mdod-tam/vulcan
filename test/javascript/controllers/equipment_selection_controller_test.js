import { Application } from "@hotwired/stimulus"
import EquipmentSelectionController from "controllers/admin/equipment_selection_controller"

describe("equipment selection", () => {
  let application

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ""
  })

  async function start(html) {
    document.body.innerHTML = html
    application = Application.start()
    application.register("equipment-selection", EquipmentSelectionController)
    await new Promise(resolve => setTimeout(resolve, 0))
  }

  test("select group checks all rows and deselecting one row removes whole-group selection", async () => {
    await start(`<form data-controller="equipment-selection"><section data-equipment-selection-target="group">
      <input id="group" type="checkbox" name="group_product_ids[]" value="1" data-action="equipment-selection#selectGroup" data-equipment-selection-target="groupCheckbox">
      <input id="need" type="checkbox" name="need_ids[]" value="2" data-action="equipment-selection#selectRow" data-equipment-selection-target="rowCheckbox">
      <input id="item" type="checkbox" name="item_ids[]" value="3" data-action="equipment-selection#selectRow" data-equipment-selection-target="rowCheckbox">
    </section></form>`)
    document.querySelector("#group").click()
    expect(document.querySelector("#need").checked).toBe(true)
    expect(document.querySelector("#item").checked).toBe(true)
    document.querySelector("#item").click()
    expect(document.querySelector("#group").checked).toBe(false)
    expect(new FormData(document.querySelector("form")).getAll("need_ids[]")).toEqual(["2"])
    expect(new FormData(document.querySelector("form")).getAll("item_ids[]")).toEqual([])
  })

  test("review count reflects restored and reduced new quantities plus existing detached units", async () => {
    await start(`<form data-controller="equipment-selection" data-equipment-selection-existing-units-value="1">
      <span data-equipment-selection-target="unitCount"></span>
      <span data-equipment-selection-target="unitLabel"></span>
      <input type="number" value="2" data-equipment-selection-target="quantity" data-action="input->equipment-selection#updateQuantities">
    </form>`)
    const count = document.querySelector("span")
    expect(count.textContent).toBe("3")
    const label = document.querySelector('[data-equipment-selection-target="unitLabel"]')
    expect(label.textContent).toBe("physical units")
    const quantity = document.querySelector("input")
    quantity.value = "1"
    quantity.dispatchEvent(new Event("input", { bubbles: true }))
    expect(count.textContent).toBe("2")
    quantity.value = "0"
    quantity.dispatchEvent(new Event("input", { bubbles: true }))
    expect(count.textContent).toBe("1")
    expect(label.textContent).toBe("physical unit")
    quantity.value = "2"
    quantity.dispatchEvent(new Event("input", { bubbles: true }))
    expect(label.textContent).toBe("physical units")
  })
})
