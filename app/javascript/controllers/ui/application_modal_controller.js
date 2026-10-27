import { Controller } from "@hotwired/stimulus"

class ApplicationModalController extends Controller {
  handleFormSubmit(event) {
    if (event.detail.success) {
      const dialog = event.target.closest("dialog")
      if (dialog) {
        dialog.close()
        Turbo.visit(window.location.href, { action: "replace" })
      }
    }
  }

  open(event) {
    const button = event.currentTarget
    const applicationId = button.dataset.applicationId
    const modalId = button.dataset.modalId

    const dialog = document.getElementById(modalId)
    if (!dialog) {
      console.error("Modal not found:", modalId)
      return
    }

    const viewFullLink = dialog.querySelector('#modal-view-full-link')
    if (viewFullLink) {
      viewFullLink.href = `/admin/applications/${applicationId}`
    }

    const editButton = dialog.querySelector('#modal-edit-button')
    if (editButton) {
      editButton.dataset.applicationId = applicationId
    }

    const frameId = "application-modal-content"
    const frame = dialog.querySelector(`[id="${frameId}"]`)
    if (frame) {
      Turbo.visit(`/admin/applications/${applicationId}?modal=true`, { 
        frame: frameId
      })
    } else {
      console.error("Frame not found with ID:", frameId)
    }

    if (dialog.tagName === "DIALOG") {
      dialog.showModal()
    }
  }

  close(event) {
    event?.preventDefault()
    const dialog = event.target.closest("dialog")
    if (dialog) {
      dialog.close()
    }
  }

  openUserEdit(event) {
    const userId = event.currentTarget.dataset.userId || document.querySelector('[data-user-id]')?.dataset.userId
    const dialog = document.getElementById('user-edit-modal')
    
    if (!dialog) {
      console.error("User edit modal not found")
      return
    }
    
    const frame = dialog.querySelector('[id="user-edit-modal-content"]')
    
    if (frame && userId) {
      Turbo.visit(`/admin/users/${userId}/edit?modal=true`, { 
        frame: "user-edit-modal-content"
      })
      dialog.showModal()
    }
  }

  openApplicationEdit(event) {
    const applicationId = event.currentTarget.dataset.applicationId
    const dialog = document.getElementById('application-edit-modal')
    
    if (!dialog) {
      console.error("Application edit modal not found")
      return
    }
    
    const frame = dialog.querySelector('[id="application-edit-modal-content"]')
    
    if (frame && applicationId) {
      Turbo.visit(`/admin/applications/${applicationId}/edit?modal=true`, { 
        frame: "application-edit-modal-content"
      })
      dialog.showModal()
    }
  }
}

export default ApplicationModalController
