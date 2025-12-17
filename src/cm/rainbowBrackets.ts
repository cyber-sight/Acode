import type { Text } from "@codemirror/state";
import { RangeSetBuilder } from "@codemirror/state";
import type { DecorationSet, ViewUpdate } from "@codemirror/view";
import { Decoration, EditorView, ViewPlugin } from "@codemirror/view";

export const defaultRainbowColors: string[] = [
	"red",
	"orange",
	"yellow",
	"green",
	"blue",
	"indigo",
	"violet",
];

interface ThemeRules {
	[selector: string]: { color: string };
}

interface DepthCache {
	balances: Int32Array;
	prefixDepth: Int32Array;
	version: number;
}

interface RainbowBracketsOptions {
	colors?: string[];
	useLight?: boolean;
}

interface ViewportRange {
	from: number;
	to: number;
}

/**
 * Build a base theme for N colors.
 */
function rainbowTheme(colors: string[]) {
	const rules: ThemeRules = {};
	// Depth k (1..N) maps to class .cm-rb-dk
	for (let i = 0; i < colors.length; i++) {
		const depth = i + 1;
		rules[`.cm-rb-d${depth}`] = { color: colors[i] };
	}
	return EditorView.baseTheme(rules);
}

function lineBalance(text: string): number {
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

function computeDepthCache(doc: Text): DepthCache {
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

function firstChangedLine(update: ViewUpdate): number {
	let min = Number.POSITIVE_INFINITY;
	update.changes.iterChanges(
		(fromA: number, _toA: number, fromB: number, _toB: number) => {
			const ln = update.state.doc.lineAt(fromB).number;
			if (ln < min) min = ln;
		},
	);
	if (min === Number.POSITIVE_INFINITY) return 1;
	return Math.max(1, min);
}

function recomputeDepthCache(
	prevCache: DepthCache | null,
	prevDoc: Text | null,
	newDoc: Text,
	startLine = 1,
): DepthCache {
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

function buildDecorationBank(maxDepth: number): Decoration[] {
	const arr: Decoration[] = new Array(maxDepth);
	for (let i = 0; i < maxDepth; i++) {
		const cls = `cm-rb-d${i + 1}`;
		arr[i] = Decoration.mark({ class: cls });
	}
	return arr;
}

/**
 * The main extension factory.
 */
export function rainbowBrackets(options: RainbowBracketsOptions = {}) {
	const palette = options.colors || defaultRainbowColors;
	const theme = rainbowTheme(palette);
	const bank = buildDecorationBank(palette.length);

	class RainbowPlugin {
		view: EditorView;
		cache: DepthCache;
		decorations: DecorationSet;

		constructor(view: EditorView) {
			this.view = view;
			this.cache = computeDepthCache(view.state.doc);
			this.decorations = this.compute();
		}

		update(update: ViewUpdate): void {
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

		compute(): DecorationSet {
			const { view } = this;
			const { cache } = this;
			const builder = new RangeSetBuilder<Decoration>();
			const colorCount = palette.length;
			if (!colorCount) return builder.finish();

			const margin = 200;
			const windows: ViewportRange[] = [];
			for (const { from, to } of view.visibleRanges) {
				const start = Math.max(0, from - margin);
				const end = Math.min(view.state.doc.length, to + margin);
				if (start < end) windows.push({ from: start, to: end });
			}
			windows.sort((a, b) => a.from - b.from || a.to - b.to);
			const merged: ViewportRange[] = [];
			for (const w of windows) {
				if (!merged.length || w.from > merged[merged.length - 1].to) {
					merged.push({ ...w });
				} else {
					merged[merged.length - 1].to = Math.max(
						merged[merged.length - 1].to,
						w.to,
					);
				}
			}

			for (const { from: winStart, to: winEnd } of merged) {
				// Start scanning exactly at window start to keep builder.add calls sorted
				const startLine = view.state.doc.lineAt(winStart);
				let depth = cache.prefixDepth[startLine.number - 1];
				// Adjust depth if starting mid-line
				const startOffset = winStart - startLine.from;
				if (startOffset > 0) {
					depth += lineBalance(startLine.text.slice(0, startOffset));
				}

				let pos = winStart;
				while (pos < winEnd) {
					const line = view.state.doc.lineAt(pos);
					const text = line.text;
					const lineStart = line.from;
					const upto = Math.min(line.to, winEnd);
					const iStart = Math.max(0, pos - lineStart);
					for (let i = iStart, n = upto - lineStart; i < n; i++) {
						const ch = text.charCodeAt(i);
						if (ch === 40 || ch === 91 || ch === 123) {
							const clsIndex = ((depth % colorCount) + colorCount) % colorCount;
							builder.add(lineStart + i, lineStart + i + 1, bank[clsIndex]);
							depth++;
						} else if (ch === 41 || ch === 93 || ch === 125) {
							depth = Math.max(depth - 1, 0);
							const clsIndex = ((depth % colorCount) + colorCount) % colorCount;
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
	}

	const vp = ViewPlugin.fromClass(RainbowPlugin, {
		decorations: (v) => v.decorations,
	});

	return [vp, theme];
}

export default rainbowBrackets;
