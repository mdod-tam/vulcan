// All upload submit guards use the same active-field rule and the widget's localized explanation.
export function documentUploadBlocker(root, isVisible = element => !!(element.offsetParent || element.getClientRects().length)) {
  const widgets = Array.from(root.querySelectorAll("[data-scan-state]"))
  if (root.matches("[data-scan-state]")) widgets.unshift(root)
  for (const widget of widgets) {
    const input = widget.querySelector('input[type="file"]')
    if (!input || input.disabled || input.closest("[hidden], .hidden") || !isVisible(input)) continue
    if (!["idle", "clean"].includes(widget.dataset.scanState)) return input
  }
  return null
}
