
/**
 * Calculates the threshold from base FPL and the policy percentage.
 * @param {Object} params
 * @param {Object.<string|number, number>} params.baseFplBySize - Base FPL amounts by household size
 * @param {number} params.modifierPercent - Policy modifier percentage (e.g., 400 for 400%)
 * @param {number} params.additionalPerson - Base FPL increment for each person beyond the table
 * @param {number|string} params.householdSize - Positive whole household size
 * @returns {number} Calculated threshold amount
 */
export function calculateThreshold({ baseFplBySize, modifierPercent, additionalPerson, householdSize }) {
  const size = Number(householdSize);
  const lastSize = Math.max(0, ...Object.keys(baseFplBySize ?? {}).map(Number));
  const additionalPeople = Math.max(size - lastSize, 0);
  const base = Number(baseFplBySize?.[Math.min(size, lastSize)]);
  const extra = additionalPeople > 0 ? Number(additionalPerson) : 0;
  if (!Number.isInteger(size) || size < 1 || !Number.isFinite(base) || base <= 0 ||
      !Number.isFinite(modifierPercent) || modifierPercent <= 0 ||
      !Number.isFinite(extra) || (additionalPeople > 0 && extra <= 0)) return NaN;

  return Math.round((base + additionalPeople * extra) * modifierPercent) / 100;
}


