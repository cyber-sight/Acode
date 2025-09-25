import { foldEffect, foldedRanges } from "@codemirror/language";
import { EditorSelection, EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
/**
 * Interface for fold span objects
 * @typedef {Object} FoldSpan
 * @property {number} fromLine - Starting line number (1-based)
 * @property {number} fromCol - Starting column (0-based)
 * @property {number} toLine - Ending line number (1-based)
 * @property {number} toCol - Ending column (0-based)
 */

/**
 * Get all folded ranges from CodeMirror editor state
 * @param {EditorState} state - CodeMirror editor state
 * @returns {FoldSpan[]} Array of fold span objects
 */
export function getAllFolds(state) {
	const doc = state.doc;
	const folds = [];

	foldedRanges(state).between(0, doc.length, (from, to) => {
		const fromPos = doc.lineAt(from);
		const toPos = doc.lineAt(to);
		folds.push({
			fromLine: fromPos.number,
			fromCol: from - fromPos.from,
			toLine: toPos.number,
			toCol: to - toPos.from,
		});
	});

	return folds;
}

/**
 * @param {EditorView} view - CodeMirror editor state
 */
export function getSelection(view) {
	const sel = view.state.selection;
	return {
		ranges: sel.ranges.map((r) => ({ from: r.from, to: r.to })),
		mainIndex: sel.mainIndex,
	};
}

/**
 * Get scroll
 * @param {EditorView} view - CodeMirror editor view
 */
export function getScrollPosition(view) {
	const { scrollTop, scrollLeft } = view.scrollDOM;
	return { scrollTop, scrollLeft };
}

/**
 * Set scroll position in CodeMirror editor view
 * @param {EditorView} view - CodeMirror editor view
 * @param {number} scrollTop - Vertical scroll position
 * @param {number} scrollLeft - Horizontal scroll position
 */
export function setScrollPosition(view, scrollTop, scrollLeft) {
	const scroller = view.scrollDOM;

	if (typeof scrollTop === "number") {
		scroller.scrollTop = scrollTop;
	}

	if (typeof scrollLeft === "number") {
		scroller.scrollLeft = scrollLeft;
	}
}

export function restoreSelection(view, sel) {
	if (!sel || !sel.ranges || !sel.ranges.length) return;
	const len = view.state.doc.length;

	const ranges = sel.ranges
		.map((r) => {
			const from = Math.max(0, Math.min(len, r.from | 0));
			const to = Math.max(0, Math.min(len, r.to | 0));
			return EditorSelection.range(from, to);
		})
		.filter(Boolean);

	if (!ranges.length) return;

	const mainIndex =
		sel.mainIndex >= 0 && sel.mainIndex < ranges.length ? sel.mainIndex : 0;

	view.dispatch({
		selection: EditorSelection.create(ranges, mainIndex),
		scrollIntoView: true,
	});
}

/**
 * Restore folds to CodeMirror editor
 * @param {EditorView} view - CodeMirror editor view
 * @param {FoldSpan[]} folds - Array of fold spans to restore
 */
export function restoreFolds(view, folds) {
	if (!Array.isArray(folds) || folds.length === 0) return;

	function lineColToOffset(doc, line, col) {
		const ln = doc.line(line);
		return Math.min(ln.from + col, ln.to);
	}

	function loadFolds(state, saved) {
		const doc = state.doc;
		const effects = [];

		for (const f of saved) {
			// Validate line numbers
			if (f.fromLine < 1 || f.fromLine > doc.lines) continue;
			if (f.toLine < 1 || f.toLine > doc.lines) continue;

			const from = lineColToOffset(doc, f.fromLine, f.fromCol);
			const to = lineColToOffset(doc, f.toLine, f.toCol);
			if (to > from) {
				effects.push(foldEffect.of({ from, to }));
			}
		}
		return effects;
	}

	const restoreEffects = loadFolds(view.state, folds);
	if (restoreEffects.length) {
		view.dispatch({ effects: restoreEffects });
	}
}

export function clearSelection(view) {
	view.dispatch({
		selection: EditorSelection.single(view.state.selection.main.head), // keep cursor where the main selection head is
		scrollIntoView: true,
	});
	// Also clear the global DOM selection to prevent native selection handles/menus persisting across tab switches
	try {
		document.getSelection()?.removeAllRanges();
	} catch (_) {}
}

export default {
	getAllFolds,
	getSelection,
	getScrollPosition,
	setScrollPosition,
	restoreSelection,
	restoreFolds,
	clearSelection,
};
