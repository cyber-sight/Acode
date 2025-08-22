const modesByName = {};
const modes = [];

/**
 * Initialize CodeMirror mode list functionality
 */
export function initModes() {
	// CodeMirror modes don't need the same ace.define wrapper
	// but we maintain the same API structure for compatibility
}

/**
 * Add language mode to CodeMirror editor
 * @param {string} name name of the mode
 * @param {string|Array<string>} extensions extensions of the mode
 * @param {string} [caption] display name of the mode
 * @param {Function} [languageExtension] CodeMirror language extension function
 */
export function addMode(name, extensions, caption, languageExtension = null) {
	const filename = name.toLowerCase();
	const mode = new Mode(filename, caption, extensions, languageExtension);
	modesByName[filename] = mode;
	modes.push(mode);
}

/**
 * Remove language mode from CodeMirror editor
 * @param {string} name
 */
export function removeMode(name) {
	const filename = name.toLowerCase();
	delete modesByName[filename];
	const modeIndex = modes.findIndex((mode) => mode.name === filename);
	if (modeIndex >= 0) {
		modes.splice(modeIndex, 1);
	}
}

/**
 * Get mode for file path
 * @param {string} path
 * @returns {Mode}
 */
export function getModeForPath(path) {
	let mode = modesByName.text;
	let fileName = path.split(/[\/\\]/).pop();

	// Sort modes by specificity (descending) to check most specific first
	const sortedModes = [...modes].sort((a, b) => {
		return getModeSpecificityScore(b) - getModeSpecificityScore(a);
	});

	for (const iMode of sortedModes) {
		if (iMode.supportsFile?.(fileName)) {
			mode = iMode;
			break;
		}
	}
	return mode;
}

/**
 * Calculates a specificity score for a mode.
 * Higher score means more specific.
 * - Anchored patterns (e.g., "^Dockerfile") get a base score of 1000.
 * - Non-anchored patterns (extensions) are scored by length.
 */
function getModeSpecificityScore(modeInstance) {
	const extensionsStr = modeInstance.extensions;
	if (!extensionsStr) return 0;

	const patterns = extensionsStr.split("|");
	let maxScore = 0;

	for (const pattern of patterns) {
		let currentScore = 0;
		if (pattern.startsWith("^")) {
			// Exact filename match or anchored pattern
			currentScore = 1000 + (pattern.length - 1); // Subtract 1 for '^'
		} else {
			// Extension match
			currentScore = pattern.length;
		}
		if (currentScore > maxScore) {
			maxScore = currentScore;
		}
	}
	return maxScore;
}

/**
 * Get all modes by name
 * @returns {Object}
 */
export function getModesByName() {
	return modesByName;
}

/**
 * Get all modes array
 * @returns {Array}
 */
export function getModes() {
	return modes;
}

class Mode {
	extensions;
	displayName;
	name;
	mode;
	extRe;
	languageExtension;

	/**
	 * Create a new mode
	 * @param {string} name
	 * @param {string} caption
	 * @param {string|Array<string>} extensions
	 * @param {Function} languageExtension - CodeMirror language extension function
	 */
	constructor(name, caption, extensions, languageExtension = null) {
		if (Array.isArray(extensions)) {
			extensions = extensions.join("|");
		}

		this.name = name;
		this.mode = name; // CodeMirror uses different mode naming
		this.extensions = extensions;
		this.caption = caption || this.name.replace(/_/g, " ");
		this.languageExtension = languageExtension;
		let re;

		if (/\^/.test(extensions)) {
			re =
				extensions.replace(/\|(\^)?/g, function (a, b) {
					return "$|" + (b ? "^" : "^.*\\.");
				}) + "$";
		} else {
			re = "^.*\\.(" + extensions + ")$";
		}

		this.extRe = new RegExp(re, "i");
	}

	supportsFile(filename) {
		return this.extRe.test(filename);
	}

	/**
	 * Get the CodeMirror language extension
	 * @returns {Function|null} The language extension function or null if not available
	 */
	getExtension() {
		return this.languageExtension;
	}

	/**
	 * Check if the language extension is available (loaded)
	 * @returns {boolean}
	 */
	isAvailable() {
		return this.languageExtension !== null;
	}
}
