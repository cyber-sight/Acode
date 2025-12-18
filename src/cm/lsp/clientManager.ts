import { getIndentUnit, indentUnit } from "@codemirror/language";
import type { LSPClientExtension } from "@codemirror/lsp-client";
import {
	findReferencesKeymap,
	formatKeymap,
	hoverTooltips,
	jumpToDefinitionKeymap,
	LSPClient,
	LSPPlugin,
	renameKeymap,
	serverCompletion,
	serverDiagnostics,
	signatureHelp,
} from "@codemirror/lsp-client";
import { Extension, MapMode } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import lspStatusBar from "components/lspStatusBar";
import Uri from "utils/Uri";
import { ensureServerRunning } from "./serverLauncher";
import serverRegistry from "./serverRegistry";
import { createTransport } from "./transport";
import type {
	BuiltinExtensionsConfig,
	ClientManagerOptions,
	ClientState,
	FileMetadata,
	FormattingOptions,
	LspServerDefinition,
	NormalizedRootUri,
	ParsedUri,
	RootUriContext,
	TextEdit,
	TransportHandle,
} from "./types";
import AcodeWorkspace from "./workspace";

function asArray<T>(value: T | T[] | null | undefined): T[] {
	if (!value) return [];
	return Array.isArray(value) ? value : [value];
}

function pluginKey(
	serverId: string,
	rootUri: string | null | undefined,
): string {
	return `${serverId}::${rootUri ?? "__global__"}`;
}

function safeString(value: unknown): string {
	return value != null ? String(value) : "";
}

const defaultKeymaps = keymap.of([
	...formatKeymap,
	...renameKeymap,
	...jumpToDefinitionKeymap,
	...findReferencesKeymap,
]);

interface BuiltinExtensionsResult {
	extensions: Extension[];
	diagnosticsExtension: Extension | LSPClientExtension | null;
}

function buildBuiltinExtensions(
	config: BuiltinExtensionsConfig = {},
): BuiltinExtensionsResult {
	const {
		hover: includeHover = true,
		completion: includeCompletion = true,
		signature: includeSignature = true,
		keymaps: includeKeymaps = true,
		diagnostics: includeDiagnostics = true,
	} = config;

	const extensions: Extension[] = [];
	let diagnosticsExtension: Extension | LSPClientExtension | null = null;

	if (includeCompletion) extensions.push(serverCompletion());
	if (includeHover) extensions.push(hoverTooltips());
	if (includeKeymaps) extensions.push(defaultKeymaps);
	if (includeSignature) extensions.push(signatureHelp());
	if (includeDiagnostics) {
		const diagExt = serverDiagnostics();
		diagnosticsExtension = diagExt;
		extensions.push(diagExt as Extension);
	}

	return { extensions, diagnosticsExtension };
}

interface LSPError extends Error {
	code?: string;
}

interface InitContext {
	key: string;
	normalizedRootUri: string | null;
	originalRootUri: string | null;
}

interface ExtendedLSPClient extends LSPClient {
	__acodeLoggedInfo?: boolean;
}

export class LspClientManager {
	options: ClientManagerOptions;

	#clients: Map<string, ClientState>;
	#pendingClients: Map<string, Promise<ClientState>>;

	constructor(options: ClientManagerOptions = {}) {
		this.options = { ...options };
		this.#clients = new Map();
		this.#pendingClients = new Map();
	}

	setOptions(next: Partial<ClientManagerOptions>): void {
		this.options = { ...this.options, ...next };
	}

