# Password Visibility Toggle Component

This document explains how to use the password visibility toggle component in the application.

## Overview

The password visibility toggle component allows users to toggle the visibility of password fields, making it easier to verify their input while maintaining security. The component includes:

- A password input field
- A toggle button with an eye icon
- Accessibility features including screen reader support
- Automatic timeout for security

## Features

- **Toggle Visibility**: Users can click the eye icon to toggle between showing and hiding the password.
- **Accessibility**: The component is fully accessible, with proper ARIA attributes and keyboard navigation.
- **Security**: Passwords automatically revert to hidden after a configurable timeout.
- **Responsive**: The component works well on all device sizes, with appropriate touch target sizes.

## Implementation

The component is implemented using:

1. A Rails form helper (`password_field_with_toggle`)
2. The shared helper data builder (`password_visibility_data`)
3. The Stimulus `visibility` controller (`app/javascript/controllers/ui/visibility_controller.js`)

## Usage

### Basic Usage

To add a password field with visibility toggle to your form, use the `password_field_with_toggle` helper:

```erb
<%= form_with model: @user do |form| %>
  <%= password_field_with_toggle(form, :password) %>
<% end %>
```

### Customization

You can customize the password field by passing options:

```erb
<%= password_field_with_toggle(form, :password, 
    label: "Your Password",
    hint: "Minimum 8 characters",
    timeout: 10000, # 10 seconds
    html_options: {
      minlength: 8,
      placeholder: "Enter your password",
      aria: {
        required: "true",
        invalid: @user.errors[:password].any?,
        errormessage: "password-error"
      }
    }
) %>
```

### Available Options

| Option | Description | Default |
|--------|-------------|---------|
| `label` | The label text for the password field | Field name humanized |
| `placeholder` | Placeholder text | `nil` |
| `required` | Whether the field is required | `true` |
| `autocomplete` | The autocomplete attribute | 'current-password' or 'new-password' for confirmation |
| `timeout` | Time in milliseconds before password is hidden again | 5000 |
| `hint` | Hint text displayed below the input | `nil` |
| `html_options` | Additional HTML options for the input | `{}` |

## Accessibility

The component follows accessibility best practices:

- The toggle button has appropriate ARIA attributes (`aria-label`, `aria-pressed`)
- The password field is linked to the status element with `aria-describedby`
- A screen reader status element announces the current state (hidden/visible)
- The toggle button is keyboard accessible
- The toggle button has sufficient color contrast
- The toggle button has appropriate size for touch targets

## Security Considerations

- The password is automatically hidden after the specified timeout (default: 5 seconds)
- The timeout helps prevent shoulder surfing in public places
- The component does not store the password in any additional variables
- The timeout is cleared when navigating away from the page

## Example

Here's an example of how to use the component in a registration form:

```erb
<%= form_with model: @user, url: sign_up_path do |form| %>
  <%= password_field_with_toggle(form, :password, 
      label: "Password",
      hint: "Minimum 6 characters",
      html_options: {
        minlength: 6,
        aria: {
          required: "true",
          invalid: @user.errors[:password].any?,
          errormessage: "password-error"
        }
      }
  ) %>
  
  <%= password_field_with_toggle(form, :password_confirmation, 
      label: "Confirm Password",
      html_options: {
        minlength: 6,
        aria: {
          required: "true",
          invalid: @user.errors[:password_confirmation].any?,
          errormessage: "password-confirmation-error"
        }
      }
  ) %>
  
  <%= form.submit "Create Account" %>
<% end %>
```

## Troubleshooting

If the password visibility toggle is not working:

1. Make sure the JavaScript is properly loaded
2. Check that the wrapper has the `visibility` Stimulus controller data attributes
3. Verify that the input/button/status elements have the expected Stimulus targets
4. Check the browser console for any JavaScript errors
