import { EditorView } from "@codemirror/view";
import Sidebar from "components/sidebar";
import openFile from "lib/openFile";
import {
	clearHighlightCache,
	highlightLine,
	sanitize,
} from "utils/codeHighlight";
import helpers from "utils/helpers";

export { sanitize, clearHighlightCache };

export function getFilename(uri) {
	if (!uri) return "";
	try {
		const decoded = decodeURIComponent(uri);
		const parts = decoded.split("/").filter(Boolean);
		return parts.pop() || "";
	} catch {
		const parts = uri.split("/").filter(Boolean);
		return parts.pop() || "";
	}
}

export function escapeRegExp(string) {
	return string.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function groupReferencesByFile(references) {
	const grouped = {};
	for (const ref of references) {
		if (!grouped[ref.uri]) {
			grouped[ref.uri] = [];
		}
		grouped[ref.uri].push(ref);
	}
	return grouped;
}

export async function buildFlatList(references, symbolName) {
	const grouped = groupReferencesByFile(references);

	const items = [];
	for (const [uri, fileRefs] of Object.entries(grouped)) {
		fileRefs.sort((a, b) => a.range.start.line - b.range.start.line);

		items.push({
			type: "file-header",
			uri,
			fileName: getFilename(uri),
			count: fileRefs.length,
		});

		for (const ref of fileRefs) {
			const highlightedText = await highlightLine(
				ref.lineText || "",
				uri,
				symbolName,
			);

			items.push({
				type: "reference",
				uri,
				ref,
				line: ref.range.start.line + 1,
				lineText: ref.lineText || "",
				highlightedText,
				symbol: symbolName,
			});
		}
	}
	return items;
}

export function createReferenceItemRenderer(options = {}) {
	const { collapsedFiles, onToggleFile, onNavigate } = options;

	return function renderItem(item, recycledEl) {
		const $el = recycledEl || tag("div");
		$el.className = "";
		$el.onclick = null;
		$el.innerHTML = "";

		if (item.type === "file-header") {
			const isCollapsed = collapsedFiles?.has(item.uri);
			$el.className = `ref-file-header ${isCollapsed ? "collapsed" : ""}`;
			const iconClass = helpers.getIconForFile(item.fileName);

			$el.innerHTML = `
				<span class="icon chevron keyboard_arrow_down"></span>
				<span class="${iconClass} file-icon"></span>
				<span class="file-name">${sanitize(item.fileName)}</span>
				<span class="ref-count">${item.count}</span>
			`;

			$el.onclick = () => onToggleFile?.(item.uri);
		} else {
			$el.className = "ref-item";

			$el.innerHTML = `
				<span class="line-number">${item.line}</span>
				<span class="ref-preview">${item.highlightedText}</span>
			`;

			$el.onclick = () => onNavigate?.(item.ref);
		}

		return $el;
	};
}

export async function navigateToReference(ref) {
	Sidebar.hide();

	try {
		await openFile(ref.uri, { render: true });
		const { editor } = editorManager;
		if (!editor) return;

		const doc = editor.state.doc;
		const startLine = doc.line(ref.range.start.line + 1);
		const endLine = doc.line(ref.range.end.line + 1);
		const from = Math.min(
			startLine.from + ref.range.start.character,
			startLine.to,
		);
		const to = Math.min(endLine.from + ref.range.end.character, endLine.to);

		editor.dispatch({
			selection: { anchor: from, head: to },
			effects: EditorView.scrollIntoView(from, { y: "center" }),
		});
		editor.focus();
	} catch (error) {
		console.error("Failed to navigate to reference:", error);
	}
}

export function getReferencesStats(references) {
	const fileCount = new Set(references.map((r) => r.uri)).size;
	const refCount = references.length;
	return {
		fileCount,
		refCount,
		text: `${refCount} reference${refCount !== 1 ? "s" : ""} in ${fileCount} file${fileCount !== 1 ? "s" : ""}`,
	};
}