	getActiveClients(): ClientState[] {
		return Array.from(this.#clients.values());
	}

	async getExtensionsForFile(metadata: FileMetadata): Promise<Extension[]> {
		const { uri, languageId, languageName, view, file, rootUri } = metadata;

		const effectiveLang = safeString(languageId ?? languageName).toLowerCase();
		if (!effectiveLang) return [];

		const servers = serverRegistry.getServersForLanguage(effectiveLang);
		if (!servers.length) return [];

		const lspExtensions: Extension[] = [];
		const diagnosticsUiExtension = this.options.diagnosticsUiExtension;

		for (const server of servers) {
			let targetLanguageId = effectiveLang;
			if (server.resolveLanguageId) {
				try {
					const resolved = server.resolveLanguageId({
						languageId: effectiveLang,
						languageName,
						uri,
						file,
					});
					if (resolved) targetLanguageId = safeString(resolved);
				} catch (error) {
					console.warn(
						`LSP server ${server.id} failed to resolve language id for ${uri}`,
						error,
					);
				}
			}

			try {
				const clientState = await this.#ensureClient(server, {
					uri,
					file,
					view,
					languageId: targetLanguageId,
					rootUri,
				});
				const plugin = clientState.client.plugin(uri, targetLanguageId);
				clientState.attach(uri, view as EditorView);
				lspExtensions.push(plugin);
			} catch (error) {
				const lspError = error as LSPError;
				if (lspError?.code === "LSP_SERVER_UNAVAILABLE") {
					console.info(
						`Skipping LSP client for ${server.id}: ${lspError.message}`,
					);
					continue;
				}
				console.error(
					`Failed to initialize LSP client for ${server.id}`,
					error,
				);
			}
		}

		if (diagnosticsUiExtension && lspExtensions.length) {
			lspExtensions.push(...asArray(diagnosticsUiExtension));
		}

