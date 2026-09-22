export function debounce(fn, wait) {
  let timeout
  function debounced(...args) {
    clearTimeout(timeout)
    timeout = setTimeout(() => {
      timeout = null
      fn.apply(this, args)
    }, wait)
  }
  debounced.cancel = () => {
    clearTimeout(timeout)
    timeout = null
  }
  return debounced
}
