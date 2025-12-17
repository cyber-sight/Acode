import type { WorkspaceFile } from "@codemirror/lsp-client";
import { LSPPlugin, Workspace } from "@codemirror/lsp-client";
import type { Text } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import type { WorkspaceFileUpdate, WorkspaceOptions } from "./types";

class AcodeWorkspaceFile implements WorkspaceFile {
	uri: string;
	languageId: string;
	version: number;
	doc: Text;
	views: Set<EditorView>;

	constructor(
		uri: string,
		languageId: string,
		version: number,
		doc: Text,
		view?: EditorView,
	) {
		this.uri = uri;
		this.languageId = languageId;
		this.version = version;
		this.doc = doc;
		this.views = new Set();
		if (view) this.views.add(view);
	}

	getView(preferred?: EditorView): EditorView | null {
		if (preferred && this.views.has(preferred)) return preferred;
		const iterator = this.views.values();
		const next = iterator.next();
		return next.done ? null : next.value;
	}
}

export default class AcodeWorkspace extends Workspace {
	files: AcodeWorkspaceFile[];
	options: WorkspaceOptions;

	#fileMap: Map<string, AcodeWorkspaceFile>;
	#versions: Record<string, number>;

	constructor(
		client: ConstructorParameters<typeof Workspace>[0],
		options: WorkspaceOptions = {},
	) {
		super(client);
		this.files = [];
		this.#fileMap = new Map();
		this.#versions = Object.create(null) as Record<string, number>;
		this.options = options;
	}

	#getOrCreateFile(
		uri: string,
		languageId: string,
		view: EditorView,
	): AcodeWorkspaceFile {
		let file = this.#fileMap.get(uri);
		if (!file) {
			const doc = view.state?.doc;
			if (!doc) {
				throw new Error(
					`Cannot create workspace file without document: ${uri}`,
				);
			}
			file = new AcodeWorkspaceFile(
				uri,
				languageId,
				this.#nextFileVersion(uri),
				doc,
				view,
			);
			this.#fileMap.set(uri, file);
			this.files.push(file);
			this.client.didOpen(file);
		}
		file.views.add(view);
		return file;
	}

	#getFileEntry(uri: string): AcodeWorkspaceFile | null {
		return this.#fileMap.get(uri) ?? null;
	}

	#removeFileEntry(file: AcodeWorkspaceFile): void {
		this.#fileMap.delete(file.uri);
		this.files = this.files.filter((candidate) => candidate !== file);
	}

	#nextFileVersion(uri: string): number {
		const current = this.#versions[uri] ?? -1;
		const next = current + 1;
		this.#versions[uri] = next;
		return next;
	}

	syncFiles(): readonly WorkspaceFileUpdate[] {
		const updates: WorkspaceFileUpdate[] = [];
		for (const file of this.files) {
			const view = file.getView();
			if (!view) continue;
			const plugin = LSPPlugin.get(view);
			if (!plugin) continue;
			const { unsyncedChanges } = plugin;
			if (unsyncedChanges.empty) continue;

			updates.push({ file, prevDoc: file.doc, changes: unsyncedChanges });
			file.doc = view.state.doc;
			file.version = this.#nextFileVersion(file.uri);
			plugin.clear();
		}
		return updates;
	}

	openFile(uri: string, languageId: string, view: EditorView): void {
		if (!view) return;
		this.#getOrCreateFile(uri, languageId, view);
	}

	closeFile(uri: string, view?: EditorView): void {
		const file = this.#getFileEntry(uri);
		if (!file) return;

		if (view && file.views.has(view)) {
			file.views.delete(view);
		}

		if (!file.views.size) {
			this.client.didClose(uri);
			this.#removeFileEntry(file);
		}
	}

	getFile(uri: string): AcodeWorkspaceFile | null {
		return this.#getFileEntry(uri);
	}

	async displayFile(uri: string): Promise<EditorView | null> {
		if (typeof this.options.displayFile === "function") {
			try {
				return await this.options.displayFile(uri);
			} catch (error) {
				console.error("Failed to display file via workspace", error);
			}
		}
		return null;
	}
}