		return lspExtensions;
	}

	async formatDocument(
		metadata: FileMetadata,
		options: FormattingOptions = {},
	): Promise<boolean> {
		const { uri, languageId, languageName, view, file } = metadata;
		const effectiveLang = safeString(languageId ?? languageName).toLowerCase();
		if (!effectiveLang || !view) return false;
		const servers = serverRegistry.getServersForLanguage(effectiveLang);
		if (!servers.length) return false;

		for (const server of servers) {
			try {
				const context: RootUriContext = {
					uri,
					languageId: effectiveLang,
					view,
					file,
					rootUri: metadata.rootUri,
				};
				const state = await this.#ensureClient(server, context);
				const capabilities = state.client.serverCapabilities;
				if (!capabilities?.documentFormattingProvider) continue;
				state.attach(uri, view);
				const plugin = LSPPlugin.get(view);
				if (!plugin) continue;
				plugin.client.sync();
				const edits = await state.client.request<
					{ textDocument: { uri: string }; options: FormattingOptions },
					TextEdit[] | null
				>("textDocument/formatting", {
					textDocument: { uri },
					options: buildFormattingOptions(view, options),
				});
				if (!edits || !edits.length) {
					plugin.client.sync();
					return true;
				}
				const applied = applyTextEdits(plugin, view, edits);
				if (applied) {
					plugin.client.sync();
					return true;
				}
			} catch (error) {
				console.error(`LSP formatting failed for ${server.id}`, error);
			}
		}
		return false;
	}

	detach(uri: string, view: EditorView): void {
		for (const state of this.#clients.values()) {
			state.detach(uri, view);
		}
	}

	async dispose(): Promise<void> {
		const disposeOps: Promise<void>[] = [];
		for (const [key, state] of this.#clients.entries()) {
			disposeOps.push(state.dispose());
			this.#clients.delete(key);
		}
		await Promise.allSettled(disposeOps);
	}

	async #ensureClient(
		server: LspServerDefinition,
		context: RootUriContext,
	): Promise<ClientState> {
		const resolvedRoot = await this.#resolveRootUri(server, context);
		const { normalizedRootUri, originalRootUri } = normalizeRootUriForServer(
			server,
			resolvedRoot,
		);
		const key = pluginKey(server.id, normalizedRootUri);

		// Return existing client if already initialized
		if (this.#clients.has(key)) {
			return this.#clients.get(key)!;
		}

		// If initialization is already in progress, wait for it
		if (this.#pendingClients.has(key)) {
			return this.#pendingClients.get(key)!;
		}

		// Create and track the pending initialization
		const initPromise = this.#initializeClient(server, context, {
			key,
			normalizedRootUri,
			originalRootUri,
		});
		this.#pendingClients.set(key, initPromise);

		try {
			return await initPromise;
		} finally {
			this.#pendingClients.delete(key);
		}
	}

	async #initializeClient(
		server: LspServerDefinition,
		context: RootUriContext,
		initContext: InitContext,
	): Promise<ClientState> {
		const { key, normalizedRootUri, originalRootUri } = initContext;

		const workspaceOptions = {
			displayFile: this.options.displayFile,
		};

		const clientConfig = { ...(server.clientConfig ?? {}) };
		const builtinConfig = clientConfig.builtinExtensions ?? {};
		const useDefaultExtensions = clientConfig.useDefaultExtensions !== false;
		const { extensions: defaultExtensions, diagnosticsExtension } =
			useDefaultExtensions
				? buildBuiltinExtensions({
						hover: builtinConfig.hover !== false,
						completion: builtinConfig.completion !== false,
						signature: builtinConfig.signature !== false,
						keymaps: builtinConfig.keymaps !== false,
						diagnostics: builtinConfig.diagnostics !== false,
					})
				: { extensions: [], diagnosticsExtension: null };

		const extraExtensions = asArray(this.options.clientExtensions);
		const serverExtensions = asArray(clientConfig.extensions);

		interface ExtensionWithCapabilities {
			clientCapabilities?: {
				textDocument?: {
					publishDiagnostics?: unknown;
				};
			};
		}

		const wantsCustomDiagnostics = [
			...extraExtensions,
			...serverExtensions,
		].some((ext) => {
			const extWithCaps = ext as ExtensionWithCapabilities;
			return !!extWithCaps?.clientCapabilities?.textDocument
				?.publishDiagnostics;
		});

		const filteredBuiltins =
			wantsCustomDiagnostics && diagnosticsExtension
				? defaultExtensions.filter((ext) => ext !== diagnosticsExtension)
				: defaultExtensions;

		const mergedExtensions = [
			...filteredBuiltins,
			...extraExtensions,
			...serverExtensions,
		];
		clientConfig.extensions = mergedExtensions;

		const existingHandlers = clientConfig.notificationHandlers ?? {};

		type LogLevel = "error" | "warn" | "log" | "info";
		interface LogMessageParams {
			type?: number;
			message?: string;
		}
		interface ShowMessageParams {
			type?: number;
			message?: string;
		}

		clientConfig.notificationHandlers = {
			...existingHandlers,
			"window/logMessage": (_client: LSPClient, params: unknown): boolean => {
				const logParams = params as LogMessageParams;
				if (!logParams?.message) return false;
				const { type, message } = logParams;
				let level: LogLevel = "info";
				switch (type) {
					case 1:
						level = "error";
						break;
					case 2:
						level = "warn";
						break;
					case 4:
						level = "log";
						break;
					default:
						level = "info";
				}
				const logFn = console[level] ?? console.info;
				logFn(`[LSP:${server.id}] ${message}`);
				return true;
			},
			"window/showMessage": (_client: LSPClient, params: unknown): boolean => {
				const showParams = params as ShowMessageParams;
				if (!showParams?.message) return false;
				const { type, message } = showParams;
				let statusType: "info" | "success" | "warning" | "error" = "info";
				let icon = "info";
				let duration: number | false = 5000;

				switch (type) {
					case 1: // Error
						statusType = "error";
						icon = "error";
						duration = false; // Persistent for errors
						break;
					case 2: // Warning
						statusType = "warning";
						icon = "warningreport_problem";
						duration = 8000;
						break;
					case 3: // Info
						statusType = "info";
						icon = "info";
						break;
					case 4: // Log
						statusType = "info";
						icon = "autorenew";
						break;
				}

				lspStatusBar.show({
					message,
					title: server.label || server.id,
					type: statusType,
					icon,
					duration,
				});
				console.info(`[LSP:${server.id}] ${message}`);
				return true;
			},
			// "$/progress": (_client: LSPClient, params: unknown): boolean => {
			// 	interface ProgressParams {
			// 		token?: string | number;
			// 		value?: {
			// 			kind?: "begin" | "report" | "end";
			// 			title?: string;
			// 			message?: string;
			// 			percentage?: number;
			// 			cancellable?: boolean;
			// 		};
			// 	}
			// 	const progressParams = params as ProgressParams;
			// 	if (!progressParams?.value) return false;
			// 	console.log("Progress", progressParams.value);

			// 	const { kind, title, message, percentage } = progressParams.value;
			// 	const displayTitle = title || server.label || server.id;

			// 	if (kind === "begin") {
			// 		lspStatusBar.show({
			// 			message: message || "Starting...",
			// 			title: displayTitle,
			// 			type: "info",
			// 			icon: "autorenew",
			// 			duration: false,
			// 			showProgress: typeof percentage === "number",
			// 			progress: percentage,
			// 		});
			// 	} else if (kind === "report") {
			// 		lspStatusBar.update({
			// 			message: message,
			// 			progress: percentage,
			// 		});
			// 	} else if (kind === "end") {
			// 		lspStatusBar.show({
			// 			message: message || "Complete",
			// 			title: displayTitle,
			// 			type: "success",
			// 			icon: "check",
			// 			duration: 2000,
			// 		});
			// 	}

			// 	console.info(
			// 		`[LSP:${server.id}] Progress: ${kind} - ${message || title || ""} ${typeof percentage === "number" ? `(${percentage}%)` : ""}`,
			// 	);
			// 	return true;
			// },
		};

		if (!clientConfig.workspace) {
			clientConfig.workspace = (client: LSPClient) =>
				new AcodeWorkspace(client, workspaceOptions);
		}

		if (normalizedRootUri && !clientConfig.rootUri) {
			clientConfig.rootUri = normalizedRootUri;
		}

		if (!normalizedRootUri && clientConfig.rootUri) {
			delete clientConfig.rootUri;
		}

		if (server.startupTimeout && !clientConfig.timeout) {
			clientConfig.timeout = server.startupTimeout;
		}

		let transportHandle: TransportHandle | undefined;
		let client: ExtendedLSPClient | undefined;

		try {
			await ensureServerRunning(server);
			transportHandle = createTransport(server, {
				...context,
				rootUri: normalizedRootUri ?? null,
				originalRootUri: originalRootUri ?? undefined,
			});
			await transportHandle.ready;
			client = new LSPClient(clientConfig) as ExtendedLSPClient;
			client.connect(transportHandle.transport);
			await client.initializing;
			if (!client.__acodeLoggedInfo) {
				if (normalizedRootUri) {
					if (originalRootUri && originalRootUri !== normalizedRootUri) {
						console.info(
							`[LSP:${server.id}] root ${normalizedRootUri} (from ${originalRootUri})`,
						);
					} else {
						console.info(`[LSP:${server.id}] root`, normalizedRootUri);
					}
				} else if (originalRootUri) {
					console.info(`[LSP:${server.id}] root ignored`, originalRootUri);
				}
				client.__acodeLoggedInfo = true;
			}
		} catch (error) {
			transportHandle?.dispose?.();
			throw error;
		}

		const state = this.#createClientState({
			key,
			server,
			client,
			transportHandle,
			normalizedRootUri,
			originalRootUri,
		});

		this.#clients.set(key, state);
		return state;
	}

	#createClientState(params: {
		key: string;
		server: LspServerDefinition;
		client: LSPClient;
		transportHandle: TransportHandle;
		normalizedRootUri: string | null;
		originalRootUri: string | null;
	}): ClientState {
		const {
			key,
			server,
			client,
			transportHandle,
			normalizedRootUri,
			originalRootUri,
		} = params;
		const fileRefs = new Map<string, Set<EditorView>>();
		const effectiveRoot = normalizedRootUri ?? originalRootUri ?? null;

		const attach = (uri: string, view: EditorView): void => {
			const existing = fileRefs.get(uri) ?? new Set();
			existing.add(view);
			fileRefs.set(uri, existing);
			const suffix = effectiveRoot ? ` (root ${effectiveRoot})` : "";
			console.info(`[LSP:${server.id}] attached to ${uri}${suffix}`);
		};

		const detach = (uri: string, view?: EditorView): void => {
			const existing = fileRefs.get(uri);
			if (!existing) return;
			if (view) existing.delete(view);
			if (!view || !existing.size) {
				fileRefs.delete(uri);
				try {
					// Only pass uri to closeFile - view is not needed for closing
					// and passing it may cause issues if the view is already disposed
					(client.workspace as AcodeWorkspace)?.closeFile?.(uri);
				} catch (error) {
					console.warn(`Failed to close LSP file ${uri}`, error);
				}
			}

			if (!fileRefs.size) {
				this.options.onClientIdle?.({
					server,
					client,
					rootUri: effectiveRoot,
				});
			}
		};

		const dispose = async (): Promise<void> => {
			try {
				client.disconnect();
			} catch (error) {
				console.warn(`Error disconnecting LSP client ${server.id}`, error);
			}
			try {
				await transportHandle.dispose?.();
			} catch (error) {
				console.warn(`Error disposing LSP transport ${server.id}`, error);
			}
			this.#clients.delete(key);
		};

		return {
			server,
			client,
			transport: transportHandle,
			rootUri: effectiveRoot,
			attach,
			detach,
			dispose,
		};
	}

	async #resolveRootUri(
		server: LspServerDefinition,
		context: RootUriContext,
	): Promise<string | null> {
		if (context?.rootUri) return context.rootUri;

		if (typeof server.rootUri === "function") {
			try {
				const value = await server.rootUri(context?.uri ?? "", context);
				if (value) return safeString(value);
			} catch (error) {
				console.warn(`Server root resolver failed for ${server.id}`, error);
			}
		}

		if (typeof this.options.resolveRoot === "function") {
			try {
				const value = await this.options.resolveRoot(context);
				if (value) return safeString(value);
			} catch (error) {
				console.warn("Global LSP root resolver failed", error);
			}
		}

		return null;
	}
}

