import settingsPage from "components/settingsPage";
import toast from "components/toast";
import confirm from "dialogs/confirm";
import loader from "dialogs/loader";
import prompt from "dialogs/prompt";
import select from "dialogs/select";
import rootfsManager from "lib/rootfsManager";
import FileBrowser from "pages/fileBrowser";

export default function rootfsSettings() {
	let page;

	async function refreshPublicHome() {
		const path = await rootfsManager.getActivePublicHome();
		localStorage.ishActivePublicHome = path.startsWith("file://") ? path : `file://${path}`;
	}

	function createPage(roots = [], error = "") {
		const items = [
			{
				key: "import-archive",
				text: "Import Rootfs Archive",
				info: "Import a .tar.gz, .tar.xz, or .zip root filesystem.",
				chevron: true,
			},
			{
				key: "import-folder",
				text: "Import Rootfs Folder",
				info: "Import a local folder containing bin/sh.",
				chevron: true,
			},
			...(error
				? [{ key: "load-error", text: "Root Filesystems Unavailable", info: error }]
				: roots.map((root) => ({
				key: `root:${root.id}`,
				text: root.name,
				value: root.isActive ? "Next launch" : "",
				info: root.isDefault
					? "Bundled root filesystem"
					: root.importedAt || "Imported root filesystem",
				chevron: true,
			}))),
		];
		return settingsPage("Root Filesystems", items, callback, undefined, {
			preserveOrder: true,
			pageClassName: "detail-settings-page",
			listClassName: "detail-settings-list",
			infoAsDescription: true,
			valueInTail: true,
		});
	}

	async function refresh() {
		page?.hide();
		try {
			await refreshPublicHome();
			page = createPage(await rootfsManager.list());
		} catch (error) {
			page = createPage([], error?.message || "The iOS RootfsManager service is unavailable.");
		}
		page.show();
	}

	async function importRoot(directory) {
		try {
			const selected = await FileBrowser(
				directory ? "folder" : "file",
				directory
					? "Select a local root filesystem folder"
					: "Select a root filesystem archive (.tar.gz, .tar.xz, or .zip)",
				false,
			);
			const suggestedName = directory
				? selected.name
				: selected.name.replace(/(\.tar\.gz|\.tgz|\.tar\.xz|\.txz|\.zip)$/i, "");
			const name = await prompt("Root Filesystem Name", suggestedName, "text", {
				required: true,
			});
			if (!name) return;
			loader.showTitleLoader();
			if (directory) await rootfsManager.importDirectory(selected.url, name);
			else await rootfsManager.importArchive(selected.url, name);
			toast("Root filesystem imported");
			await refresh();
		} catch (error) {
			if (error?.message !== "User cancelled") toast(error?.message || String(error));
		} finally {
			loader.removeTitleLoader();
		}
	}

	async function manageRoot(rootId) {
		const roots = await rootfsManager.list();
		const root = roots.find((item) => item.id === rootId);
		if (!root) return;
		const options = [["activate", "Use On Next Launch"]];
		if (!root.isDefault && !root.isActive) {
			options.push(["rename", "Rename"], ["delete", "Delete"]);
		}
		const action = await select(root.name, options);
		if (!action) return;
		if (action === "activate") {
			const result = await rootfsManager.activate(root.id);
			await refreshPublicHome();
			if (result.restartRequired) toast("Root selected. Close and relaunch Acode to use it.");
			await refresh();
			return;
		}
		if (action === "rename") {
			const name = await prompt("Root Filesystem Name", root.name, "text", { required: true });
			if (name) await rootfsManager.rename(root.id, name);
			await refresh();
			return;
		}
		if (action === "delete") {
			const accepted = await confirm("Delete Root Filesystem", `Delete ${root.name}? This cannot be undone.`);
			if (accepted) {
				await rootfsManager.delete(root.id);
				await refresh();
			}
		}
	}

	async function callback(key) {
		if (key === "import-archive") return importRoot(false);
		if (key === "import-folder") return importRoot(true);
		if (key.startsWith("root:")) return manageRoot(key.slice(5));
	}

	return {
		show: async (...args) => {
			// Show a page synchronously so native-service failures never look like
			// a tap that did nothing.
			page = createPage([{ id: "loading", name: "Loading…", isDefault: true }]);
			page.show(...args);
			await refresh();
		},
	};
}
