import { Application } from "@hotwired/stimulus"
import ProductClassificationController from "controllers/admin/product_classification_controller"

describe("ProductClassificationController", () => {
  let application

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ""
  })

  test("category changes limit choices while keeping invalid selected types editable", async () => {
    document.body.innerHTML = `
      <style>.flex { display: flex; } .hidden { display: none; }</style>
      <form data-controller="product-classification" data-product-classification-choices-value='{"devices":["Smartphone"],"accessories":["Signaler"]}'>
        <select data-product-classification-target="category" data-action="product-classification#update"><option value="accessories">Accessories</option><option value="devices">Devices</option></select>
        <div id="phone" class="flex" data-product-classification-target="type" data-device-type="Smartphone"><input type="checkbox" checked></div>
        <div id="signaler" class="flex" data-product-classification-target="type" data-device-type="Signaler"><input type="checkbox"></div>
      </form>
    `
    application = Application.start()
    application.register("product-classification", ProductClassificationController)
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(document.querySelector("#phone").hidden).toBe(false)
    expect(document.querySelector("#phone input").checked).toBe(true)
    expect(document.querySelector("#phone input").disabled).toBe(false)
    const category = document.querySelector("select")
    category.value = "devices"
    category.dispatchEvent(new Event("change", { bubbles: true }))
    expect(document.querySelector("#signaler").hidden).toBe(true)
    expect(document.querySelector("#signaler")).not.toBeVisible()
    expect(document.querySelector("#signaler input").disabled).toBe(true)
    category.value = "accessories"
    category.dispatchEvent(new Event("change", { bubbles: true }))
    expect(document.querySelector("#signaler").hidden).toBe(false)
    expect(document.querySelector("#signaler")).toBeVisible()
    expect(document.querySelector("#signaler input").disabled).toBe(false)
  })
})