interface Change {
	from: number;
	to: number;
	insert: string;
}

function applyTextEdits(
	plugin: LSPPlugin,
	view: EditorView,
	edits: TextEdit[],
): boolean {
	const changes: Change[] = [];
	for (const edit of edits) {
		if (!edit?.range) continue;
		let fromBase: number;
		let toBase: number;
		try {
			fromBase = plugin.fromPosition(edit.range.start, plugin.syncedDoc);
			toBase = plugin.fromPosition(edit.range.end, plugin.syncedDoc);
		} catch (_) {
			continue;
		}
		const fromResult = plugin.unsyncedChanges.mapPos(
			fromBase,
			1,
			MapMode.TrackDel,
		);
		const toResult = plugin.unsyncedChanges.mapPos(
			toBase,
			-1,
			MapMode.TrackDel,
		);
		if (fromResult == null || toResult == null) continue;
		const insert =
			typeof edit.newText === "string"
				? edit.newText.replace(/\r\n/g, "\n")
				: "";
		changes.push({ from: fromResult, to: toResult, insert });
	}
	if (!changes.length) return false;
	changes.sort((a, b) => a.from - b.from || a.to - b.to);
	view.dispatch({ changes });
	return true;
}

function buildFormattingOptions(
	view: EditorView,
	overrides: FormattingOptions = {},
): FormattingOptions {
	const state = view?.state;
	if (!state) return { ...overrides };

	const unitValue = state.facet(indentUnit);
	const unit =
		typeof unitValue === "string" && unitValue.length
			? unitValue
			: String(unitValue ?? "\t");
	let tabSize = getIndentUnit(state);
	if (
		typeof tabSize !== "number" ||
		!Number.isFinite(tabSize) ||
		tabSize <= 0
	) {
		tabSize = resolveIndentWidth(unit);
	}
	const insertSpaces = !unit.includes("\t");

	return {
		tabSize,
		insertSpaces,
		...overrides,
	};
}

