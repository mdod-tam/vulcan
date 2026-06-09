import { Application } from "@hotwired/stimulus"
import TrainingDurationConfirmationController from "controllers/forms/training_duration_confirmation_controller"

describe("TrainingDurationConfirmationController", () => {
  let application
  let form
  let duration
  let dialog
  let message

  beforeEach(() => {
    document.body.innerHTML = `
      <form data-controller="training-duration-confirmation" data-action="submit->training-duration-confirmation#confirm">
        <input type="number" name="duration_hours" value="2.5" data-training-duration-confirmation-target="duration" />
        <dialog data-training-duration-confirmation-target="dialog">
          <p data-training-duration-confirmation-target="message"></p>
          <button type="button" data-training-duration-confirmation-target="noButton" data-action="training-duration-confirmation#cancel">No</button>
          <button type="button" data-training-duration-confirmation-target="yesButton" data-action="training-duration-confirmation#proceed">Yes</button>
        </dialog>
        <button type="submit">Mark as Completed</button>
      </form>
    `

    application = Application.start()
    application.register("training-duration-confirmation", TrainingDurationConfirmationController)

    form = document.querySelector("form")
    duration = document.querySelector("input[name='duration_hours']")
    dialog = document.querySelector("dialog")
    message = dialog.querySelector("p")

    dialog.showModal = jest.fn(() => dialog.setAttribute("open", "open"))
    dialog.close = jest.fn(() => dialog.removeAttribute("open"))
    form.requestSubmit = jest.fn()
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  test("submits normally when duration is two hours or less", () => {
    duration.value = "2"
    const event = new Event("submit", { bubbles: true, cancelable: true })

    form.dispatchEvent(event)

    expect(event.defaultPrevented).toBe(false)
    expect(dialog.showModal).not.toHaveBeenCalled()
  })

  test("opens confirmation dialog when duration is over two hours", () => {
    const event = new Event("submit", { bubbles: true, cancelable: true })

    form.dispatchEvent(event)

    expect(event.defaultPrevented).toBe(true)
    expect(dialog.showModal).toHaveBeenCalled()
    expect(message.textContent).toBe("You entered more than the typical number of training hours. Confirm 2.5 hours?")
  })

  test("No closes dialog and returns focus to duration input", () => {
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
    dialog.querySelector("button").click()

    expect(dialog.close).toHaveBeenCalled()
    expect(document.activeElement).toBe(duration)
  })

  test("Yes resumes form submission", () => {
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
    dialog.querySelectorAll("button")[1].click()

    expect(dialog.close).toHaveBeenCalled()
    expect(form.requestSubmit).toHaveBeenCalled()
  })
})
