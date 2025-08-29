import { languages } from "@codemirror/language-data";
import { addMode } from "./modelist";

// 1) Always register a plain text fallback
addMode("Text", "txt|text|log|plain", "Plain Text", () => []);

// 2) Register all languages provided by @codemirror/language-data
//    We convert extensions like [".js", ".mjs"] into a modelist pattern: "js|mjs"
//    and include anchored filename patterns like "^Dockerfile" when present.
for (const lang of languages) {
	try {
		const name = String(lang?.name || "").trim();
		if (!name) continue;

		/** @type {string[]} */
		const parts = [];
		// File extensions
		if (Array.isArray(lang.extensions)) {
			for (const e of lang.extensions) {
				if (typeof e !== "string") continue;
				const cleaned = e.replace(/^\./, "").trim();
				if (cleaned) parts.push(cleaned);
			}
		}
		// Exact filenames (dockerfile, makefile, etc.)
		const filenames = Array.isArray(lang.filenames)
			? lang.filenames
			: lang.filename
				? [lang.filename]
				: [];
		for (const fn of filenames) {
			if (typeof fn !== "string") continue;
			const cleaned = fn.trim();
			if (cleaned) parts.push(`^${cleaned}`);
		}

		// Skip if we have no way to match the language
		if (parts.length === 0) continue;

		const pattern = parts.join("|");

		// Wrap language-data loader as our modelist language provider
		// lang.load() returns a Promise<Extension>; we let the editor handle async loading
		const loader = typeof lang.load === "function" ? () => lang.load() : null;

		addMode(name, pattern, name, loader);
	} catch (_) {
		// Ignore faulty entries to avoid breaking the whole registration
	}
}
