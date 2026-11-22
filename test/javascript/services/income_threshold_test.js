import { calculateThreshold } from "../../../app/javascript/services/income_threshold"

test("uses the supplied table boundary for larger households", () => {
  const rules = { baseFplBySize: { 1: 100, 2: 200, 3: 300 }, modifierPercent: 400, additionalPerson: 75 }

  expect(calculateThreshold({ ...rules, householdSize: 3 })).toBe(1200)
  expect(calculateThreshold({ ...rules, householdSize: 5 })).toBe(1800)
})

test("calculates known sizes in an incomplete table and rejects unknown sizes", () => {
  const rules = { baseFplBySize: { 1: 100, 3: 300 }, modifierPercent: 400, additionalPerson: null }

  expect(calculateThreshold({ ...rules, householdSize: 3 })).toBe(1200)
  expect(calculateThreshold({ ...rules, householdSize: 2 })).toBeNaN()
  expect(calculateThreshold({ ...rules, householdSize: 4 })).toBeNaN()
})