function resolveIndentWidth(unit: string): number {
	if (typeof unit !== "string" || !unit.length) return 4;
	let width = 0;
	for (const ch of unit) {
		if (ch === "\t") return 4;
		width += 1;
	}
	return width || 4;
}

const defaultManager = new LspClientManager();

export default defaultManager;

const FILE_SCHEME_REQUIRED_SERVERS = new Set(["typescript"]);

function normalizeRootUriForServer(
	server: LspServerDefinition,
	rootUri: string | null,
): NormalizedRootUri {
	if (!rootUri || typeof rootUri !== "string") {
		return { normalizedRootUri: null, originalRootUri: null };
	}
	const schemeMatch = /^([a-zA-Z][\w+\-.]*):/.exec(rootUri);
	const scheme = schemeMatch ? schemeMatch[1].toLowerCase() : null;
	if (scheme === "file") {
		return { normalizedRootUri: rootUri, originalRootUri: rootUri };
	}

	if (scheme === "content") {
		const fileUri = contentUriToFileUri(rootUri);
		if (fileUri) {
			return { normalizedRootUri: fileUri, originalRootUri: rootUri };
		}
		if (FILE_SCHEME_REQUIRED_SERVERS.has(server.id)) {
			return { normalizedRootUri: null, originalRootUri: rootUri };
		}
	}

	return { normalizedRootUri: rootUri, originalRootUri: rootUri };
}

