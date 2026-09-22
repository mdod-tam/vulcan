// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import * as ActiveStorage from "@rails/activestorage"
// Toast notifications removed in favor of native Rails flash messages

import "./controllers"

ActiveStorage.start()
