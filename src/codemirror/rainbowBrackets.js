import { RangeSetBuilder } from "@codemirror/state";
import { Decoration, EditorView, ViewPlugin } from "@codemirror/view";

export const defaultRainbowColors = [
	"red",
	"orange",
	"yellow",
	"green",
	"blue",
	"indigo",
	"violet",
];

/**
 * Build a base theme for N colors.
 */
function rainbowTheme(colors) {
	const rules = {};
	// Depth k (1..N) maps to class .cm-rb-dk
	for (let i = 0; i < colors.length; i++) {
		const depth = i + 1;
		rules[`.cm-rb-d${depth}`] = { color: colors[i] };
	}
	return EditorView.baseTheme(rules);
}

function lineBalance(text) {
	let bal = 0;
	for (let i = 0, n = text.length; i < n; i++) {
		const ch = text.charCodeAt(i);
		// Quick switch on a few ASCII codes
		// '(', ')', '[', ']', '{', '}'
		if (ch === 40 || ch === 91 || ch === 123) bal++;
		else if (ch === 41 || ch === 93 || ch === 125) bal--;
	}
	return bal;
}

function computeDepthCache(doc) {
	const lineCount = doc.lines;
	const balances = new Int32Array(lineCount);
	const prefixDepth = new Int32Array(lineCount + 1); // prefixDepth[1] for line 1
	// Iterate once through all lines
	for (let ln = 1; ln <= lineCount; ln++) {
		const t = doc.line(ln).text;
		const bal = lineBalance(t);
		balances[ln - 1] = bal;
		prefixDepth[ln] = prefixDepth[ln - 1] + bal;
	}
	return { balances, prefixDepth, version: doc.length }; // track length as a cheap change marker
}

function firstChangedLine(update) {
	let min = Number.POSITIVE_INFINITY;
	update.changes.iterChanges((fromA, _toA, fromB, _toB) => {
		const ln = update.state.doc.lineAt(fromB).number;
		if (ln < min) min = ln;
	});
	if (min === Number.POSITIVE_INFINITY) return 1;
	return Math.max(1, min);
}

function recomputeDepthCache(prevCache, prevDoc, newDoc, startLine = 1) {
	const lineCount = newDoc.lines;
	const balances = new Int32Array(lineCount);
	const prefixDepth = new Int32Array(lineCount + 1);

	// Copy prefix for unchanged prefix lines
	const copyEnd = Math.max(1, Math.min(startLine - 1, lineCount));
	if (prevCache && prevDoc) {
		for (let ln = 1; ln <= copyEnd; ln++) {
			balances[ln - 1] = prevCache.balances[ln - 1] || 0;
			prefixDepth[ln] = prevCache.prefixDepth[ln] || 0;
		}
	}

	// If nothing to copy, ensure prefixDepth[0] = 0
	if (copyEnd === 0) prefixDepth[0] = 0;

	// Start depth for startLine
	const startDepth = prefixDepth[startLine - 1] || 0;
	prefixDepth[startLine - 1] = startDepth; // make sure defined

	for (let ln = startLine; ln <= lineCount; ln++) {
		const t = newDoc.line(ln).text;
		const bal = lineBalance(t);
		balances[ln - 1] = bal;
		prefixDepth[ln] = prefixDepth[ln - 1] + bal;
	}

	return { balances, prefixDepth, version: newDoc.length };
}

function buildDecorationBank(maxDepth) {
	const arr = new Array(maxDepth);
	for (let i = 0; i < maxDepth; i++) {
		const cls = `cm-rb-d${i + 1}`;
		arr[i] = Decoration.mark({ class: cls });
	}
	return arr;
}

/**
 * The main extension factory.
 * @param {{ colors?: string[], useLight?: boolean }} [options]
 */
export function rainbowBrackets(options = {}) {
	const palette = options.colors || defaultRainbowColors;
	const theme = rainbowTheme(palette);
	const bank = buildDecorationBank(palette.length);

	const vp = ViewPlugin.fromClass(
		class RainbowPlugin {
			constructor(view) {
				this.view = view;
				this.cache = computeDepthCache(view.state.doc);
				this.decorations = this.compute();
			}

			update(update) {
				if (update.docChanged) {
					const startLn = firstChangedLine(update);
					this.cache = recomputeDepthCache(
						this.cache,
						update.startState.doc,
						update.state.doc,
						startLn,
					);
				}
				if (update.docChanged || update.viewportChanged) {
					this.decorations = this.compute();
				}
			}

			compute() {
				const { view } = this;
				const { cache } = this;
				const builder = new RangeSetBuilder();
				const colorCount = palette.length;
				if (!colorCount) return builder.finish();

				const margin = 200;
				for (const { from, to } of view.visibleRanges) {
					const start = Math.max(0, from - margin);
					const end = Math.min(view.state.doc.length, to + margin);

					const startLine = view.state.doc.lineAt(start);
					let depth = cache.prefixDepth[startLine.number - 1];
					let pos = startLine.from;
					while (pos < end) {
						const line = view.state.doc.lineAt(pos);
						const text = line.text;
						const lineStart = line.from;
						const upto = Math.min(line.to, end);
						for (let i = 0, n = upto - lineStart; i < n; i++) {
							const ch = text.charCodeAt(i);
							if (ch === 40 || ch === 91 || ch === 123) {
								const clsIndex =
									((depth % colorCount) + colorCount) % colorCount;
								builder.add(lineStart + i, lineStart + i + 1, bank[clsIndex]);
								depth++;
							} else if (ch === 41 || ch === 93 || ch === 125) {
								depth = Math.max(depth - 1, 0);
								const clsIndex =
									((depth % colorCount) + colorCount) % colorCount;
								builder.add(lineStart + i, lineStart + i + 1, bank[clsIndex]);
							}
						}
						const nextLineNo = line.number + 1;
						if (nextLineNo <= view.state.doc.lines)
							depth = cache.prefixDepth[nextLineNo - 1];
						pos = line.to + 1;
					}
				}
				return builder.finish();
			}
		},
		{
			decorations: (v) => v.decorations,
		},
	);

	return [vp, theme];
}

export default rainbowBrackets;
