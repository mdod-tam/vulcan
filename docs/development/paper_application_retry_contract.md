# Paper intake retry contract

Tracked deliberately: this is the contract the paper form's re-render must satisfy, and a contract
that lives outside the repository cannot be reviewed with the code it governs.

What the re-rendered paper form must put back after a failed create, where each value comes from,
and which layer proves it. Written because five review rounds each found a field that was accepted
for processing and silently dropped on retry; the pattern is always the same and this is the list
that makes it checkable.

## The set-difference contract

Two allowlists exist in `Admin::PaperApplicationsController`:

- **processing** — `permitted_paper_params`, what the service may act on.
- **retry** — `build_submitted_params`, what the re-render may put back.

Every field in *processing* is either in *retry* or deliberately excluded for a stated reason. There
are two standing exclusions, eight fields in total:

- The four native file inputs (`income_proof`, `residency_proof`, `id_proof`,
  `medical_certification`), which no server render can repopulate.
- The four matching `*_signed_id` fields, which are processing-only: each names a blob already
  uploaded directly to storage. Echoing one back would claim an attachment the form cannot show and
  staff cannot verify, and reattaching the file mints a new signed id anyway.

A field in processing but not in retry is a silent data-loss bug. That is exactly how the proof
actions, the two no-information flags, and the guardian/dependent selection were each lost.

## Where each group is restored from, and what proves it

| Group | Restored from | Trap | Proved by |
|---|---|---|---|
| Applicant/constituent fields | rebuilt `Constituent`, `submitted_params[:constituent]` | dependent fieldset shares these names and is disabled, not removed | request + system |
| Application fields | rebuilt `Application`, `submitted_params[:application]` | `fields_for :application` was unbound | request + system |
| Disability booleans | rebuilt `Constituent` via `applicant_attributes` | group is mixed: five User columns plus one Application column | request |
| `self_certify_disability` | rebuilt `Application`, sourced from `applicant_attributes` | posts under one key, stored on another model; nil before `create_application` | request |
| Proof actions ×4 | `submitted_params`, radios bind `checked` | medical had a hardcoded `checked` that won by document order | request + system |
| Rejection reason + custom text ×4 | `submitted_params`, `selected` / textarea body | accepted for processing, absent from retry | request |
| `no_medical_provider_information`, `no_income_information` | `submitted_params`, boolean-cast | absent from retry; their loss re-imposes validation | request |
| Applicant-type branch | `@applicant_type` | radios are disabled once locked, so a retry omits the param | request + system |
| Guardian selection | `submitted_params[:guardian_id]` + `@selected_guardian` | picker fills the identity box only on click, so the id restored but the name did not | request + system |
| Dependent selection | `submitted_params[:dependent_id]` + `@selected_dependent` | `mode: :new` described the opposite of what the next POST does | request |
| Inline guardian fields | rebuilt `Users::Constituent` | `fields_for` bound to a raw hash raises on every reader | request |
| Dependent own email/phone | `submitted_params[:constituent]` | params, not columns; `.presence` overrode deliberate blanks | request + system |
| Contact strategies ×3 | `submitted_params`, hidden `"0"` companion | browsers omit unchecked boxes entirely | system |
| Relationship type | `submitted_params[:relationship_type]` | `options_for_select` ignores the bound object | system |
| Alternate contact relationship | rebuilt `Application` | same `options_for_select` trap | request |
| State fields | rebuilt record | hardcoded `"MD"` overrode submissions | request |
| Four file inputs | **not restorable** | — | asserted empty, then reselected |

## Which layer proves what

- **Request/view tests** — value binding, and the blank/false/absent distinctions. Cheap, exhaustive,
  and the right place for "did this field come back".
- **System tests** — picker behaviour, branch reveal, connect-time Stimulus, and anything where the
  browser's own submission rules matter (unchecked boxes are omitted; disabled controls are not
  submitted). A request test posting an explicit `"0"` cannot reproduce those.
