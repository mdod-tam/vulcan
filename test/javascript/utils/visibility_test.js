import { setVisible, legacyToggleHidden, show, hide, toggle, _resetLegacyWarnings } from 'utils/visibility'

describe('Visibility Utility', () => {
  let element
  let consoleWarnSpy

  beforeEach(() => {
    element = document.createElement('div')
    element.classList.add('test-element')
    document.body.appendChild(element)
    
    consoleWarnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {})
    
    _resetLegacyWarnings()
  })

  afterEach(() => {
    if (element.parentNode) {
      element.parentNode.removeChild(element)
    }
    
    consoleWarnSpy.mockRestore()
  })

  describe('setVisible', () => {
    test('shows element when visible is true', () => {
      element.classList.add('hidden')
      
      setVisible(element, true)
      
      expect(element).not.toHaveClass('hidden')
    })

    test('hides element when visible is false', () => {
      setVisible(element, false)
      
      expect(element).toHaveClass('hidden')
    })

    test('uses custom hidden class', () => {
      setVisible(element, false, { hiddenClass: 'invisible' })
      
      expect(element).toHaveClass('invisible')
      expect(element).not.toHaveClass('hidden')
    })

    test('sets required attribute when visible and required is true', () => {
      setVisible(element, true, { required: true })
      
      expect(element).not.toHaveClass('hidden')
      expect(element.hasAttribute('required')).toBe(true)
      expect(element.getAttribute('required')).toBe('required')
    })

    test('removes required attribute when not visible', () => {
      element.setAttribute('required', 'required')
      
      setVisible(element, false, { required: true })
      
      expect(element).toHaveClass('hidden')
      expect(element.hasAttribute('required')).toBe(false)
    })

    test('removes required attribute when visible but required is false', () => {
      element.setAttribute('required', 'required')
      
      setVisible(element, true, { required: false })
      
      expect(element).not.toHaveClass('hidden')
      expect(element.hasAttribute('required')).toBe(false)
    })

    test('does not affect required attribute when required option is undefined', () => {
      element.setAttribute('required', 'required')
      
      setVisible(element, true)
      
      expect(element).not.toHaveClass('hidden')
      expect(element.hasAttribute('required')).toBe(true)
    })

    test('handles null element gracefully', () => {
      expect(() => {
        setVisible(null, true)
      }).not.toThrow()
      
      expect(consoleWarnSpy).toHaveBeenCalledWith('setVisible: element is null/undefined')
    })

    test('handles undefined element gracefully', () => {
      expect(() => {
        setVisible(undefined, false)
      }).not.toThrow()
      
      expect(consoleWarnSpy).toHaveBeenCalledWith('setVisible: element is null/undefined')
    })

    test('works with various element types', () => {
      const input = document.createElement('input')
      const div = document.createElement('div')
      const select = document.createElement('select')
      
      document.body.appendChild(input)
      document.body.appendChild(div)
      document.body.appendChild(select)
      
      setVisible(input, false, { required: true })
      setVisible(div, false)
      setVisible(select, true, { required: true })
      
      expect(input).toHaveClass('hidden')
      expect(input.hasAttribute('required')).toBe(false)
      expect(div).toHaveClass('hidden')
      expect(select).not.toHaveClass('hidden')
      expect(select.hasAttribute('required')).toBe(true)
      
      document.body.removeChild(input)
      document.body.removeChild(div)
      document.body.removeChild(select)
    })
  })

  describe('legacyToggleHidden', () => {
    test('shows element when shouldHide is false', () => {
      element.classList.add('hidden')
      
      legacyToggleHidden(element, false)
      
      expect(element).not.toHaveClass('hidden')
    })

    test('hides element when shouldHide is true', () => {
      legacyToggleHidden(element, true)
      
      expect(element).toHaveClass('hidden')
    })

    test('shows deprecation warning', () => {
      legacyToggleHidden(element, false)
      
      expect(consoleWarnSpy).toHaveBeenCalledWith(
        expect.stringContaining('legacyToggleHidden is deprecated. Use setVisible() instead.'),
        expect.any(String)
      )
    })

    test('shows one deprecation warning across repeated calls', () => {
      legacyToggleHidden(element, false)
      legacyToggleHidden(element, true)
      
      expect(consoleWarnSpy).toHaveBeenCalledTimes(1)
    })

    test('passes options correctly', () => {
      legacyToggleHidden(element, true, { required: true })
      
      expect(element).toHaveClass('hidden')
      expect(element.hasAttribute('required')).toBe(false)
    })
  })

  describe('show', () => {
    test('shows element', () => {
      element.classList.add('hidden')
      
      show(element)
      
      expect(element).not.toHaveClass('hidden')
    })

    test('sets required attribute when requested', () => {
      show(element, { required: true })
      
      expect(element).not.toHaveClass('hidden')
      expect(element.hasAttribute('required')).toBe(true)
    })

    test('uses custom hidden class', () => {
      element.classList.add('invisible')
      
      show(element, { hiddenClass: 'invisible' })
      
      expect(element).not.toHaveClass('invisible')
    })
  })

  describe('hide', () => {
    test('hides element', () => {
      hide(element)
      
      expect(element).toHaveClass('hidden')
    })

    test('removes required attribute when requested', () => {
      element.setAttribute('required', 'required')
      
      hide(element, { required: false })
      
      expect(element).toHaveClass('hidden')
      expect(element.hasAttribute('required')).toBe(false)
    })

    test('uses custom hidden class', () => {
      hide(element, { hiddenClass: 'invisible' })
      
      expect(element).toHaveClass('invisible')
      expect(element).not.toHaveClass('hidden')
    })
  })

  describe('toggle', () => {
    test('shows hidden element', () => {
      element.classList.add('hidden')
      
      toggle(element)
      
      expect(element).not.toHaveClass('hidden')
    })

    test('hides visible element', () => {
      toggle(element)
      
      expect(element).toHaveClass('hidden')
    })

    test('uses custom hidden class', () => {
      element.classList.add('invisible')
      
      toggle(element, { hiddenClass: 'invisible' })
      
      expect(element).not.toHaveClass('invisible')
    })

    test('handles required attribute', () => {
      element.classList.add('hidden')
      
      toggle(element, { required: true })
      
      expect(element).not.toHaveClass('hidden')
      expect(element.hasAttribute('required')).toBe(true)
    })

    test('handles null element gracefully', () => {
      expect(() => {
        toggle(null)
      }).not.toThrow()
      
      expect(consoleWarnSpy).toHaveBeenCalledWith('toggle: element is null/undefined')
    })
  })

  describe('real-world scenarios', () => {
    test('handles form field show/hide with required', () => {
      const form = document.createElement('form')
      const input = document.createElement('input')
      input.type = 'text'
      input.name = 'test'
      form.appendChild(input)
      document.body.appendChild(form)
      
      setVisible(input, false, { required: false })
      expect(input).toHaveClass('hidden')
      expect(input.hasAttribute('required')).toBe(false)
      
      setVisible(input, true, { required: true })
      expect(input).not.toHaveClass('hidden')
      expect(input.hasAttribute('required')).toBe(true)
      
      setVisible(input, false, { required: false })
      expect(input).toHaveClass('hidden')
      expect(input.hasAttribute('required')).toBe(false)
      
      document.body.removeChild(form)
    })

    test('handles multiple elements with different states', () => {
      const elements = [
        document.createElement('div'),
        document.createElement('input'),
        document.createElement('select')
      ]
      
      elements.forEach(el => {
        el.classList.add('form-field')
        document.body.appendChild(el)
      })
      
      elements.forEach(el => setVisible(el, false))
      elements.forEach(el => expect(el).toHaveClass('hidden'))
      
      setVisible(elements[0], true)
      setVisible(elements[1], true, { required: true })
      setVisible(elements[2], false, { required: false })
      
      expect(elements[0]).not.toHaveClass('hidden')
      expect(elements[0].hasAttribute('required')).toBe(false)
      
      expect(elements[1]).not.toHaveClass('hidden')
      expect(elements[1].hasAttribute('required')).toBe(true)
      
      expect(elements[2]).toHaveClass('hidden')
      expect(elements[2].hasAttribute('required')).toBe(false)
      
      elements.forEach(el => document.body.removeChild(el))
    })

    test('handles checkbox toggle scenarios', () => {
      const checkbox = document.createElement('input')
      checkbox.type = 'checkbox'
      const dependentField = document.createElement('input')
      dependentField.type = 'text'
      
      document.body.appendChild(checkbox)
      document.body.appendChild(dependentField)
      
      const handleCheckboxChange = () => {
        const isChecked = checkbox.checked
        setVisible(dependentField, !isChecked, { required: !isChecked })
      }
      
      checkbox.checked = false
      handleCheckboxChange()
      
      expect(dependentField).not.toHaveClass('hidden')
      expect(dependentField.hasAttribute('required')).toBe(true)
      
      checkbox.checked = true
      handleCheckboxChange()
      
      expect(dependentField).toHaveClass('hidden')
      expect(dependentField.hasAttribute('required')).toBe(false)
      
      document.body.removeChild(checkbox)
      document.body.removeChild(dependentField)
    })

    test('handles radio button dependent field scenarios', () => {
      const radio1 = document.createElement('input')
      const radio2 = document.createElement('input')
      const section1 = document.createElement('div')
      const section2 = document.createElement('div')
      
      radio1.type = 'radio'
      radio1.name = 'test'
      radio1.value = 'option1'
      
      radio2.type = 'radio'
      radio2.name = 'test'
      radio2.value = 'option2'
      
      document.body.appendChild(radio1)
      document.body.appendChild(radio2)
      document.body.appendChild(section1)
      document.body.appendChild(section2)
      
      radio1.checked = true
      radio2.checked = false
      
      setVisible(section1, radio1.checked)
      setVisible(section2, radio2.checked)
      
      expect(section1).not.toHaveClass('hidden')
      expect(section2).toHaveClass('hidden')
      
      radio1.checked = false
      radio2.checked = true
      
      setVisible(section1, radio1.checked)
      setVisible(section2, radio2.checked)
      
      expect(section1).toHaveClass('hidden')
      expect(section2).not.toHaveClass('hidden')
      
      const toRemove = [radio1, radio2, section1, section2]
      toRemove.forEach(el => {
        if (el && el.parentNode === document.body) {
          document.body.removeChild(el)
        }
      })
    })
  })

  describe('edge cases', () => {
    test('handles element with multiple CSS classes', () => {
      element.classList.add('form-field', 'mb-4', 'hidden', 'text-gray-700')
      
      setVisible(element, true)
      
      expect(element).toHaveClass('form-field')
      expect(element).toHaveClass('mb-4')
      expect(element).toHaveClass('text-gray-700')
      expect(element).not.toHaveClass('hidden')
    })

    test('handles rapid successive calls', () => {
      setVisible(element, true)
      setVisible(element, false)
      setVisible(element, true)
      setVisible(element, false)
      
      expect(element).toHaveClass('hidden')
    })

    test('handles required attribute with different values', () => {
      element.setAttribute('required', '')
      setVisible(element, true, { required: false })
      expect(element.hasAttribute('required')).toBe(false)
      
      element.setAttribute('required', 'required')
      setVisible(element, true, { required: false })
      expect(element.hasAttribute('required')).toBe(false)
      
      element.setAttribute('required', 'true')
      setVisible(element, true, { required: false })
      expect(element.hasAttribute('required')).toBe(false)
    })

    test('handles elements already in correct state', () => {
      setVisible(element, true)
      expect(element).not.toHaveClass('hidden')
      
      element.classList.add('hidden')
      setVisible(element, false)
      expect(element).toHaveClass('hidden')
    })
  })
})
