export const THEME_KEY = "lumawall-theme";
export const CHOICES = ["system", "light", "dark"];

/** A stored value is only trusted when it is one of the three choices. */
export const normalizeChoice = (value) => (CHOICES.includes(value) ? value : "system");

/** The data-theme attribute for a choice: none at all means "follow the system". */
export const attributeFor = (choice) => (choice === "light" || choice === "dark" ? choice : null);
