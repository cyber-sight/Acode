import "./styles.scss";
import VirtualList from "components/virtualList";
import actionStack from "lib/actionStack";
import { openReferencesTab } from "./referencesTab";
import {
	buildFlatList,
	clearHighlightCache,
	createReferenceItemRenderer,
	getReferencesStats,
	navigateToReference,
	sanitize,
} from "./utils";

let currentPanel = null;

function createReferencesPanel() {
	const state = {
		visible: false,
		expanded: false,
		loading: true,
		symbolName: "",
		references: [],
		collapsedFiles: new Set(),
		flatItems: [],
	};

	let virtualList = null;

	const $mask = tag("span", { className: "references-panel-mask" });
	const $panel = tag("div", { className: "references-panel" });

	const $dragHandle = tag("div", { className: "drag-handle" });
	const $header = createHeader();
	const $content = tag("div", { className: "panel-content" });

	$panel.append($dragHandle, $header.el, $content);

	$mask.onclick = hide;

	let startY = 0;
	let currentY = 0;
	let isDragging = false;

	$dragHandle.ontouchstart = onDragStart;
	$dragHandle.onmousedown = onDragStart;

	function onDragStart(e) {
		isDragging = true;
		startY = e.touches ? e.touches[0].clientY : e.clientY;
		currentY = startY;
		$panel.style.transition = "none";

		document.addEventListener("touchmove", onDragMove, { passive: false });
		document.addEventListener("mousemove", onDragMove);
		document.addEventListener("touchend", onDragEnd);
		document.addEventListener("mouseup", onDragEnd);
	}

	function onDragMove(e) {
		if (!isDragging) return;
		e.preventDefault();
		currentY = e.touches ? e.touches[0].clientY : e.clientY;
		const deltaY = currentY - startY;

		if (deltaY > 0) {
			$panel.style.transform = `translateY(${deltaY}px)`;
		} else if (!state.expanded) {
			const expansion = Math.min(Math.abs(deltaY), 100);
			$panel.style.maxHeight = `${60 + (expansion / 100) * 25}vh`;
		}
	}

	function onDragEnd() {
		isDragging = false;
		document.removeEventListener("touchmove", onDragMove);
		document.removeEventListener("mousemove", onDragMove);
		document.removeEventListener("touchend", onDragEnd);
		document.removeEventListener("mouseup", onDragEnd);

		$panel.style.transition = "";
		const deltaY = currentY - startY;

		if (deltaY > 100) {
			hide();
		} else if (deltaY < -50 && !state.expanded) {
			state.expanded = true;
			$panel.classList.add("expanded");
			$panel.style.transform = "";
			$panel.style.maxHeight = "";
		} else {
			$panel.style.transform = "";
			$panel.style.maxHeight = "";
		}
	}

	function createHeader() {
		const $el = tag("div", { className: "panel-header" });
		const $content = tag("div", { className: "header-content" });
		const $title = tag("div", { className: "header-title" });
		const $subtitle = tag("span", { className: "header-subtitle" });

		const $actions = tag("div", { className: "header-actions" });
		const $openTabBtn = tag("button", {
			className: "action-btn open-tab-btn",
			title: "Open in Tab",
			innerHTML: '<span class="icon fullscreen"></span>',
			onclick: openInTab,
		});
		const $closeBtn = tag("button", {
			className: "action-btn close-btn",
			innerHTML: '<span class="icon clearclose"></span>',
			onclick: hide,
		});

		$actions.append($openTabBtn, $closeBtn);
		$content.append($title, $subtitle);
		$el.append($content, $actions);

		return {
			el: $el,
			setTitle(symbolName) {
				$title.innerHTML = `<span class="icon linkinsert_link"></span><span>References to </span><span class="symbol-name">${sanitize(symbolName)}</span>`;
			},
			setSubtitle(text) {
				$subtitle.textContent = text;
			},
		};
	}

	function openInTab() {
		const refs = state.references;
		const sym = state.symbolName;
		hide();
		openReferencesTab({
			symbolName: sym,
			references: refs,
		});
	}

	function getVisibleItems() {
		return state.flatItems.filter((item) => {
			if (item.type === "file-header") return true;
			return !state.collapsedFiles.has(item.uri);
		});
	}

	function toggleFile(uri) {
		if (state.collapsedFiles.has(uri)) {
			state.collapsedFiles.delete(uri);
		} else {
			state.collapsedFiles.add(uri);
		}
		virtualList?.setItems(getVisibleItems());
	}

	function renderLoading() {
		$content.innerHTML = `
			<div class="loading-state">
				<div class="loader"></div>
				<span>Finding references...</span>
			</div>
		`;
	}

	function renderEmpty() {
		$content.innerHTML = `
			<div class="empty-state">
				<span class="icon search"></span>
				<span>No references found</span>
			</div>
		`;
	}

	async function renderReferences() {
		$content.innerHTML = `
			<div class="loading-state">
				<div class="loader"></div>
				<span>Highlighting code...</span>
			</div>
		`;

		const stats = getReferencesStats(state.references);
		$header.setSubtitle(stats.text);

		state.flatItems = await buildFlatList(state.references, state.symbolName);

		$content.innerHTML = "";

		const renderItem = createReferenceItemRenderer({
			collapsedFiles: state.collapsedFiles,
			onToggleFile: toggleFile,
			onNavigate: (ref) => {
				hide();
				navigateToReference(ref);
			},
		});

		virtualList = new VirtualList($content, {
			itemHeight: 40,
			buffer: 15,
			renderItem,
		});
		virtualList.setItems(getVisibleItems());
	}

	function show(options = {}) {
		if (currentPanel && currentPanel !== panelInstance) {
			currentPanel.hide();
		}
		currentPanel = panelInstance;

		state.symbolName = options.symbolName || "";
		state.references = [];
		state.loading = true;
		state.expanded = false;
		state.collapsedFiles.clear();
		state.flatItems = [];

		if (virtualList) {
			virtualList.destroy();
			virtualList = null;
		}

		clearHighlightCache();

		$header.setTitle(state.symbolName);
		$header.setSubtitle("Searching...");
		renderLoading();

		document.body.append($mask, $panel);

		requestAnimationFrame(() => {
			$mask.classList.add("visible");
			$panel.classList.add("visible");
			$panel.classList.remove("expanded");
		});

		state.visible = true;

		actionStack.push({
			id: "references-panel",
			action: hide,
		});
	}

	function hide() {
		if (!state.visible) return;
		state.visible = false;

		$mask.classList.remove("visible");
		$panel.classList.remove("visible");

		actionStack.remove("references-panel");

		if (virtualList) {
			virtualList.destroy();
			virtualList = null;
		}

		setTimeout(() => {
			$mask.remove();
			$panel.remove();
		}, 250);

		if (currentPanel === panelInstance) {
			currentPanel = null;
		}
	}

	function setReferences(references) {
		state.loading = false;
		state.references = references || [];

		if (state.references.length === 0) {
			$header.setSubtitle("No references found");
			renderEmpty();
		} else {
			renderReferences();
		}
	}

	function setError(message) {
		state.loading = false;
		$header.setSubtitle("Error");
		$content.innerHTML = `
			<div class="empty-state">
				<span class="icon error_outline"></span>
				<span>${sanitize(message)}</span>
			</div>
		`;
	}

	const panelInstance = {
		show,
		hide,
		setReferences,
		setError,
		get visible() {
			return state.visible;
		},
	};

	return panelInstance;
}

let panelSingleton = null;

function getPanel() {
	if (!panelSingleton) {
		panelSingleton = createReferencesPanel();
	}
	return panelSingleton;
}

export function showReferencesPanel(options) {
	const panel = getPanel();
	panel.show(options);
	return panel;
}

export function hideReferencesPanel() {
	const panel = getPanel();
	panel.hide();
}

export { openReferencesTab };

export default {
	show: showReferencesPanel,
	hide: hideReferencesPanel,
	getPanel,
	openReferencesTab,
};
