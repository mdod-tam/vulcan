const colors = require('tailwindcss/colors')

// Design tokens. Views use these names, so the palette changes in one place:
//   primary  brand color: links, primary actions, selected state, the focus ring
//   success  completed, approved, available
//   warning  needs attention, waiting on someone
//   danger   failed, rejected, destructive
//   info     in progress, informational
// Status colors never carry meaning alone; every badge and message also states it in words.
module.exports = {
  content: [
    './app/views/**/*.html.erb',
    './app/helpers/**/*.rb',
    './app/presenters/**/*.rb',
    './app/services/notification_composer.rb',
    './app/models/constituent_portal/activity.rb',
    './app/assets/stylesheets/**/*.css',
    './app/javascript/**/*.js'
  ],
  theme: {
    extend: {
      colors: {
        primary: colors.indigo,
        success: colors.green,
        warning: colors.amber,
        danger: colors.red,
        info: colors.blue
      },
      fontFamily: {
        sans: [
          'system-ui', '-apple-system', 'BlinkMacSystemFont', '"Segoe UI"', 'Roboto', '"Helvetica Neue"',
          'Arial', '"Noto Sans"', 'sans-serif'
        ]
      },
      // One elevation scale: 1 resting controls, 2 cards, 3 raised or hovered cards, 4 dialogs and menus.
      boxShadow: {
        'elevation-1': '0 1px 2px 0 rgb(0 0 0 / 0.05)',
        'elevation-2': '0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1)',
        'elevation-3': '0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1)',
        'elevation-4': '0 20px 25px -5px rgb(0 0 0 / 0.1), 0 8px 10px -6px rgb(0 0 0 / 0.1)'
      }
    }
  }
}
