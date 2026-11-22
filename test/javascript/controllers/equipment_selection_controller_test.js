import { Application } from "@hotwired/stimulus"
import EquipmentSelectionController from "controllers/admin/equipment_selection_controller"

describe("equipment selection", () => {
  let application
  let form

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ""
  })

  async function start() {
    document.body.innerHTML = `<style>.flex { display: flex; } .hidden { display: none; }</style>
    <form data-controller="equipment-selection">
      <input type="search" data-equipment-selection-target="search" data-action="input->equipment-selection#filter">
      <p data-equipment-selection-target="summary"></p>
      <p data-equipment-selection-target="empty" hidden>No equipment matches these filters.</p>
      <button type="button" data-action="equipment-selection#selectMatching">Select matching</button>
      <section data-equipment-selection-target="group">
        <input id="group" type="checkbox" data-action="equipment-selection#selectGroup" data-equipment-selection-target="groupCheckbox">
        <article id="need-row" class="flex" data-equipment-selection-target="row" data-search-text="Phone constituent Application #2" data-available-stock="1">Phone request
          <output data-stock-coverage></output>
          <input id="need" type="checkbox" name="need_ids[]" value="2" data-action="equipment-selection#selectRow" data-equipment-selection-target="rowCheckbox">
          <input id="quantity" type="number" name="quantities[2]" value="2" max="2" data-equipment-selection-target="quantity" data-action="input->equipment-selection#quantityChanged">
        </article>
        <article id="item-row" class="flex" data-equipment-selection-target="row" data-search-text="Tablet constituent Application #3" data-available-stock="0">Tablet detached unit
          <output data-stock-coverage></output>
          <input id="item" type="checkbox" name="item_ids[]" value="3" data-action="equipment-selection#selectRow" data-equipment-selection-target="rowCheckbox">
        </article>
        <article id="reserved-row" class="flex" data-equipment-selection-target="row" data-search-text="Reserved constituent Application #4" data-available-stock="5" data-requested-quantity="2">Already reserved request
          <output data-stock-coverage></output>
          <input id="reserved" type="checkbox" name="need_ids[]" value="4" disabled data-action="equipment-selection#selectRow" data-equipment-selection-target="rowCheckbox">
          <input id="reserved-quantity" type="number" value="0" max="0" data-equipment-selection-target="quantity">
        </article>
      </section>
    </form>`
    application = Application.start()
    application.register("equipment-selection", EquipmentSelectionController)
    form = document.querySelector("form")
    await new Promise(resolve => setTimeout(resolve, 0))
  }

  function input(element, value) {
    element.value = value
    element.dispatchEvent(new Event("input", { bubbles: true }))
  }

  test("group selection includes available rows once and shows partial selection without selecting reservations", async () => {
    await start()
    document.querySelector("#group").click()
    expect(document.querySelector("#need").checked).toBe(true)
    expect(document.querySelector("#item").checked).toBe(true)
    expect(document.querySelector("#reserved").checked).toBe(false)
    expect(document.querySelector("#reserved-quantity").disabled).toBe(true)
    expect(document.querySelector("p").textContent).toBe("2 selected (0 hidden by filters) · 3 units")
    document.querySelector("#item").click()
    expect(document.querySelector("#group").checked).toBe(false)
    expect(document.querySelector("#group").indeterminate).toBe(true)
    expect(new FormData(form).getAll("need_ids[]")).toEqual(["2"])
    expect(new FormData(form).getAll("item_ids[]")).toEqual([])
  })

  test("hidden checked rows remain submitted while Select matching only adds visible available rows", async () => {
    await start()
    document.querySelector("#need").click()
    input(document.querySelector("input[type=search]"), "tablet")
    expect(document.querySelector("#need-row").hidden).toBe(true)
    expect(document.querySelector("#need-row")).not.toBeVisible()
    expect(document.querySelector("p").textContent).toBe("1 selected (1 hidden by filters) · 2 units")
    document.querySelector("button").click()
    expect(document.querySelector("p").textContent).toBe("2 selected (1 hidden by filters) · 3 units")
    expect(new FormData(form).getAll("need_ids[]")).toEqual(["2"])
    expect(new FormData(form).getAll("item_ids[]")).toEqual(["3"])
    input(document.querySelector("input[type=search]"), "No such model")
    expect(document.querySelector('[data-equipment-selection-target="empty"]').hidden).toBe(false)
    input(document.querySelector("input[type=search]"), "")
    expect(document.querySelector('[data-equipment-selection-target="empty"]').hidden).toBe(true)
    expect(document.querySelector("#need").checked).toBe(true)
    expect(document.querySelector("#item").checked).toBe(true)
  })

  test("positive quantity edits check their request and unchecking removes its validation and selected total", async () => {
    await start()
    const quantity = document.querySelector("#quantity")
    expect(quantity.required).toBe(false)
    input(quantity, "1")
    expect(document.querySelector("#need").checked).toBe(true)
    expect(quantity.required).toBe(true)
    expect(quantity.min).toBe("1")
    expect(quantity.max).toBe("2")
    expect(document.querySelector("p").textContent).toBe("1 selected (0 hidden by filters) · 1 unit")
    document.querySelector("#need").click()
    input(quantity, "0")
    expect(quantity.required).toBe(false)
    expect(quantity.min).toBe("")
    expect(quantity.max).toBe("")
    expect(form.checkValidity()).toBe(true)
    expect(document.querySelector("p").textContent).toBe("0 selected (0 hidden by filters) · 0 units")
  })

  test("selecting a group initializes invalid unused quantities to the outstanding count", async () => {
    await start()
    input(document.querySelector("#quantity"), "0")
    document.querySelector("#group").click()
    expect(document.querySelector("#quantity").value).toBe("2")
    expect(form.checkValidity()).toBe(true)
  })

  test("search matches the constituent or application number instead of incidental row text", async () => {
    await start()
    const search = document.querySelector("input[type=search]")
    input(search, "#3")
    expect(document.querySelector("#item-row")).toBeVisible()
    expect(document.querySelector("#need-row")).not.toBeVisible()
    input(search, "PHONE CONSTITUENT")
    expect(document.querySelector("#need-row")).toBeVisible()
    input(search, "request")
    expect(document.querySelector('[data-equipment-selection-target="empty"]').hidden).toBe(false)
  })

  test("stock coverage follows chosen quantities and compares reserved requests without making them selectable", async () => {
    await start()
    const coverage = document.querySelector("#need-row [data-stock-coverage]")
    expect(coverage.textContent).toBe("Partial")
    expect(document.querySelector("#item-row [data-stock-coverage]").textContent).toBe("No")
    const reservedRow = document.querySelector("#reserved-row")
    const reservedCoverage = reservedRow.querySelector("[data-stock-coverage]")
    expect(reservedCoverage.textContent).toBe("All")
    reservedRow.dataset.availableStock = "1"
    input(document.querySelector("#quantity"), "2")
    expect(reservedCoverage.textContent).toBe("Partial")
    reservedRow.dataset.availableStock = "0"
    input(document.querySelector("#quantity"), "1")
    expect(coverage.textContent).toBe("All")
    expect(reservedCoverage.textContent).toBe("No")
    expect(document.querySelector("#reserved").disabled).toBe(true)
    expect(document.querySelector("#reserved-quantity").disabled).toBe(true)
    input(document.querySelector("#quantity"), "0")
    expect(coverage.textContent).toBe("—")
  })

  test("group selection changes matching rows while retaining hidden checked rows", async () => {
    await start()
    input(document.querySelector("input[type=search]"), "tablet")
    document.querySelector("#group").click()
    expect(document.querySelector("#item").checked).toBe(true)
    expect(document.querySelector("#need").checked).toBe(false)
    input(document.querySelector("input[type=search]"), "")
    document.querySelector("#need").click()
    input(document.querySelector("input[type=search]"), "tablet")
    expect(document.querySelector("#group").checked).toBe(true)
    document.querySelector("#group").click()
    expect(document.querySelector("#item").checked).toBe(false)
    expect(document.querySelector("#need").checked).toBe(true)
    expect(new FormData(form).getAll("need_ids[]")).toEqual(["2"])
  })

  test("filter submission keeps selections and copies the current return context to the separate action form", async () => {
    document.body.innerHTML = `
      <div data-controller="equipment-selection">
        <form id="equipment-filters" action="/admin/equipment" method="get" data-action="submit->equipment-selection#applyFilters">
          <input type="search" name="return_context[search]" data-equipment-selection-target="search" data-action="input->equipment-selection#filter">
          <button>Apply filters</button>
        </form>
        <form id="selection" action="/admin/bid_groups/new" method="get">
          <input type="hidden" name="return_context[search]" data-equipment-selection-target="contextField">
          <article data-equipment-selection-target="row" data-search-text="Samuel Reed Application #29">
            <input type="checkbox" name="need_ids[]" value="29" checked data-equipment-selection-target="rowCheckbox">
          </article>
        </form>
      </div>`
    application = Application.start()
    application.register("equipment-selection", EquipmentSelectionController)
    await new Promise(resolve => setTimeout(resolve, 0))
    input(document.querySelector('input[type="search"]'), "Samuel")
    const event = new Event("submit", { bubbles: true, cancelable: true })
    document.querySelector("#equipment-filters").dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
    const selection = document.querySelector("#selection")
    expect(new FormData(selection).getAll("need_ids[]")).toEqual(["29"])
    expect(new FormData(selection).get("return_context[search]")).toBe("Samuel")
  })

  test("read-only history rows can be filtered without selection controls", async () => {
    document.body.innerHTML = `<div data-controller="equipment-selection">
      <input type="search" data-equipment-selection-target="search" data-action="input->equipment-selection#filter">
      <article data-equipment-selection-target="row" data-search-text="Samuel Reed Application #29">Shipped device</article>
    </div>`
    application = Application.start()
    application.register("equipment-selection", EquipmentSelectionController)
    await new Promise(resolve => setTimeout(resolve, 0))
    input(document.querySelector('input[type="search"]'), "No matching constituent")
    expect(document.querySelector("article").hidden).toBe(true)
  })
})
