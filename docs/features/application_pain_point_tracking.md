# Application Pain Point Tracking

Tracks the last successfully autosaved application field for draft applications so admins can review where online applicants stop making progress.

## High-Level Flow

1. The online application form registers the Stimulus `autosave` controller.
2. On field blur, `app/javascript/controllers/forms/autosave_controller.js` PATCHes the field name and value to `ConstituentPortal::ApplicationsController#autosave_field`.
3. The controller delegates to `Applications::AutosaveService`.
4. The service loads the requested application or, when no id is present, finds or creates a draft.
5. If the field is autosavable and saves successfully, the service writes the normalized attribute name to `applications.last_visited_step`.
6. The admin pain point report groups draft applications by `last_visited_step` and displays the counts.

## Entry Points

| Layer | Path | Behavior |
|-------|------|----------|
| New application form | `app/views/constituent_portal/applications/new.html.erb` | Uses the collection autosave route until the first draft is created, then the Stimulus controller updates the form and autosave URLs with the new application id. |
| Edit application form | `app/views/constituent_portal/applications/edit.html.erb` | Uses the member autosave route for the existing draft. |
| Stimulus controller | `app/javascript/controllers/forms/autosave_controller.js` | Sends non-file input, select, and textarea fields on blur. Skips file inputs and fields marked `data-no-autosave`. |
| Rails controller | `app/controllers/constituent_portal/applications_controller.rb` | `autosave_field` calls `Applications::AutosaveService` and returns JSON success or field errors. |
| Service | `app/services/applications/autosave_service.rb` | Owns field allowlisting, type casting, draft lookup/creation, field persistence, and `last_visited_step` updates. |
| Analytics model query | `app/models/application.rb` | `Application.pain_point_analysis` groups draft applications with a nonblank `last_visited_step` and orders by count descending. |
| Admin report | `app/controllers/admin/application_analytics_controller.rb` and `app/views/admin/application_analytics/pain_points.html.erb` | Shows the grouped results in a table. |

## Routes

| Route helper | Verb and path | Use |
|--------------|---------------|-----|
| `autosave_field_constituent_portal_applications_path` | `PATCH /constituent_portal/applications/autosave_field` | Autosave before a draft application id exists. |
| `autosave_field_constituent_portal_application_path(application)` | `PATCH /constituent_portal/applications/:id/autosave_field` | Autosave an existing draft. |
| `admin_application_analytics_pain_points_path` | `GET /admin/application_analytics/pain_points` | Admin report. |

## Key Concepts

| Concept | Current behavior |
|---------|------------------|
| `last_visited_step` | A string column on `applications`. Despite the name, it stores the last successfully autosaved field attribute, such as `household_size` or `hearing_disability`, not a wizard page name. |
| Draft-only reporting | `Application.pain_point_analysis` uses the `Application.draft` scope and ignores blank `last_visited_step` values. |
| Autosavable application fields | `Applications::AutosaveService#autosave_target_for` allows income, household size, eligibility confirmations, medical provider fields, and alternate contact fields. |
| Autosavable user fields | The service accepts the disability fields `hearing_disability`, `vision_disability`, `speech_disability`, `mobility_disability`, and `cognition_disability`. For dependent applications, these update the dependent user. |
| Ignored fields | File uploads, address fields, proof attachment fields, and non-allowlisted attributes return errors and do not update `last_visited_step`. |
| Persistence style | Autosave uses targeted writes for individual draft fields. `last_visited_step` is updated with `update_column`, so validations and callbacks are skipped for that marker update. |
| Admin navigation | The admin dashboard links to System Reports, and the System Reports show page (`app/views/admin/reports/show.html.erb`) links to Pain Point Analysis. |

## Report Output

The "Application Pain Point Analysis" page lists the field attributes where draft applications last saved data before submission stopped.

- The first column shows the humanized field name with the raw attribute in parentheses.
- The second column shows the number of draft applications with that last saved field.
- Higher counts identify fields where more draft applications stopped after a successful autosave.

## Tests

| Test file | Coverage |
|-----------|----------|
| `test/controllers/constituent_portal/applications_controller_autosave_test.rb` | Existing and newly created draft autosave, dependent draft authorization, application/user field marker updates, ignored fields, and application-created audit event when autosave creates a draft. |
| `test/models/application_test.rb` | `Application.draft` and `Application.pain_point_analysis`. |
| `test/controllers/admin/application_analytics_controller_test.rb` | Admin report response and empty-result handling. |

## Related Docs

- [`docs/features/application_workflow_guide.md`](./application_workflow_guide.md)
- [`docs/development/javascript_architecture.md`](../development/javascript_architecture.md)
- [`docs/features/audit_event_tracking.md`](./audit_event_tracking.md)
