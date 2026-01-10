import VirtualList from "components/virtualList";
import EditorFile from "lib/editorFile";
import {
	buildFlatList,
	clearHighlightCache,
	createReferenceItemRenderer,
	getReferencesStats,
	navigateToReference,
	sanitize,
} from "./utils";

export function createReferencesTab(options = {}) {
	const {
		symbolName = "",
		references = [],
		flatItems: prebuiltItems = null,
	} = options;
	const collapsedFiles = new Set();
	let flatItems = prebuiltItems || [];
	let virtualList = null;
	let isInitialized = false;

	const $container = tag("div", {
		className: "references-tab-container",
	});

	const stats = getReferencesStats(references);

	const $header = tag("div", { className: "references-tab-header" });
	$header.innerHTML = `
		<div class="header-info">
			<span class="icon linkinsert_link"></span>
			<span class="header-title">References to <code>${sanitize(symbolName)}</code></span>
			<span class="header-stats">${stats.text}</span>
		</div>
	`;

	const $listContainer = tag("div", { className: "references-list-container" });
	const $loadingState = tag("div", { className: "loading-state" });
	$loadingState.innerHTML = `
		<div class="loader"></div>
		<span>Highlighting code...</span>
	`;

	$container.append($header, $listContainer);

	function getVisibleItems() {
		return flatItems.filter((item) => {
			if (item.type === "file-header") return true;
			return !collapsedFiles.has(item.uri);
		});
	}

	function toggleFile(uri) {
		if (collapsedFiles.has(uri)) {
			collapsedFiles.delete(uri);
		} else {
			collapsedFiles.add(uri);
		}
		virtualList?.setItems(getVisibleItems());
	}

	const renderItem = createReferenceItemRenderer({
		collapsedFiles,
		onToggleFile: toggleFile,
		onNavigate: navigateToReference,
	});

	async function init() {
		if (isInitialized) return;
		isInitialized = true;

		if (!prebuiltItems || prebuiltItems.length === 0) {
			$listContainer.appendChild($loadingState);
			flatItems = await buildFlatList(references, symbolName);
			$loadingState.remove();
		}

		virtualList = new VirtualList($listContainer, {
			itemHeight: 40,
			buffer: 20,
			renderItem,
		});
		virtualList.setItems(getVisibleItems());
	}

	function destroy() {
		if (virtualList) {
			virtualList.destroy();
			virtualList = null;
		}
	}

	return {
		container: $container,
		init,
		destroy,
		get symbolName() {
			return symbolName;
		},
		get referenceCount() {
			return references.length;
		},
	};
}

export async function openReferencesTab(options = {}) {
	const { symbolName = "", references = [] } = options;

	const tabName = `Refs: ${symbolName}`;
	const existingFile = editorManager.getFile(tabName, "filename");
	if (existingFile) {
		existingFile.makeActive();
		return existingFile;
	}

	clearHighlightCache();
	const flatItems = await buildFlatList(references, symbolName);
	const stats = getReferencesStats(references);

	const tabView = createReferencesTab({ symbolName, references, flatItems });

	const file = new EditorFile(tabName, {
		type: "terminal", // just to avoid shadowdom
		content: tabView.container,
		tabIcon: "icon linkinsert_link",
		render: true,
	});

	file.setCustomTitle(() => stats.text);
	tabView.init();

	file.on("close", () => {
		tabView.destroy();
	});

	return file;
}

export default {
	createReferencesTab,
	openReferencesTab,
};