- **Non-vacuity** — each mechanism above was verified by removing the fix and watching the test fail.

## Decided: existing-dependent identity is read-only

### Scope

Retry reliability remains this work's primary purpose. Alongside it, this change ratifies one
identity decision, stated here so reviewers see the full boundary:

- **Read-only existing-dependent identity, on both initial selection and retry.** Selecting an
  on-file dependent through the ordinary `dependent_form` Turbo endpoint renders name and date of
  birth as text, and so does the retry re-render. Both, because the writer behaves identically
  either way — a form that claimed otherwise on one path would be lying on that path.
- **No duplicate detection, merge, case, or import behaviour is added.** This decides which identity
  facts staff may edit for someone already on file. Nothing here detects duplicates, merges records,
  opens or resolves duplicate-review cases, or imports anyone.
- **Paper A2 inherits this existing-dependent contract** and owns the new guardian/dependent identity
  decisions. Changing identity editing for an *existing* dependent later would be a separate
  decision needing its own review.

For an **existing dependent**, first name, last name, and date of birth render as on-file text, not
inputs. They were editable while the writer never persisted them, so a correction looked accepted
and was silently discarded on success. Retry restoration made the *failure* path truthful; the
success path was still lying.

Decided read-only rather than editable because:

- Name and date of birth are the identity tuple `Users::Constituent.find_duplicates` matches on and
  the identity decision is signed over. Editing them changes which person the record represents.
- The paper writer does not own identity changes. `build_dependent_contact_updates` deliberately
  covers contact, address, and preference only.
- The existing-adult contact toggle is not a precedent: updating contact does not redefine who the
  record is.
- Doing it properly is not three more allowlisted fields. It needs duplicate re-evaluation,
  eligibility recalculation, locking, authorization, and a field-level before/after audit. That is
  its own canonical action, to be designed separately.

Consequences, all implemented:

| | Behaviour |
|---|---|
| New dependent | Identity fields stay editable |
| Existing dependent | Identity rendered as text; **no hidden copies submitted** -- `dependent_id` alone identifies the record |
| Where it applies | Initial selection (`dependent_form` Turbo endpoint, `mode == :edit`) **and** the retry re-render |
| Copy | "Using existing dependent: … These are the identity details currently on file and cannot be changed during paper intake." The former "Review and update their information" and "Verify carefully before changing" are gone |
| Contact, address, preferences | Remain editable, because the writer genuinely persists them |
| Branch inference | `inferred_dependent_application_from` accepts `dependent_id`, since a selected dependent now submits no name |

The UI deliberately does **not** offer a correction link. The current admin edit route is not that
workflow yet: it permits first and last name but not date of birth, and its `user_updated` audit
records the administrator rather than the field-level identity change. Promising a route that does
not exist would be the same class of false assurance this decision removes.

## A trap worth naming

Rendering identity read-only meant wrapping an existing markup block in `<% if %> / <% else %>`. The
`<% end %>` landed *before* two `</div>` closers, so the read-only branch emitted unmatched closing
tags. The browser reparented everything after them, which pushed the `commonSections` container
outside the `<form>` -- and the applicant-type controller, whose target it is, could no longer see
it. The visible symptom was that a retry showed no application, disability, proof, or attestation
sections at all, with the controller's own inputs (`guardianChosen`, `dependentRadioSelected`) both
correctly `true`.

It was found by asking the live Stimulus instance what it could see, rather than by reading the
condition: `hasCommonSectionsTarget: false` alongside `showCommonWouldBe: true` pointed straight at
nesting rather than logic. Both branches of that partial now render balanced markup, asserted by
rendering each and counting tags.

## Known gaps

- The inline-guardian **retry** is covered at request level only. A browser test reaches the inline
  guardian form itself (`paper_application_dependent_guardian_test.rb`), but nothing captures that
  form failing and coming back with its fields restored; doing so needs the guardian creation flow,
  which A2 is about to replace.
