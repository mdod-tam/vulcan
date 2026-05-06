import { Controller } from "@hotwired/stimulus"
import { debounce } from "lodash.debounce"

export default class extends Controller {
  static targets = [
    "addressInput",
    "address2Input",
    "cityInput",
    "stateInput",
    "zipInput"
  ]

  static values = {
    countries: { type: Array, default: ["us"] }
  }

  connect() {
    if (!this.hasAddressInputTarget) return

    this.setupAutocomplete()
  }

  setupAutocomplete() {
    // Create a container for suggestions
    this.suggestionsContainer = document.createElement("div")
    this.suggestionsContainer.className = "absolute z-10 w-full mt-1 bg-white border border-gray-300 rounded-md shadow-lg hidden"
    this.suggestionsContainer.style.maxHeight = "300px"
    this.suggestionsContainer.style.overflowY = "auto"

    this.addressInputTarget.parentElement.style.position = "relative"
    this.addressInputTarget.parentElement.appendChild(this.suggestionsContainer)

    // Debounced search to avoid excessive API calls
    this.debouncedSearch = debounce((query) => this.searchAddresses(query), 300)

    this.addressInputTarget.addEventListener("input", (e) => {
      this.debouncedSearch(e.target.value)
    })

    // Close suggestions when clicking outside
    document.addEventListener("click", (e) => {
      if (e.target !== this.addressInputTarget) {
        this.suggestionsContainer.classList.add("hidden")
      }
    })
  }

  async searchAddresses(query) {
    if (query.length < 3) {
      this.suggestionsContainer.classList.add("hidden")
      return
    }

    try {
      // Use Nominatim API (OpenStreetMap) for address search
      // Restrict to US by using countrycodes parameter
      const response = await fetch(
        `https://nominatim.openstreetmap.org/search?` +
        `format=json&` +
        `q=${encodeURIComponent(query)}&` +
        `countrycodes=us&` +
        `addressdetails=1&` +
        `limit=5`,
        {
          headers: {
            "Accept": "application/json"
          }
        }
      )

      if (!response.ok) {
        console.warn("Nominatim API error:", response.status)
        return
      }

      const results = await response.json()
      this.displaySuggestions(results)
    } catch (error) {
      console.error("Address search error:", error)
    }
  }

  displaySuggestions(results) {
    this.suggestionsContainer.innerHTML = ""

    if (results.length === 0) {
      this.suggestionsContainer.classList.add("hidden")
      return
    }

    results.forEach((result) => {
      const suggestion = document.createElement("div")
      suggestion.className = "px-4 py-2 cursor-pointer hover:bg-indigo-50 border-b border-gray-200 last:border-b-0"
      suggestion.textContent = result.display_name

      suggestion.addEventListener("click", () => {
        this.selectAddress(result)
      })

      this.suggestionsContainer.appendChild(suggestion)
    })

    this.suggestionsContainer.classList.remove("hidden")
  }

  selectAddress(result) {
    this.suggestionsContainer.classList.add("hidden")
    this.fillAddressFields(result)
  }

  fillAddressFields(place) {
    const address = place.address || {}

    // Extract address components from Nominatim response
    const streetAddress = address.road || address.house_number || ""
    const city = address.city || address.town || address.village || ""
    const state = this.getStateAbbreviation(address.state || "")
    const zip = address.postcode || ""

    if (this.hasAddressInputTarget && streetAddress) {
      this.addressInputTarget.value = streetAddress
      this.addressInputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }

    if (this.hasAddress2InputTarget) {
      this.address2InputTarget.value = ""
    }

    if (this.hasCityInputTarget && city) {
      this.cityInputTarget.value = city
      this.cityInputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }

    if (this.hasStateInputTarget && state) {
      this.stateInputTarget.value = state
      this.stateInputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }

    if (this.hasZipInputTarget && zip) {
      this.zipInputTarget.value = zip
      this.zipInputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    }
  }

  getStateAbbreviation(stateName) {
    // Map of US state names to abbreviations
    const stateMap = {
      "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR",
      "california": "CA", "colorado": "CO", "connecticut": "CT", "delaware": "DE",
      "florida": "FL", "georgia": "GA", "hawaii": "HI", "idaho": "ID",
      "illinois": "IL", "indiana": "IN", "iowa": "IA", "kansas": "KS",
      "kentucky": "KY", "louisiana": "LA", "maine": "ME", "maryland": "MD",
      "massachusetts": "MA", "michigan": "MI", "minnesota": "MN", "mississippi": "MS",
      "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV",
      "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
      "north carolina": "NC", "north dakota": "ND", "ohio": "OH", "oklahoma": "OK",
      "oregon": "OR", "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC",
      "south dakota": "SD", "tennessee": "TN", "texas": "TX", "utah": "UT",
      "vermont": "VT", "virginia": "VA", "washington": "WA", "west virginia": "WV",
      "wisconsin": "WI", "wyoming": "WY", "district of columbia": "DC"
    }

    const normalized = stateName.toLowerCase().trim()
    return stateMap[normalized] || stateName.toUpperCase()
  }
}
