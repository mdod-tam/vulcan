import { Controller } from "@hotwired/stimulus"

class ApplicationModalController extends Controller {
  connect() {
    // Store bound function as instance property for proper cleanup
    this.boundHandleFormSubmit = this.handleFormSubmit.bind(this)
    // Listen for Turbo form submissions within modals
    this.element.addEventListener("turbo:submit-end", this.boundHandleFormSubmit)
  }

  disconnect() {
    // Remove listener using the same bound function reference
    this.element.removeEventListener("turbo:submit-end", this.boundHandleFormSubmit)
  }

  handleFormSubmit(event) {
    // If form submission was successful, close the modal and reload the page
    if (event.detail.success) {
      const dialog = event.target.closest("dialog")
      if (dialog) {
        dialog.close()
        // Reload the page to reflect changes
        window.location.reload()
      }
    }
  }

  open(event) {
    const button = event.currentTarget
    const applicationId = button.dataset.applicationId
    const modalId = button.dataset.modalId
        
    // Find the dialog element
    const dialog = document.getElementById(modalId)
    if (!dialog) {
      console.error("Modal not found:", modalId)
      return
    }
    
    // Update the "View Full Application" link
    const viewFullLink = dialog.querySelector('#modal-view-full-link')
    if (viewFullLink) {
      viewFullLink.href = `/admin/applications/${applicationId}`
    }
    
    // Update the edit button with the application ID
    const editButton = dialog.querySelector('#modal-edit-button')
    if (editButton) {
      editButton.dataset.applicationId = applicationId
    }
    
    // Load application content into the modal frame
    const frameId = "application-modal-content"
    const frame = dialog.querySelector(`[id="${frameId}"]`)
    if (frame) {
      // Use Turbo to load the application show page into the frame
      Turbo.visit(`/admin/applications/${applicationId}?modal=true`, { 
        frame: frameId
      })
    } else {
      console.error("Frame not found with ID:", frameId)
    }
    
    // Show the dialog
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
