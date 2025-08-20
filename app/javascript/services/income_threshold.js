// Shared utility for income threshold calculations

/**
 * Calculate the income threshold for a given household size.
 * @param {Object} params
 * @param {Object.<string|number, number>} params.baseFplBySize - Map of household size (1..8) to base FPL amount
 * @param {number} params.modifierPercent - Policy modifier percentage (e.g., 400 for 400%)
 * @param {number|string} params.householdSize - Household size (capped at 8)
 * @returns {number} Calculated threshold amount
 */
export function calculateThreshold({ baseFplBySize, modifierPercent, householdSize }) {
  const sizeNum = Math.max(0, Math.min(parseInt(householdSize, 10) || 0, 8));

  if (!baseFplBySize || typeof baseFplBySize !== 'object') {
    return 0;
  }

  // Support both numeric and string keys ("1".."8")
  const base = baseFplBySize[sizeNum] || baseFplBySize[String(sizeNum)] || 0;
  const modifier = typeof modifierPercent === 'number' && !Number.isNaN(modifierPercent)
    ? modifierPercent
    : 400; // sensible default

  return base * (modifier / 100);
}

/**
 * Determine if the income exceeds the calculated threshold.
 * @param {Object} params
 * @param {Object.<string|number, number>} params.baseFplBySize
 * @param {number} params.modifierPercent
 * @param {number|string} params.householdSize
 * @param {number|string} params.income
 * @returns {boolean}
 */
export function exceeds({ baseFplBySize, modifierPercent, householdSize, income }) {
  const incomeNum = typeof income === 'number' ? income : parseFloat(income) || 0;
  const threshold = calculateThreshold({ baseFplBySize, modifierPercent, householdSize });
  return incomeNum > threshold;
}


