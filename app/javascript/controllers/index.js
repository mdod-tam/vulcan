import { application } from "./application"

// Admin Controllers
import RoleSelectController from "./admin/role_select_controller"
import AdminUserSearchController from "./admin/user_search_controller"

// Auth Controllers
import AddCredentialController from "./auth/add_credential_controller"
import CredentialAuthenticatorController from "./auth/credential_authenticator_controller"
import TotpFormController from "./auth/totp_form_controller"

// Chart Controllers
import ChartController from "./charts/chart_controller"
import ChartToggleController from "./charts/toggle_controller"
import ReportsChartController from "./charts/reports_chart_controller"

// Form Controllers
import ApplicationFormController from "./forms/application_form_controller"
import AutosaveController from "./forms/autosave_controller"
import CurrencyFormatterController from "./forms/currency_formatter_controller"
import DateInputController from "./forms/date_input_controller"
import DateRangeController from "./forms/date_range_controller"
import DependentFieldsController from "./forms/dependent_fields_controller"
import DependentSelectorController from "./forms/dependent_selector_controller"
import FormValidationController from "./forms/form_validation_controller"
import IncomeValidationController from "./forms/income_validation_controller"
import PaperApplicationController from "./forms/paper_application_controller"
import RejectionFormController from "./forms/rejection_form_controller"

// Review Controllers
import EvaluationManagementController from "./reviews/evaluation_management_controller"
import ProofStatusController from "./reviews/proof_status_controller"
import W9ReviewController from "./reviews/w9_review_controller"

// UI Controllers
import AccessibilityAnnouncerController from "./ui/accessibility_announcer_controller"
import CheckboxSelectAllController from "./ui/checkbox_select_all_controller"
import MobileMenuController from "./ui/mobile_menu_controller"
import ModalController from "./ui/modal_controller"
import PdfLoaderController from "./ui/pdf_loader_controller"
import ReportsToggleController from "./ui/reports_toggle_controller"
import UploadController from "./ui/upload_controller"
import VisibilityController from "./ui/visibility_controller"

// User Controllers
import ApplicantTypeController from "./users/applicant_type_controller"
import DocumentProofHandlerController from "./users/document_proof_handler_controller"
import GuardianPickerController from "./users/guardian_picker_controller"

// Chart configuration
import { chartConfig } from "../services/chart_config"

// Development-only imports
if (process.env?.NODE_ENV === "development") {
  import("./debug_controller").then(module => {
    application.register("debug", module.default)
  })
}


// Admin Controllers
application.register("role-select", RoleSelectController)
application.register("admin-user-search", AdminUserSearchController)

// Auth Controllers
application.register("add-credential", AddCredentialController)
application.register("credential-authenticator", CredentialAuthenticatorController)
application.register("totp-form", TotpFormController)

// Chart Controllers
application.register("chart", ChartController)
application.register("chart-toggle", ChartToggleController)
application.register("reports-chart", ReportsChartController)

// Form Controllers
application.register("application-form", ApplicationFormController)
application.register("autosave", AutosaveController)
application.register("currency-formatter", CurrencyFormatterController)
application.register("date-input", DateInputController)
application.register("date-range", DateRangeController)
application.register("dependent-fields", DependentFieldsController)
application.register("dependent-selector", DependentSelectorController)
application.register("form-validation", FormValidationController)
application.register("income-validation", IncomeValidationController)
application.register("paper-application", PaperApplicationController)
application.register("rejection-form", RejectionFormController)

// Review Controllers
application.register("evaluation-management", EvaluationManagementController)
application.register("proof-status", ProofStatusController)
application.register("w9-review", W9ReviewController)

// UI Controllers
application.register("accessibility-announcer", AccessibilityAnnouncerController)
application.register("checkbox-select-all", CheckboxSelectAllController)
application.register("mobile-menu", MobileMenuController)
application.register("modal", ModalController)
application.register("pdf-loader", PdfLoaderController)
application.register("reports-toggle", ReportsToggleController)
application.register("upload", UploadController)
application.register("visibility", VisibilityController)

// User Controllers
application.register("applicant-type", ApplicantTypeController)
application.register("document-proof-handler", DocumentProofHandlerController)
application.register("guardian-picker", GuardianPickerController)
