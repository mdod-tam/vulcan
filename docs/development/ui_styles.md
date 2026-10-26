# UI styles

Views are styled with Tailwind utilities, a small set of design tokens, and one component layer. The tokens live in [tailwind.config.js](../../tailwind.config.js); the component and base layers live in [application.tailwind.css](../../app/assets/stylesheets/application.tailwind.css). `yarn build:css` produces the stylesheet the layout links.

## Tokens

| Token | Meaning |
| --- | --- |
| `primary` | The brand color: primary actions, links, selected state, and the focus indicator. |
| `success`, `warning`, `danger`, `info` | Outcome colors for done or approved, waiting, failed or destructive, and in progress. |
| `shadow-elevation-1` to `-4` | One shadow scale: resting controls, cards, raised cards, dialogs and menus. |

Each color uses Tailwind's full scale (`bg-primary-600`, `text-danger-700`). A color never carries a status alone; badges and messages also say it in words.

## Components

- **Buttons:** `btn` plus one of `btn-primary`, `btn-secondary` (tinted), `btn-outline`, `btn-success`, `btn-danger`, `btn-danger-outline`; add `btn-sm` for a compact size. Layout utilities such as `w-full` stay on the element.
- **Badges:** `badge` plus `badge-neutral`, `-primary`, `-success`, `-info`, `-warning`, `-attention`, `-danger`, or `-accent`; add `badge-lg` for page-level status. [BadgeHelper](../../app/helpers/badge_helper.rb) maps each status family to a variant and renders them (`status_badge`, `badge`, `badge_class_for`).
- **Flash messages:** `flash-message` plus `flash-success`, `flash-error`, `flash-warning`, or `flash-info`; `notice` and `alert` share the success and error looks. [shared/_flash](../../app/views/shared/_flash.html.erb) renders them.
- **Surfaces and forms:** `card`, `form-label`, `form-input`, `form-hint`, and `skip-link`.

## Focus and motion

One `:focus-visible` rule in the base layer draws the focus indicator in the primary color: an outline on links, buttons and other controls, a border and ring on text fields. Views do not add `focus:ring` or `focus:outline-none`. Under `prefers-reduced-motion: reduce`, transitions, animations and smooth scrolling are shortened to nothing.

## Adding to the system

Prefer an existing component or token. When a pattern repeats across views, add a class to the component layer rather than repeating the utility string, and extend `tailwind.config.js` only for a value that has a name in the design. Email and PDF layouts use their own inline styles and are not part of this system.
