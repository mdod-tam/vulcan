import { Application } from "@hotwired/stimulus"
import StockPurchaseController from "controllers/admin/stock_purchase_controller"

describe("StockPurchaseController", () => {
  let application
  let form

  function batch(productId, index) {
    return `<div>
      <input type="hidden" name="stock[][product_id]" value="${productId}">
      <label for="stock-quantity-${productId}-${index}">Quantity</label>
      <input type="number" id="stock-quantity-${productId}-${index}" name="stock[][quantity]" value="0" min="0" step="1">
      <label for="stock-setup-${productId}-${index}">Disability group</label>
      <select id="stock-setup-${productId}-${index}" name="stock[][supplier_setup_group]">
        <option value="">Unassigned</option>
        <option value="deaf">Deaf</option>
        <option value="deafblind">DeafBlind</option>
        <option value="speech">Speech</option>
      </select>
    </div>`
  }

  beforeEach(async () => {
    document.body.innerHTML = `<form>${[42, 84].map(productId => `
      <section id="product-${productId}" data-controller="stock-purchase">
        <div data-stock-purchase-target="rows">${batch(productId, 0)}</div>
        <template data-stock-purchase-target="template">${batch(productId, "__BATCH_INDEX__")}</template>
        <button type="button" data-action="stock-purchase#add">Add another setup</button>
      </section>`).join("")}</form>`
    form = document.querySelector("form")
    application = Application.start()
    application.register("stock-purchase", StockPurchaseController)
    await new Promise(resolve => setTimeout(resolve, 0))
  })

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ""
  })

  test("repeated additions keep entered batches, label new fields, and submit native stock rows", () => {
    document.querySelector("#stock-quantity-42-0").value = "10"
    document.querySelector("#stock-setup-42-0").value = "deaf"
    const add = document.querySelector("#product-42 button")
    add.click()
    expect(document.activeElement).toBe(document.querySelector("#stock-quantity-42-1"))
    document.querySelector("#stock-quantity-42-1").value = "10"
    document.querySelector("#stock-setup-42-1").value = "deafblind"
    add.click()
    expect(document.activeElement).toBe(document.querySelector("#stock-quantity-42-2"))

    const rows = document.querySelector('[data-stock-purchase-target="rows"]')
    expect(rows.children).toHaveLength(3)
    expect(Array.from(rows.querySelectorAll('input[type="number"]'), input => input.value)).toEqual(["10", "10", "0"])
    expect(Array.from(rows.querySelectorAll("select"), select => select.value)).toEqual(["deaf", "deafblind", ""])
    rows.querySelectorAll("label").forEach(label => {
      expect(label.control).toBe(document.getElementById(label.htmlFor))
      expect(label.control).not.toBeNull()
    })
    expect(Array.from(new FormData(form))).toEqual([
      ["stock[][product_id]", "42"], ["stock[][quantity]", "10"], ["stock[][supplier_setup_group]", "deaf"],
      ["stock[][product_id]", "42"], ["stock[][quantity]", "10"], ["stock[][supplier_setup_group]", "deafblind"],
      ["stock[][product_id]", "42"], ["stock[][quantity]", "0"], ["stock[][supplier_setup_group]", ""],
      ["stock[][product_id]", "84"], ["stock[][quantity]", "0"], ["stock[][supplier_setup_group]", ""]
    ])
  })

  test("products add batches independently without reusing field IDs or changing another model", () => {
    document.querySelector("#stock-quantity-84-0").value = "7"
    document.querySelector("#stock-setup-84-0").value = "speech"
    document.querySelector("#product-42 button").click()
    document.querySelector("#product-84 button").click()

    const fieldIds = Array.from(form.querySelectorAll("input[id], select[id]"), field => field.id)
    expect(new Set(fieldIds).size).toBe(fieldIds.length)
    expect(fieldIds.some(id => id.includes("__BATCH_INDEX__"))).toBe(false)
    expect(document.querySelector("#stock-quantity-42-1")).not.toBeNull()
    expect(document.activeElement).toBe(document.querySelector("#stock-quantity-84-1"))
    const submitted = new FormData(form)
    expect(submitted.getAll("stock[][product_id]")).toEqual(["42", "42", "84", "84"])
    expect(submitted.getAll("stock[][quantity]")).toEqual(["0", "0", "7", "0"])
    expect(submitted.getAll("stock[][supplier_setup_group]")).toEqual(["", "", "speech", ""])
  })
})
