import { Application } from "@hotwired/stimulus"
import TrainingOutcomeController from "controllers/forms/training_outcome_controller"

const flush = () => new Promise(resolve => setTimeout(resolve, 0))

describe("training outcome forms", () => {
  let application
  let selection
  let complete
  let cancel

  beforeEach(async () => {
    document.body.innerHTML = `
      <section data-controller="training-outcome">
        <select data-training-outcome-target="selection" data-action="training-outcome#change">
          <option value="">Choose</option>
          <option value="complete" selected>Complete</option>
          <option value="cancel">Cancel</option>
        </select>
        <div data-training-outcome-target="panel" data-outcome="complete">
          <form><textarea required>Restored shared summary</textarea><button>Save report</button></form>
        </div>
        <div data-training-outcome-target="panel" data-outcome="cancel">
          <form><textarea required>Private cancellation reason</textarea><button>Cancel appointment</button></form>
        </div>
      </section>`
    application = Application.start()
    application.register("training-outcome", TrainingOutcomeController)
    await flush()
    selection = document.querySelector("select")
    complete = document.querySelector('[data-outcome="complete"]')
    cancel = document.querySelector('[data-outcome="cancel"]')
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  test("restored outcome remains selected and only its form can submit", () => {
    expect(complete.hidden).toBe(false)
    expect(complete.querySelector("textarea").disabled).toBe(false)
    expect(complete.querySelector("textarea").value).toBe("Restored shared summary")
    expect(cancel.hidden).toBe(true)
    expect(cancel.querySelector("textarea").disabled).toBe(true)
    expect(cancel.querySelector("button").disabled).toBe(true)
  })

  test("switching from a restored outcome and back preserves both drafts and native validation", () => {
    selection.value = "cancel"
    selection.dispatchEvent(new Event("change", { bubbles: true }))
    expect(cancel.hidden).toBe(false)
    expect(cancel.querySelector("textarea").disabled).toBe(false)
    expect(cancel.querySelector("textarea").required).toBe(true)
    expect(complete.querySelector("button").disabled).toBe(true)
    cancel.querySelector("textarea").value = "Changed cancellation reason"
    selection.value = "complete"
    selection.dispatchEvent(new Event("change", { bubbles: true }))
    expect(complete.querySelector("textarea").value).toBe("Restored shared summary")
    expect(cancel.querySelector("textarea").value).toBe("Changed cancellation reason")
    expect(complete.querySelector("button").disabled).toBe(false)
    expect(cancel.querySelector("textarea").disabled).toBe(true)
  })
})
