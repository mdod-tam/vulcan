import { Controller } from "@hotwired/stimulus";
import { setVisible } from "../../utils/visibility";

// A request that never settles is worse here than one that fails: the form stays in `checking` and
// Submit stays disabled, so a completed application -- including four already-selected files that a
// reload would discard -- cannot be submitted at all. Bounded so the worst case is a retry.
const IDENTITY_REVIEW_TIMEOUT_MS = 15000;

// Marks the two failures that need to be told apart from an ordinary one, because their recovery is
// different: a timeout is retried as-is, an expired session must be signed in again first.
class IdentityReviewFailure extends Error {
  constructor(kind, message) {
    super(message);
    this.name = "IdentityReviewFailure";
    this.kind = kind;
  }
}

export default class extends Controller {
  static targets = [
    "submitButton",
    "rejectionButton",
    "status",
    "applicantLocale",
    "languagePreferenceNotice",
    "rejectionFirstName",
    "rejectionLastName",
    "rejectionRecipientId",
    "rejectionEmail",
    "rejectionDependentEmail",
    "rejectionPhone",
    "rejectionHouseholdSize",
    "rejectionAnnualIncome",
    "rejectionExistingPreferenceNotice",
    "rejectionExistingPreferenceValue",
    "identityReviewPanel",
    "identityReviewHeading",
    "identityReviewBody",
    "identityReviewCandidates",
    "identityReviewOverride",
    "identityReviewOverrideButton",
    "identityReviewNotice",
    "identityDecision"
  ];

  // Endpoint comes from a Rails-generated data value rather than a hardcoded path.
  static values = { identityReviewUrl: String };