function contentUriToFileUri(uri: string): string | null {
	try {
		const parsed = Uri.parse(uri) as ParsedUri | null;
		if (!parsed || typeof parsed !== "object") return null;
		const { docId, rootUri, isFileUri } = parsed;
		if (!docId) return null;

		if (isFileUri && rootUri) {
			return rootUri;
		}

		const providerMatch =
			/^content:\/\/com\.((?![:<>"/\\|?*]).*)\\.documents\//.exec(
				rootUri ?? "",
			);
		const providerId = providerMatch ? providerMatch[1] : null;

		let normalized = docId.trim();
		if (!normalized) return null;

		switch (providerId) {
			case "foxdebug.acode":
				normalized = normalized.replace(/:+$/, "");
				if (!normalized) return null;
				if (normalized.startsWith("raw:/")) {
					normalized = normalized.slice(4);
				} else if (normalized.startsWith("raw:")) {
					normalized = normalized.slice(4);
				}
				if (!normalized.startsWith("/")) return null;
				return buildFileUri(normalized);
			case "android.externalstorage":
				normalized = normalized.replace(/:+$/, "");
				if (!normalized) return null;

				if (normalized.startsWith("/")) {
					return buildFileUri(normalized);
				}

				if (normalized.startsWith("raw:/")) {
					return buildFileUri(normalized.slice(4));
				}

				if (normalized.startsWith("raw:")) {
					return buildFileUri(normalized.slice(4));
				}

				const separator = normalized.indexOf(":");
				if (separator === -1) return null;

				const root = normalized.slice(0, separator);
				const remainder = normalized.slice(separator + 1);
				if (!remainder) return null;

				switch (root) {
					case "primary":
						return buildFileUri(`/storage/emulated/0/${remainder}`);
					default:
						if (/^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$/.test(root)) {
							return buildFileUri(`/storage/${root}/${remainder}`);
						}
				}
				return null;
			default:
				return null;
		}
	} catch (_) {
		return null;
	}
}

function buildFileUri(pathname: string): string | null {
	if (!pathname) return null;
	const normalized = pathname.startsWith("/") ? pathname : `/${pathname}`;
	const encoded = encodeURI(normalized).replace(/#/g, "%23");
	return `file://${encoded}`;
}