  // Only these ten facts are sent for review. Everything else the form holds -- application
  // answers, provider details and four native file inputs -- is irrelevant to an identity check
  // and must never be uploaded to one.
  static IDENTITY_FIELDS = [
    "first_name",
    "last_name",
    "date_of_birth",
    "email",
    "phone",
    "physical_address_1",
    "physical_address_2",
    "city",
    "state",
    "zip_code"
  ];

  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("PaperApplicationController connected");
    }

    this._incomeExceedsThreshold = false;
    this._identityReviewState = "idle";
    this._identityReviewGeneration = 0;
    this._identityReviewBypass = false;
    this._identityReviewAbort = null;
    this._identityReviewTimer = null;
    this._candidateSelectionInFlight = false;
    this._candidateSelectionAbort = null;
    this._candidateSelectionRefusal = null;
    this._dependentContactChoiceField = null;
    this._dependentContactChoiceMessage = null;
    this._identityReviewToken = null;
    this._identityReviewExpiresAt = null;

    // Listen for income validation events from income_validation_controller
    this._boundHandleIncomeValidation = this.handleIncomeValidation.bind(this);
    this.element.addEventListener('income-validation:validated', this._boundHandleIncomeValidation);
    this._boundSyncFormState = this.syncFormState.bind(this);
    this.element.addEventListener('input', this._boundSyncFormState);
    this.element.addEventListener('change', this._boundSyncFormState);

    // Any edit to what a review was about invalidates it. Without this, editing during the request
    // leaves the state stuck at `checking` -- Submit disabled forever -- and editing after a panel
    // appears leaves stale candidates and a live token on screen for a different applicant.
    this._boundInvalidateIdentityReview = this._handleIdentityFactChange.bind(this);
    this.element.addEventListener('input', this._boundInvalidateIdentityReview);
    this.element.addEventListener('change', this._boundInvalidateIdentityReview);
    this._boundApplicantTypeChanged = () => this.invalidateIdentityReview();
    this.element.addEventListener('applicant-type:applicantTypeChanged', this._boundApplicantTypeChanged);

    this.updateLanguagePreferenceNotices();

    // After sibling Stimulus controllers on this element finish connect (income validation, etc.)
    requestAnimationFrame(() => {
      this.syncFormState();
      this._applySubmitGating();
    });
  }

  disconnect() {
    // Clean up event listeners
    if (this._boundHandleIncomeValidation) {
      this.element.removeEventListener('income-validation:validated', this._boundHandleIncomeValidation);
    }
    if (this._boundSyncFormState) {
      this.element.removeEventListener('input', this._boundSyncFormState);
      this.element.removeEventListener('change', this._boundSyncFormState);
    }
    // An in-flight review and a pending expiry timer both outlive this element otherwise.
    if (this._boundInvalidateIdentityReview) {
      this.element.removeEventListener('input', this._boundInvalidateIdentityReview);
      this.element.removeEventListener('change', this._boundInvalidateIdentityReview);
    }
    if (this._boundApplicantTypeChanged) {
      this.element.removeEventListener('applicant-type:applicantTypeChanged', this._boundApplicantTypeChanged);
    }
    this._abortIdentityReview();
    this._abortCandidateSelection();
    this._clearIdentityReviewTimer();
  }

  applicantLocaleTargetConnected() {
    this.updateLanguagePreferenceNotices();
  }

  /**
   * Handle income validation results from income_validation_controller
   * @param {CustomEvent} event The validation event with details about threshold status
   */
  handleIncomeValidation(event) {
    this._incomeExceedsThreshold = !!event.detail.exceedsThreshold;
    this._applySubmitGating();
  }

  /**
   * Re-evaluate submit / rejection UI from income threshold + existing-adult verification.
   */
  syncAdultVerificationGate() {
    this._applySubmitGating();
  }

  /**
   * Highlight contact deltas on the adult picker before native form submit, then gate the
   * submission on an identity review when this is a new self applicant.
   *
   * The review has to happen *before* the native submission rather than after a failed one: the
   * four proof inputs are native file inputs with no direct upload, so a server-rendered failure
   * would discard the documents staff had already chosen. So the form asks a read-only endpoint
   * about the ten identity facts first, and only then submits everything.
   *
   * A `clear` answer is not a state -- it resumes submission immediately, so the ordinary case
   * stays one click and one upload.
   */
  beforeSubmit(event) {
    const root = this.element.querySelector("[data-controller~='adult-picker']");
    if (root && this.application) {
      const picker = this.application.getControllerForElementAndIdentifier(root, "adult-picker");
      if (picker && typeof picker.highlightChanges === "function") picker.highlightChanges();
    }

    if (this._identityReviewBypass) return;
    if (!this._identityReviewContext()) return;
    if (!event || typeof event.preventDefault !== "function") return;

    // Synchronously, before any await: the native submission must not start.
    event.preventDefault();
    if (this._identityReviewState === "checking") return;

    this._startIdentityReview(event.submitter || null);
  }

  /**
   * Narrow on purpose: an income figure or a proof choice changing is not a different applicant, and
   * discarding a valid review for it would send staff round the loop again for nothing.
   * @private
   */
  _handleIdentityFactChange(event) {
    const name = event && event.target ? String(event.target.name || "") : "";
    if (!name) return;

    const isFact = this.constructor.IDENTITY_FIELDS.some((field) => name === `constituent[${field}]`) ||
      name === "constituent[dependent_email]" || name === "constituent[dependent_phone]";
    const isFlag = name === "no_email_address" || name === "no_phone_number";
    const isApplicantType = name === "applicant_type";
    const isDependentContext = ["guardian_id", "relationship_type", "email_strategy",
      "phone_strategy", "address_strategy", "use_guardian_email", "use_guardian_phone",
      "use_guardian_address"].includes(name);
    if (!isFact && !isFlag && !isApplicantType && !isDependentContext) return;

    this.invalidateIdentityReview();
  }

  /**
   * Selecting an existing constituent or existing dependent is already the other disposition.
   * New self applicants and new dependents are the final-submit branches that require review.
   * @private
   */
  _isNewSelfApplicant() {
    const existing = this.element.querySelector('[name="existing_constituent_id"]');
    if (existing && !existing.disabled && String(existing.value || "").trim()) return false;

    const type = this.element.querySelector('[name="applicant_type"]:checked')
      || this.element.querySelector('[name="applicant_type"]');
    const value = type ? String(type.value || "") : "self";
    if (value === "dependent") return false;

    return !!this.element.querySelector('[name="constituent[first_name]"]');
  }

  _identityReviewContext() {
    if (this._isNewSelfApplicant()) return "self_applicant";

    const type = this.element.querySelector('[name="applicant_type"]:checked');
    const guardian = this.element.querySelector('[name="guardian_id"]');
    const dependent = this.element.querySelector('[name="dependent_id"]');
    const firstName = this.element.querySelector('[name="constituent[first_name]"]');
    if (type?.value === "dependent" && String(guardian?.value || "").trim() &&
        !String(dependent?.value || "").trim() && firstName) return "dependent";

    return null;
  }

  /** @private */
  _identityReviewNoun({ plural = false } = {}) {
    const dependent = this._identityReviewContext() === "dependent";
    if (plural) return dependent ? "dependents" : "constituents";

    return dependent ? "dependent" : "constituent";
  }

  /**
   * Builds a fresh FormData rather than serializing the form, so no File and no unrelated answer
   * can be transported to a check. Flags are read from the checkbox itself: each has a hidden "0"
   * before it, and FormData#get would return that hidden value for a checked box.
   * @private
   */
  _identityReviewPayload() {
    const body = new FormData();
    const snapshot = {};
    const context = this._identityReviewContext() || "self_applicant";

    this.constructor.IDENTITY_FIELDS.forEach((field) => {
      const input = this._activeIdentityInput(field, context);
      const value = input ? String(input.value || "") : "";
      body.append(`constituent[${field}]`, value);
      snapshot[field] = value;
    });

    ["no_email_address", "no_phone_number"].forEach((flag) => {
      const box = this.element.querySelector(`input[type="checkbox"][name="${flag}"]`);
      const value = box && box.checked ? "1" : "0";
      body.append(flag, value);
      snapshot[flag] = value;
    });

    snapshot.identity_context = context;
    if (context === "dependent") {
      body.append("identity_context", context);
      ["dependent_email", "dependent_phone"].forEach((field) => {
        const input = this.element.querySelector(`[name="constituent[${field}]"]`);
        const value = input ? String(input.value || "") : "";
        body.append(`constituent[${field}]`, value);
        snapshot[field] = value;
      });

      ["guardian_id", "relationship_type"].forEach((name) => {
        const input = this.element.querySelector(`[name="${name}"]`);
        const value = input ? String(input.value || "") : "";
        body.append(name, value);
        snapshot[name] = value;
      });

      [["email_strategy", "use_guardian_email"], ["phone_strategy", "use_guardian_phone"],
        ["address_strategy", "use_guardian_address"]].forEach(([strategy, checkbox]) => {
        const explicit = this.element.querySelector(`[name="${strategy}"]`);
        const useGuardian = this.element.querySelector(`input[type="checkbox"][name="${checkbox}"]`);
        const value = explicit?.value || (useGuardian?.checked ? "guardian" : "dependent");
        body.append(strategy, value);
        snapshot[strategy] = value;
      });
    }

    return { body, snapshot };
  }

  /**
   * The self and dependent fieldsets intentionally use the same submitted names. Only one copy is
   * enabled, but querySelector returns the earlier disabled self input on the dependent branch.
   * Previewing that stale copy as clear and then submitting the enabled dependent copy makes the
   * durable writer refuse after the browser has uploaded every file. Read from the active branch,
   * with the fieldset as an explicit tie-breaker so a test helper or future transition that briefly
   * enables both copies cannot silently choose the other person's identity.
   * @private
   */
  _activeIdentityInput(field, context) {
    const inputs = Array.from(this.element.querySelectorAll(`[name="constituent[${field}]"]`));
    const enabled = inputs.filter((input) => !input.disabled);
    if (context === "dependent") {
      return enabled.find((input) => input.closest("#dependent-info-section")) || enabled[0] || inputs[0];
    }

    return enabled.find((input) => !input.closest("#dependent-info-section")) || enabled[0] || inputs[0];
  }

  /**
   * Runs the read-only review, then acts on the answer.
   *
   * Guarded by both an AbortController and a generation counter: aborting stops the network work,
   * and the generation stops a response that was already in flight from painting a panel for an
   * applicant staff have since edited past. The snapshot is checked too, because a value can be
   * edited and edited back while a request is outstanding.
   * @private
   */
  async _startIdentityReview(submitter) {
    const { body, snapshot } = this._identityReviewPayload();
    this._abortIdentityReview();
    this._clearIdentityReviewTimer();

    // Anything on screen belongs to the previous answer.
    this._clearIdentityReviewContent();

    const generation = ++this._identityReviewGeneration;
    const controller = new AbortController();
    this._identityReviewAbort = controller;
    this._setIdentityReviewState("checking");

    let payload;
    try {
      payload = await this._fetchIdentityReviewWithTimeout(body, controller);
    } catch (error) {
      if (error && error.name === "AbortError") return;
      if (this._settleStaleIdentityReview(generation, snapshot)) return;
      const kind = error instanceof IdentityReviewFailure ? error.kind : "error";
      this._setIdentityReviewState(kind === "error" ? "error" : kind);
      return;
    }

    if (this._settleStaleIdentityReview(generation, snapshot)) return;

    this._identityReviewToken = payload.token || null;
    this._identityReviewExpiresAt = payload.expires_at ? Date.parse(payload.expires_at) : null;
    this._identityReviewSubmitter = submitter;

    switch (payload.state) {
      case "clear":
        this._setIdentityReviewState("idle");
        this._resumeNativeSubmission(submitter);
        break;
      case "needs_confirmation":
        this._renderPossibleMatches(payload);
        this._setIdentityReviewState("possible_matches");
        this._scheduleIdentityReviewExpiry();
        break;
      case "blocked":
        this._renderContactBlock(payload);
        this._setIdentityReviewState("blocked");
        break;
      case "invalid_contact_choice":
        this._renderDependentContactChoice(payload);
        this._setIdentityReviewState("invalid_contact_choice");
        break;
      default:
        this._setIdentityReviewState("error");
    }
  }

  /**
   * A timed-out session answers a fetch with a redirect to a sign-in page, which is a perfectly
   * successful HTML response. Parsing that as JSON would either throw or, worse, be handled as a
   * missing state -- so the content type is checked before anything is read.
   * @private
   */
  async _fetchIdentityReview(body, signal) {
    const response = await fetch(this.identityReviewUrlValue, {
      method: "POST",
      body,
      signal,
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": this._csrfToken(),
        "X-Requested-With": "XMLHttpRequest"
      }
    });

    // A timed-out session answers with a redirect to sign-in, which fetch follows and reports as a
    // perfectly successful HTML response. `redirected` is what separates that from a server error,
    // which is also HTML but was never redirected -- and the two need different advice, since no
    // amount of retrying fixes a session that has ended.
    if (response.redirected || response.status === 401) {
      throw new IdentityReviewFailure("session_expired", "identity review requires a signed-in session");
    }

    if (!response.ok) throw new Error(`identity review failed: ${response.status}`);
    const type = response.headers.get("Content-Type") || "";
    if (!type.includes("application/json")) throw new Error("identity review returned a non-JSON response");

    return response.json();
  }

  /**
   * Aborts the request if it has not settled in time, tagging the abort so it is not mistaken for
   * an invalidation -- which is also an abort, and which must stay silent.
   * @private
   */
  async _fetchIdentityReviewWithTimeout(body, controller) {
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, IDENTITY_REVIEW_TIMEOUT_MS);

    try {
      return await this._fetchIdentityReview(body, controller.signal);
    } catch (error) {
      if (timedOut) throw new IdentityReviewFailure("timed_out", "identity review timed out");
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }

  /** @private */
  _csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute("content") : "";
  }

  /**
   * Decides whether an answer still applies, and -- crucially -- leaves the state settled either way.
   *
   * Two kinds of staleness need different handling. A newer generation means something already
   * called invalidate and set the state itself, so this must not touch it. A *same*-generation
   * change means the facts moved without an event we listen for -- a value set programmatically, or
   * a field type we do not route -- and nothing else will settle it. Returning silently there was
   * what left `checking` in place and Submit disabled forever.
   * @private
   */
  _settleStaleIdentityReview(generation, snapshot) {
    if (generation !== this._identityReviewGeneration) return true;
    if (!this.element.isConnected) return true;

    const current = this._identityReviewPayload().snapshot;
    const changed = Object.keys(snapshot).some((key) => snapshot[key] !== current[key]);
    if (!changed && this._identityReviewContext()) return false;

    this._clearIdentityReviewContent();
    this._setIdentityReviewState("idle");
    return true;
  }

  /**
   * The bypass exists only for the width of this synchronous call. Leaving it set until some later
   * submit event would let a submission that never went through review slip past, because native
   * validation can prevent that event from ever arriving.
   * @private
   */
  _resumeNativeSubmission(submitter) {
    this._identityReviewBypass = true;
    try {
      this.element.requestSubmit(submitter || undefined);
    } finally {
      this._identityReviewBypass = false;
    }
  }

  /** @private */
  _abortIdentityReview() {
    if (this._identityReviewAbort) {
      this._identityReviewAbort.abort();
      this._identityReviewAbort = null;
    }
  }

  /** @private */
  _clearIdentityReviewTimer() {
    if (this._identityReviewTimer) {
      clearTimeout(this._identityReviewTimer);
      this._identityReviewTimer = null;
    }
  }

  /**
   * State transition plus the two side effects every transition needs: gating recomputed, and the
   * status region told what is happening. Kept in one place so a state can never be set without
   * the button and the announcement agreeing with it.
   * @private
   */
  _setIdentityReviewState(state) {
    this._identityReviewState = state;
    if (state === "idle") this._hideIdentityReviewPanel();
    this._renderIdentityReviewNotice(state);
    this._applySubmitGating();
  }

  /**
   * The operational states are not identity decisions, but they still have to be *seen*. Announcing
   * them only through the sr-only status region would leave sighted staff looking at a form that
   * silently did nothing -- and `checking` most of all, since it is the one state that also
   * disables Submit, so without it the button just stops working for no visible reason.
   * @private
   */
  static NOTICE_STATES = ["checking", "error", "timed_out", "session_expired", "expired"];

  _renderIdentityReviewNotice(state) {
    if (!this.hasIdentityReviewNoticeTarget) return;

    const message = this.constructor.NOTICE_STATES.includes(state) ? this._identityReviewNoticeBody(state) : null;
    if (!message) {
      setVisible(this.identityReviewNoticeTarget, false);
      return;
    }

    this.identityReviewNoticeTarget.textContent = message;
    setVisible(this.identityReviewNoticeTarget, true);
    if (this.hasIdentityReviewPanelTarget) setVisible(this.identityReviewPanelTarget, true);
    if (this.hasIdentityReviewHeadingTarget) {
      this.identityReviewHeadingTarget.textContent = this._identityReviewNoticeHeading(state);
    }

    // `checking` is transient and moves focus nowhere: pulling focus out of the field staff are
    // still in, for a state that resolves on its own a moment later, would be its own defect.
    if (state !== "checking") this.identityReviewNoticeTarget.focus();
  }

  /**
   * The sixth gating predicate. Setting `disabled` directly would be undone by the next input or
   * change event, because gating is recomputed from scratch each time.
   *
   * Error and expiry deliberately do *not* block: Submit becomes the retry. The click is
   * intercepted again by beforeSubmit, so it re-runs the check rather than falling through to an
   * unreviewed native submission.
   * @private
   */
  _identityReviewBlocksSubmit() {
    return ["checking", "possible_matches", "blocked", "invalid_contact_choice"]
      .includes(this._identityReviewState);
  }

  /** @private */
  _identityReviewStatusText() {
    // A refused candidate selection outranks the state description: the state has not changed --
    // staff are still looking at the same possible matches -- but something just happened, and it
    // is the only thing they need to hear. Cleared by the next attempt or by invalidation.
    if (this._candidateSelectionRefusal) return this._candidateSelectionRefusal;
    if (this._dependentContactChoiceMessage) return this._dependentContactChoiceMessage;

    switch (this._identityReviewState) {
      case "checking": return `Checking for existing ${this._identityReviewNoun({ plural: true })}…`;
      case "possible_matches": return "Review the possible matches before submitting.";
      case "blocked": return "Resolve the contact conflict before submitting.";
      case "invalid_contact_choice": return this._dependentContactChoiceMessage;
      case "error": return "Identity review could not be completed. Submit again to retry.";
      case "timed_out": return "Identity review took too long to respond. Submit again to retry.";
      // Truthful about the recovery: this page must not be reloaded or navigated away from, because
      // the four selected files cannot be restored, so signing in has to happen somewhere else.
      case "session_expired":
        return "Your session has expired. Sign in again in another browser tab, then submit again " +
               "here. Your entries and selected documents stay on this page.";
      case "expired": return "Review expired. Submit again to refresh the matches.";
      default: return null;
    }
  }

  /**
   * The visible body, which sits directly under a heading that already names the condition -- so it
   * carries the action rather than repeating the condition. The status text above stays a complete
   * sentence because it is announced on its own, with no heading beside it.
   * @private
   */
  _identityReviewNoticeBody(state) {
    switch (state) {
      case "checking": return "This only takes a moment. Nothing has been submitted yet.";
      case "error": return "Submit again to retry.";
      case "timed_out": return "Submit again to retry.";
      case "expired": return "Submit again to refresh the matches.";
      default: return this._identityReviewStatusText();
    }
  }

  /** @private */
  _identityReviewNoticeHeading(state) {
    switch (state) {
      case "checking": return `Checking for existing ${this._identityReviewNoun({ plural: true })}`;
      case "expired": return "Review expired";
      case "timed_out": return "Identity review timed out";
      case "session_expired": return "Session expired";
      default: return "Identity review unavailable";
    }
  }

  /**
   * One timer, no visible countdown. The deadline is also re-checked immediately before an override
   * is applied, because a suspended tab can delay a timer well past its due time.
   * @private
   */
  _scheduleIdentityReviewExpiry() {
    this._clearIdentityReviewTimer();
    if (!this._identityReviewExpiresAt) return;

    const delay = this._identityReviewExpiresAt - Date.now();
    if (delay <= 0) {
      this._expireIdentityReview();
      return;
    }
    this._identityReviewTimer = setTimeout(() => this._expireIdentityReview(), delay);
  }

  /** @private */
  _identityReviewExpired() {
    return !!this._identityReviewExpiresAt && Date.now() >= this._identityReviewExpiresAt;
  }

  /** @private */
  _expireIdentityReview() {
    this._clearIdentityReviewTimer();
    this._identityReviewToken = null;
    this._clearIdentityDecisionField();
    // The shared reset rather than a partial copy of it. Setting the state immediately afterwards
    // rebuilds the panel around the expiry notice, so nothing is lost by clearing all of it -- and
    // the copy was already drifting: it never cleared the candidate-selection refusal.
    this._clearIdentityReviewContent();
    this._setIdentityReviewState("expired");
  }

  /**
   * Any change to what the review was about invalidates it. Without this an answer about one
   * applicant stays on screen, and its token stays in the hidden field, while staff edit their way
   * to a different person.
   */
  invalidateIdentityReview() {
    // Not just "is a panel showing". After an override the state is idle again but the hidden field
    // holds a token bound to the facts as they were, so an edit here has to clear it. The server
    // would reject that token anyway, but only after the whole multipart submission -- which is the
    // round trip, and the file selections, this design exists to avoid.
    const holdsDecision = this.hasIdentityDecisionTarget && !!this.identityDecisionTarget.value;
    const selecting = !!this._candidateSelectionInFlight;
    if (this._identityReviewState === "idle" && !holdsDecision && !this._identityReviewToken && !selecting) return;

    this._abortCandidateSelection();
    this._abortIdentityReview();
    this._identityReviewGeneration += 1;
    this._clearIdentityReviewTimer();
    this._identityReviewToken = null;
    this._identityReviewExpiresAt = null;
    this._clearIdentityDecisionField();
    this._clearIdentityReviewContent();
    this._setIdentityReviewState("idle");
  }

  /** @private */
  _clearIdentityDecisionField() {
    if (this.hasIdentityDecisionTarget) this.identityDecisionTarget.value = "";
  }

  /**
   * Candidate values come from the server as JSON and are written with textContent, never
   * interpolated into markup. They are names and addresses staff typed, so markup in them is
   * plausible rather than exotic.
   * @private
   */
  _renderPossibleMatches(payload) {
    if (!this.hasIdentityReviewCandidatesTarget) return;

    this.identityReviewCandidatesTarget.replaceChildren();
    (payload.candidates || []).forEach((candidate) => {
      this.identityReviewCandidatesTarget.appendChild(this._candidateRow(candidate));
    });

    if (this.hasIdentityReviewBodyTarget) {
      this.identityReviewBodyTarget.textContent = this._identityReviewContext() === "dependent"
        ? "Is one of these people the dependent on this paper application?"
        : "Are any of these people the applicant?";
    }
    if (this.hasIdentityReviewOverrideTarget) {
      setVisible(this.identityReviewOverrideTarget, true);
    }
    if (this.hasIdentityReviewOverrideButtonTarget) {
      this.identityReviewOverrideButtonTarget.textContent =
        `These are different people — create a new ${this._identityReviewNoun()}`;
    }
    this._showIdentityReviewPanel(this._identityReviewContext() === "dependent"
      ? "Possible matching dependents" : "Possible matching constituents");
  }

  /** @private */
  _candidateRow(candidate) {
    const row = document.createElement("li");
    row.className = "flex items-center justify-between gap-4 py-2";

    const facts = document.createElement("div");
    [candidate.name, candidate.date_of_birth, [candidate.city, candidate.state, candidate.zip_code].filter(Boolean).join(" ")]
      .filter((value) => value && String(value).trim())
      .forEach((value) => {
        const line = document.createElement("div");
        line.textContent = String(value);
        facts.appendChild(line);
      });
    row.appendChild(facts);

    if (candidate.selectable) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "px-3 py-1 border rounded text-sm";
      const dependent = this._identityReviewContext() === "dependent";
      button.textContent = dependent ? "Use this dependent" : "Use this constituent";
      // Every row's visible label is identical, so the accessible name carries the distinguishing
      // fact. Otherwise a screen-reader user hears the same button repeated N times.
      button.setAttribute("aria-label", `Use this ${dependent ? "dependent" : "constituent"}: ${String(candidate.name || "")}`);
      button.addEventListener("click", () => this._selectIdentityReviewCandidate(candidate));
      row.appendChild(button);
    } else {
      // Reported so staff understand the block, but not offered as a choice.
      const note = document.createElement("span");
      note.className = "text-sm text-gray-600";
      note.textContent = this._identityReviewContext() === "dependent"
        ? "Not an eligible on-file dependent for this guardian"
        : "Not available as a paper applicant";
      row.appendChild(note);
    }

    return row;
  }

  /**
   * An exact contact collision cannot be overridden, so no token is offered and the override action
   * stays hidden. The copy names the routes out without echoing the other record's contact back.
   * @private
   */
  _renderContactBlock(payload) {
    if (this.hasIdentityReviewCandidatesTarget) this.identityReviewCandidatesTarget.replaceChildren();
    if (this.hasIdentityReviewOverrideTarget) setVisible(this.identityReviewOverrideTarget, false);

    const candidates = payload.candidates || [];
    if (this.hasIdentityReviewBodyTarget) {
      const split = (payload.reasons || []).includes("email_phone_split");
      const dependent = this._identityReviewContext() === "dependent";
      const hasSelectableCandidate = candidates.some((candidate) => candidate.selectable);
      if (split) {
        this.identityReviewBodyTarget.textContent =
          "The email and the phone number each already belong to a different existing record. " +
          "Selecting one of them will not resolve the other. Correct the entered contact information, " +
          "or contact the MAT Team for assistance.";
      } else if (dependent && hasSelectableCandidate) {
        this.identityReviewBodyTarget.textContent =
          "This email or phone is already associated with an existing record. Select the eligible " +
          "on-file dependent shown below, correct the dependent's entered contact information, or " +
          "contact the MAT Team for assistance.";
      } else if (dependent) {
        this.identityReviewBodyTarget.textContent =
          "This email or phone is already associated with an existing record, but no eligible on-file " +
          "dependent for this guardian is available to select. Correct the dependent's entered contact " +
          "information or contact the MAT Team for assistance.";
      } else if (hasSelectableCandidate) {
        this.identityReviewBodyTarget.textContent =
          "This email or phone is already associated with an existing record. Select the existing " +
          "constituent, correct the entered contact information, or contact the MAT Team for assistance.";
      } else {
        this.identityReviewBodyTarget.textContent =
          "This email or phone is already associated with an existing record, but no eligible constituent " +
          "is available to select. Correct the entered contact information or contact the MAT Team for assistance.";
      }
    }

    candidates.forEach((candidate) => {
      if (this.hasIdentityReviewCandidatesTarget) {
        this.identityReviewCandidatesTarget.appendChild(this._candidateRow(candidate));
      }
    });

    this._showIdentityReviewPanel("Existing contact information");
  }

  /** @private */
  _renderDependentContactChoice(payload) {
    if (this.hasIdentityReviewCandidatesTarget) this.identityReviewCandidatesTarget.replaceChildren();
    if (this.hasIdentityReviewOverrideTarget) setVisible(this.identityReviewOverrideTarget, false);

    this._dependentContactChoiceField = String(payload.field || "");
    this._dependentContactChoiceMessage = String(payload.message ||
      "Review the dependent's contact choice before submitting.");
    if (this.hasIdentityReviewBodyTarget) {
      this.identityReviewBodyTarget.textContent = this._dependentContactChoiceMessage;
    }

    this._showIdentityReviewPanel("Dependent contact information needed");
    const field = this.element.querySelector(
      `[name="constituent[${this._dependentContactChoiceField}]"]:not([disabled])`
    );
    if (field) {
      field.setAttribute("aria-invalid", "true");
      field.focus();
    }
  }

  /** @private */
  _showIdentityReviewPanel(heading) {
    if (this.hasIdentityReviewHeadingTarget) this.identityReviewHeadingTarget.textContent = heading;
    if (!this.hasIdentityReviewPanelTarget) return;

    setVisible(this.identityReviewPanelTarget, true);
    if (this.hasIdentityReviewHeadingTarget) this.identityReviewHeadingTarget.focus();
  }

  /** @private */
  _hideIdentityReviewPanel() {
    if (this.hasIdentityReviewPanelTarget) setVisible(this.identityReviewPanelTarget, false);
  }

  /**
   * Hiding the panel is not enough. Its rows, body and override button survive, so the next thing
   * that shows the panel -- an error after staff edited the applicant -- would display the previous
   * applicant's candidates and an override button for a decision that no longer exists.
   * @private
   */
  _clearIdentityReviewContent() {
    // The refusal was about candidates that are being discarded along with everything else here, so
    // it dies with them. Cleared in this one place rather than at each call site: it outlived the
    // panel on every path that reset content without an identity edit -- an expiry, or simply
    // submitting again -- and the live region went on announcing "already has an active
    // application" while the panel said "Review expired".
    this._candidateSelectionRefusal = null;
    if (this._dependentContactChoiceField) {
      const field = this.element.querySelector(
        `[name="constituent[${this._dependentContactChoiceField}]"]`
      );
      if (field) field.removeAttribute("aria-invalid");
    }
    this._dependentContactChoiceField = null;
    this._dependentContactChoiceMessage = null;
    if (this.hasIdentityReviewCandidatesTarget) this.identityReviewCandidatesTarget.replaceChildren();
    if (this.hasIdentityReviewBodyTarget) this.identityReviewBodyTarget.textContent = "";
    if (this.hasIdentityReviewOverrideTarget) setVisible(this.identityReviewOverrideTarget, false);
    if (this.hasIdentityReviewNoticeTarget) {
      this.identityReviewNoticeTarget.textContent = "";
      setVisible(this.identityReviewNoticeTarget, false);
    }
    this._hideIdentityReviewPanel();
  }

  /**
   * The override. Only this action puts the token into the hidden field -- receiving a token from
   * the endpoint is not itself a decision, and populating the field on arrival would let a
   * submission carry an override staff never made.
   */
  overrideIdentityReview() {
    if (!this._identityReviewToken || this._identityReviewExpired()) {
      this._expireIdentityReview();
      return;
    }

    if (this.hasIdentityDecisionTarget) this.identityDecisionTarget.value = this._identityReviewToken;
    this._hideIdentityReviewPanel();
    this._identityReviewState = "idle";
    this._applySubmitGating();
    this._resumeNativeSubmission(this._identityReviewSubmitter);
  }

  /**
   * Adult selection goes through a dedicated picker entry point that checks eligibility. Dependent
   * selection first refreshes the server-owned identity review, which composes guardian
   * relationship and application eligibility policy, before the picker may set dependent_id.
   * The final writer still requalifies either choice under its transaction lock.
   * @private
   */
  async _selectIdentityReviewCandidate(candidate) {
    // Single-flight. Two quick clicks can otherwise resolve out of order and let the earlier
    // eligibility answer overwrite the later choice.
    if (this._candidateSelectionInFlight) return;

    const dependentContext = this._identityReviewContext() === "dependent";
    const root = this.element.querySelector(dependentContext
      ? "[data-controller~='guardian-picker']" : "[data-controller~='adult-picker']");
    if (!root || !this.application) return;

    const identifier = dependentContext ? "guardian-picker" : "adult-picker";
    const method = dependentContext ? "selectDependentFromIdentityReview" : "selectAdultFromIdentityReview";
    const picker = this.application.getControllerForElementAndIdentifier(root, identifier);
    if (!picker || typeof picker[method] !== "function") return;

    this._candidateSelectionInFlight = true;
    this._candidateSelectionRefusal = null;
    this._setCandidateActionsDisabled(true);
    // Single-flight stops a second click, but not staff editing the applicant while eligibility is
    // loading. Without this the request resolves afterwards and selects a candidate for an identity
    // that no longer exists on screen.
    const abort = new AbortController();
    this._candidateSelectionAbort = abort;
    let outcome;
    try {
      if (dependentContext) {
        const refreshed = await this._recheckDependentIdentityCandidate(candidate, abort);
        outcome = refreshed.selected
          ? await picker[method](refreshed.candidate, { signal: abort.signal })
          : refreshed;
      } else {
        outcome = await picker[method](candidate, { signal: abort.signal });
      }
    } finally {
      this._candidateSelectionInFlight = false;
      this._candidateSelectionAbort = null;
      this._setCandidateActionsDisabled(false);
    }

    if (abort.signal.aborted) return;

    if (outcome && outcome.selected) {
      this.invalidateIdentityReview();
      return;
    }

    if (outcome && outcome.reason) {
      if (this.hasIdentityReviewBodyTarget) this.identityReviewBodyTarget.textContent = outcome.reason;
      // The panel body is an ordinary paragraph, so replacing its text tells a screen-reader user
      // nothing: the click appears to do nothing at all. Focus cannot move here either -- staff are
      // still choosing between candidates, and the buttons they are moving through have just been
      // re-enabled. So the refusal is announced through the form's existing polite status region,
      // which gating already owns and which is the one live region on the page.
      this._candidateSelectionRefusal = outcome.reason;
      this._applySubmitGating();
    }
  }

  /** @private */
  async _recheckDependentIdentityCandidate(candidate, controller) {
    const { body } = this._identityReviewPayload();

    try {
      const payload = await this._fetchIdentityReviewWithTimeout(body, controller);
      if (controller.signal.aborted) return { selected: false };

      const refreshed = (payload.candidates || []).find((row) =>
        String(row.id) === String(candidate.id)
      );
      if (refreshed?.selectable === true) return { selected: true, candidate: refreshed };

      return {
        selected: false,
        reason: "This record is no longer an eligible on-file dependent for the selected guardian. " +
                "Review the current matches or correct the dependent details."
      };
    } catch (error) {
      if (controller.signal.aborted && error?.kind !== "timed_out") return { selected: false };

      if (error instanceof IdentityReviewFailure && error.kind === "session_expired") {
        return {
          selected: false,
          reason: "Your session has expired. Sign in again in another browser tab, then try again " +
                  "here. Your entries and selected documents stay on this page."
        };
      }
      if (error instanceof IdentityReviewFailure && error.kind === "timed_out") {
        return { selected: false, reason: "Checking that record took too long. Try again." };
      }

      return { selected: false, reason: "That record could not be checked right now. Try again." };
    }
  }

  /** @private */
  _abortCandidateSelection() {
    if (this._candidateSelectionAbort) {
      this._candidateSelectionAbort.abort();
      this._candidateSelectionAbort = null;
    }
  }

  /** @private */
  _setCandidateActionsDisabled(disabled) {
    if (!this.hasIdentityReviewCandidatesTarget) return;

    this.identityReviewCandidatesTarget.querySelectorAll("button").forEach((button) => {
      button.disabled = disabled;
    });
  }

  /**
   * @private
   */
  _adultVerificationBlocksSubmit() {
    const idInput = this.element.querySelector('[name="existing_constituent_id"]');
    if (!idInput || idInput.disabled || !String(idInput.value || "").trim()) return false;

    const checkbox = this.element.querySelector(
      'input[type="checkbox"][name="contact_info_verified"][data-adult-picker-target="verificationCheckbox"]'
    );
    if (!checkbox || checkbox.disabled) return false;

    return !checkbox.checked;
  }

  /**
   * @private
   */
  _applySubmitGating() {
    const incomeBlocks = !!this._incomeExceedsThreshold;
    const verifyBlocks = this._adultVerificationBlocksSubmit();
    const requiredControlBlocks = this._requiredControlsBlockSubmit();
    const proofActionBlocks = this._requiredRadioGroupBlocksSubmit();
    const checkboxGroupBlocks = this._checkboxGroupBlocksSubmit();
    const reviewBlocks = this._identityReviewBlocksSubmit();
    const guardianSelectionBlocks = this._guardianSelectionBlocksSubmit();
    const disable = incomeBlocks || verifyBlocks || requiredControlBlocks || proofActionBlocks ||
      checkboxGroupBlocks || reviewBlocks || guardianSelectionBlocks;

    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = disable;
      this.submitButtonTarget.setAttribute("aria-disabled", disable ? "true" : "false");
      if (disable) {
        this.submitButtonTarget.setAttribute("disabled", "disabled");
      } else {
        this.submitButtonTarget.removeAttribute("disabled");
      }
    }

    if (this.hasStatusTarget) {
      // Identity-review states describe themselves; a generic "complete the confirmations" message
      // would tell staff nothing about what the server just found.
      const reviewText = this._identityReviewStatusText();
      this.statusTarget.textContent = reviewText || (guardianSelectionBlocks
        ? "Select or create a guardian before submitting this dependent's application."
        : (disable
          ? "Complete all required confirmations before submitting."
          : "Paper application is ready to submit."));
    }

    if (this.hasRejectionButtonTarget) {
      setVisible(this.rejectionButtonTarget, incomeBlocks);
    } else if (incomeBlocks) {
      console.warn("Missing rejectionButton target - check HTML structure");
    }
  }

  _guardianSelectionBlocksSubmit() {
    const type = this.element.querySelector('[name="applicant_type"]:checked');
    if (type?.value !== "dependent") return false;

    const guardian = this.element.querySelector('[name="guardian_id"]');
    return !String(guardian?.value || "").trim();
  }

  /**
   * Toggle medical provider fields visibility and required attribute
   * When "No medical provider information provided" is checked, hide fields and remove required
   */
  toggleMedicalProvider(event) {
    this.syncFormState(event);
  }

  syncFormState(event = null) {
    this.syncMedicalProviderRequirement(event);
    this._applySubmitGating();
  }

  syncMedicalProviderRequirement(event = null) {
    if (event?.target && !this._isMedicalProviderControl(event.target)) return;

    const checkbox = this.element.querySelector('input[name="no_medical_provider_information"]');
    if (!checkbox) return;

    const fieldset = checkbox.closest('fieldset');
    if (!fieldset) return;

    const isChecked = checkbox.checked;
    const medicalProviderFields = Array.from(fieldset.querySelectorAll('input, select, textarea'))
      .filter((field) => field.name?.startsWith("application[medical_provider_"));
    const requiredProviderFields = Array.from(medicalProviderFields)
      .filter((field) => this._isApplicationMedicalProviderField(field));
    const hasProviderInfo = medicalProviderFields
      .some((field) => String(field.value || "").trim() !== "");
    const description = fieldset.querySelector('p.text-sm');
    const fieldsContainer = fieldset.querySelector('.grid');
    const medicalRelease = fieldset.querySelector('input[type="checkbox"][name="application[medical_release_authorized]"]');

    if (isChecked) {
      if (description) description.classList.add('hidden');
      if (fieldsContainer) fieldsContainer.classList.add('hidden');

      this._setRequired(requiredProviderFields, false);
      this._setRequired([medicalRelease], false);
      checkbox.required = false;
      checkbox.setCustomValidity("");
      return;
    }

    if (description) description.classList.remove('hidden');
    if (fieldsContainer) fieldsContainer.classList.remove('hidden');

    this._setRequired(requiredProviderFields, hasProviderInfo);
    this._setRequired([medicalRelease], hasProviderInfo);
    checkbox.required = !hasProviderInfo;
    checkbox.setCustomValidity(hasProviderInfo ? "" : "Check this box if no certifying professional information was provided.");
  }

  _isApplicationMedicalProviderField(field) {
    return field.name.startsWith("application[medical_provider_") && !field.name.includes("fax");
  }

  _isMedicalProviderControl(field) {
    return field.name === "no_medical_provider_information" ||
      field.name?.startsWith("application[medical_provider_");
  }

  _setRequired(fields, required) {
    fields.filter(Boolean).forEach((field) => {
      if (required) {
        field.setAttribute('required', 'required');
        field.setAttribute('aria-required', 'true');
      } else {
        field.removeAttribute('required');
        field.removeAttribute('aria-required');
      }
    });
  }

  _requiredControlsBlockSubmit() {
    return this._enabledVisibleFields('input[type="checkbox"][required]')
      .concat(this._enabledVisibleFields(
        'input[required]:not([type="checkbox"]):not([type="radio"]):not([type="hidden"]):not([type="submit"]):not([type="button"]):not([type="reset"]), select[required], textarea[required]'
      ))
      .some((field) => this._fieldInvalid(field));
  }

  _requiredRadioGroupBlocksSubmit() {
    const radios = this._enabledVisibleFields('input[type="radio"][required]');
    const names = [...new Set(radios.map((radio) => radio.name).filter(Boolean))];

    return names.some((name) => {
      const group = radios.filter((radio) => radio.name === name);
      return group.length > 0 && !group.some((radio) => radio.checked);
    });
  }

  _checkboxGroupBlocksSubmit() {
    return Array.from(this.element.querySelectorAll("[data-requires-one-checkbox]"))
      .filter((group) => this.elementIsVisible(group))
      .some((group) => {
        const checkboxes = Array.from(group.querySelectorAll('input[type="checkbox"]'))
          .filter((field) => !field.disabled && this.elementIsVisible(field));
        return checkboxes.length > 0 && !checkboxes.some((field) => field.checked);
      });
  }

  _enabledVisibleFields(selector) {
    return Array.from(this.element.querySelectorAll(selector))
      .filter((field) => !field.disabled && this.elementIsVisible(field));
  }

  _fieldInvalid(field) {
    if ((field.type || "").toLowerCase() === "file") {
      return field.required && (!field.files || field.files.length === 0);
    }

    if (typeof field.checkValidity === "function") {
      return !field.checkValidity();
    }

    return String(field.value || "").trim() === "";
  }

  /**
   * Temporary method to prevent errors - this functionality should be handled by income-validation controller
   * TODO: Replace with proper income-validation controller setup
   */
  validateIncomeThreshold() {
    if (process.env.NODE_ENV !== 'production') {
      console.warn('validateIncomeThreshold called on paper-application controller - this should be handled by income-validation controller');
    }
    // For now, prevent the error - the income validation should be handled elsewhere
  }

  /**
   * Open the rejection modal and populate hidden fields with data from the main form.
   * Uses native <dialog> showModal() API for proper accessibility.
   */
  openRejectionModal() {
    const dialog = document.getElementById('rejection-modal');
    if (!dialog) {
      console.error('Rejection modal not found');
      return;
    }

    // Populate hidden fields from main form values
    this._populateRejectionModalFields();

    // Open the dialog using native API
    if (dialog.tagName === 'DIALOG') {
      dialog.showModal();
    } else {
      console.warn('rejection-modal is not a <dialog> element');
      setVisible(dialog, true);
    }
  }

  updateLanguagePreferenceNotices() {
    if (!this.hasLanguagePreferenceNoticeTarget) return;

    const locale = this.currentApplicantLocale();
    const message = locale === 'es'
      ? 'Applicant prefers to receive Spanish communications. Please ensure any custom rejection reason is translated.'
      : 'Applicant prefers to receive English communications.';

    this.languagePreferenceNoticeTargets.forEach((target) => {
      target.textContent = message;
    });
  }

  currentApplicantLocale() {
    if (!this.hasApplicantLocaleTarget) return 'en';

    const visibleSelect = this.applicantLocaleTargets.find((target) => this.elementIsVisible(target));
    if (visibleSelect && visibleSelect.value) return visibleSelect.value;

    return this.applicantLocaleTargets[0]?.value || 'en';
  }

  elementIsVisible(element) {
    return !!(element.offsetParent || element.getClientRects().length);
  }

  /**
   * Populate the rejection modal hidden fields with values from the main form
   * @private
   */
  _populateRejectionModalFields() {
    // Get values from main form fields
    const firstName = this.element.querySelector('[name="constituent[first_name]"]')?.value ||
                      this.element.querySelector('[name="guardian_attributes[first_name]"]')?.value || '';
    const lastName = this.element.querySelector('[name="constituent[last_name]"]')?.value ||
                     this.element.querySelector('[name="guardian_attributes[last_name]"]')?.value || '';
    const dependentEmail = this.element.querySelector('[name="constituent[dependent_email]"]')?.value || '';
    const email = this.element.querySelector('[name="constituent[email]"]')?.value ||
                  dependentEmail ||
                  this.element.querySelector('[name="guardian_attributes[email]"]')?.value || '';
    const phone = this.element.querySelector('[name="constituent[phone]"]')?.value ||
                  this.element.querySelector('[name="guardian_attributes[phone]"]')?.value || '';
    const recipientId = this.element.querySelector('[name="dependent_id"]')?.value || '';
    const householdSize = this.element.querySelector('[name="application[household_size]"]')?.value || '';
    const annualIncome = this.element.querySelector('[name="application[annual_income]"]')?.value || '';

    if (this.hasRejectionFirstNameTarget) this.rejectionFirstNameTarget.value = firstName;
    if (this.hasRejectionLastNameTarget) this.rejectionLastNameTarget.value = lastName;
    if (this.hasRejectionRecipientIdTarget) this.rejectionRecipientIdTarget.value = recipientId;
    if (this.hasRejectionEmailTarget) this.rejectionEmailTarget.value = email;
    if (this.hasRejectionDependentEmailTarget) this.rejectionDependentEmailTarget.value = dependentEmail;
    if (this.hasRejectionPhoneTarget) this.rejectionPhoneTarget.value = phone;
    if (this.hasRejectionHouseholdSizeTarget) this.rejectionHouseholdSizeTarget.value = householdSize;
    if (this.hasRejectionAnnualIncomeTarget) this.rejectionAnnualIncomeTarget.value = annualIncome;

    this._loadExistingRecipientPreference({ recipientId, email });

    if (process.env.NODE_ENV !== 'production') {
      console.log('Populated rejection modal fields:', {
        firstName, lastName, recipientId, email, dependentEmail, phone, householdSize, annualIncome
      });
    }
  }

  async _loadExistingRecipientPreference({ recipientId, email }) {
    if (!this.hasRejectionExistingPreferenceNoticeTarget || !this.hasRejectionExistingPreferenceValueTarget) return;

    this.rejectionExistingPreferenceNoticeTarget.classList.add('hidden');
    this.rejectionExistingPreferenceValueTarget.textContent = '';

    if (!recipientId && !email) return;

    const query = new URLSearchParams();
    if (recipientId) query.set('id', recipientId);
    if (email) query.set('email', email.trim().toLowerCase());

    try {
      const response = await fetch(`/admin/paper_applications/recipient_preference?${query.toString()}`, {
        headers: { Accept: 'application/json' },
        credentials: 'same-origin'
      });
      if (!response.ok) return;

      const data = await response.json();
      if (!data.found) return;

      if (data.recipient_id && this.hasRejectionRecipientIdTarget) {
        this.rejectionRecipientIdTarget.value = data.recipient_id;
      }

      const preference = (data.communication_preference || '').toString().toLowerCase();
      if (!['email', 'letter'].includes(preference)) return;

      this._setNotificationPreferenceRadio(preference);

      this.rejectionExistingPreferenceValueTarget.textContent =
        preference === 'letter' ? 'Printed Letter' : 'Email';
      this.rejectionExistingPreferenceNoticeTarget.classList.remove('hidden');
    } catch (_error) {
      // Non-blocking enhancement: keep modal functional even if lookup fails.
    }
  }

  _setNotificationPreferenceRadio(preference) {
    const radio = this.element.querySelector(`input[name="communication_preference"][value="${preference}"]`);
    if (radio) radio.checked = true;
  }
}
