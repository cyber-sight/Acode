import type {
	BridgeConfig,
	ClientConfig,
	LanguageResolverContext,
	LauncherConfig,
	LspServerDefinition,
	RegistryEventListener,
	RegistryEventType,
	RootUriContext,
	TransportDescriptor,
	WebSocketTransportOptions,
} from "./types";

const registry = new Map<string, LspServerDefinition>();
const listeners = new Set<RegistryEventListener>();

function toKey(id: string | undefined | null): string {
	return String(id ?? "")
		.trim()
		.toLowerCase();
}

function clone<T>(value: T): T | undefined {
	if (!value || typeof value !== "object") return undefined;
	try {
		return JSON.parse(JSON.stringify(value)) as T;
	} catch (_) {
		return value;
	}
}

function sanitizeLanguages(languages: string[] = []): string[] {
	if (!Array.isArray(languages)) return [];
	return languages
		.map((lang) =>
			String(lang ?? "")
				.trim()
				.toLowerCase(),
		)
		.filter(Boolean);
}

function parsePort(value: unknown): number | null {
	const num = Number(value);
	if (!Number.isFinite(num)) return null;
	const int = Math.floor(num);
	if (int !== num || int <= 0 || int > 65535) return null;
	return int;
}

interface RawBridgeConfig {
	kind?: string;
	port?: unknown;
	command?: string;
	args?: unknown[];
}

function sanitizeBridge(
	serverId: string,
	bridge: RawBridgeConfig | undefined | null,
): BridgeConfig | undefined {
	if (!bridge || typeof bridge !== "object") return undefined;
	const kind = bridge.kind ?? "axs";
	if (kind !== "axs") {
		throw new Error(
			`LSP server ${serverId} declares unsupported bridge kind ${kind}`,
		);
	}
	const port = parsePort(bridge.port);
	if (!port) {
		throw new Error(`LSP server ${serverId} bridge requires a valid port`);
	}
	const command = bridge.command ? String(bridge.command) : null;
	if (!command) {
		throw new Error(`LSP server ${serverId} bridge must supply a command`);
	}
	const args = Array.isArray(bridge.args)
		? bridge.args.map((arg) => String(arg))
		: undefined;
	return {
		kind: "axs",
		port,
		command,
		args,
	};
}

interface RawTransportDescriptor {
	kind?: string;
	command?: string;
	args?: unknown[];
	options?: Record<string, unknown> | WebSocketTransportOptions;
	url?: string;
}

interface RawLauncherConfig {
	command?: string;
	args?: unknown[];
	startCommand?: string | string[];
	checkCommand?: string;
	install?: { command?: string };
	bridge?: RawBridgeConfig;
}

interface RawServerDefinition {
	id?: string;
	label?: string;
	enabled?: boolean;
	languages?: string[];
	transport?: RawTransportDescriptor | TransportDescriptor;
	initializationOptions?: Record<string, unknown>;
	clientConfig?: Record<string, unknown> | ClientConfig;
	startupTimeout?: number;
	capabilityOverrides?: Record<string, unknown>;
	rootUri?:
		| ((uri: string, context: unknown) => string | null)
		| ((uri: string, context: RootUriContext) => string | null)
		| null;
	resolveLanguageId?:
		| ((context: LanguageResolverContext) => string | null)
		| null;
	launcher?: RawLauncherConfig | LauncherConfig;
}

function sanitizeDefinition(
	definition: RawServerDefinition,
): LspServerDefinition {
	if (!definition || typeof definition !== "object") {
		throw new TypeError("LSP server definition must be an object");
	}

	const id = toKey(definition.id);
	if (!id) throw new Error("LSP server definition requires a non-empty id");

	const transport: RawTransportDescriptor = definition.transport ?? {};
	const kind = (transport.kind ?? "stdio") as
		| "stdio"
		| "websocket"
		| "external";

	if (!transport || typeof transport !== "object") {
		throw new Error(`LSP server ${id} is missing a transport descriptor`);
	}

	if (
		!("languages" in definition) ||
		!sanitizeLanguages(definition.languages).length
	) {
		throw new Error(`LSP server ${id} must declare supported languages`);
	}

	if (kind === "stdio" && !transport.command) {
		throw new Error(`LSP server ${id} (stdio) requires a command`);
	}

	if (kind === "websocket" && !transport.url) {
		throw new Error(`LSP server ${id} (websocket) requires a url`);
	}

	const transportOptions: Record<string, unknown> =
		transport.options && typeof transport.options === "object"
			? { ...transport.options }
			: {};

	const sanitizedTransport: TransportDescriptor = {
		kind,
		command: transport.command,
		args: Array.isArray(transport.args)
			? transport.args.map((arg) => String(arg))
			: undefined,
		options: transportOptions,
		url: transport.url,
		protocols: undefined,
	};

	let launcher: LauncherConfig | undefined;
	if (definition.launcher && typeof definition.launcher === "object") {
		const rawLauncher = definition.launcher;
		launcher = {
			command: rawLauncher.command,
			args: Array.isArray(rawLauncher.args)
				? rawLauncher.args.map((arg) => String(arg))
				: undefined,
			startCommand: Array.isArray(rawLauncher.startCommand)
				? rawLauncher.startCommand.map((arg) => String(arg))
				: rawLauncher.startCommand,
			checkCommand: rawLauncher.checkCommand,
			install:
				rawLauncher.install && typeof rawLauncher.install === "object"
					? {
							command: rawLauncher.install.command ?? "",
						}
					: undefined,
			bridge: sanitizeBridge(id, rawLauncher.bridge),
		};
	}

	const sanitized: LspServerDefinition = {
		id,
		label: definition.label ?? id,
		enabled: definition.enabled !== false,
		languages: sanitizeLanguages(definition.languages),
		transport: sanitizedTransport,
		initializationOptions: clone(definition.initializationOptions),
		clientConfig: clone(definition.clientConfig),
		startupTimeout:
			typeof definition.startupTimeout === "number"
				? definition.startupTimeout
				: undefined,
		capabilityOverrides: clone(definition.capabilityOverrides),
		rootUri:
			typeof definition.rootUri === "function" ? definition.rootUri : null,
		resolveLanguageId:
			typeof definition.resolveLanguageId === "function"
				? definition.resolveLanguageId
				: null,
		launcher,
	};

	if (!Object.keys(transportOptions).length) {
		sanitized.transport.options = undefined;
	}

	return sanitized;
}

function resolveJsTsLanguageId(
	languageId: string | undefined,
	languageName: string | undefined,
): string | null {
	const lang = toKey(languageId ?? languageName);
	switch (lang) {
		case "tsx":
		case "typescriptreact":
			return "typescriptreact";
		case "jsx":
		case "javascriptreact":
			return "javascriptreact";
		case "ts":
			return "typescript";
		case "js":
			return "javascript";
		default:
			return lang || null;
	}
}

function notify(event: RegistryEventType, payload: LspServerDefinition): void {
	listeners.forEach((fn) => {
		try {
			fn(event, payload);
		} catch (error) {
			console.error("LSP server registry listener failed", error);
		}
	});
}

export interface RegisterServerOptions {
	replace?: boolean;
}

export function registerServer(
	definition: RawServerDefinition,
	options: RegisterServerOptions = {},
): LspServerDefinition {
	const { replace = false } = options;
	const normalized = sanitizeDefinition(definition);
	const exists = registry.has(normalized.id);
	if (exists && !replace) {
		const existing = registry.get(normalized.id);
		if (existing) return existing;
	}

	registry.set(normalized.id, normalized);
	notify("register", normalized);
	return normalized;
}

export function unregisterServer(id: string): boolean {
	const key = toKey(id);
	if (!key || !registry.has(key)) return false;
	const existing = registry.get(key);
	registry.delete(key);
	if (existing) {
		notify("unregister", existing);
	}
	return true;
}

export type ServerUpdater = (
	current: LspServerDefinition,
) => Partial<LspServerDefinition> | null;

export function updateServer(
	id: string,
	updater: ServerUpdater,
): LspServerDefinition | null {
	const key = toKey(id);
	if (!key || !registry.has(key)) return null;
	const current = registry.get(key);
	if (!current) return null;
	const next = updater({ ...current });
	if (!next) return current;
	const normalized = sanitizeDefinition({
		...current,
		...next,
		id: current.id,
	});
	registry.set(key, normalized);
	notify("update", normalized);
	return normalized;
}

export function getServer(id: string): LspServerDefinition | null {
	return registry.get(toKey(id)) ?? null;
}

export function listServers(): LspServerDefinition[] {
	return Array.from(registry.values());
}

export interface GetServersOptions {
	includeDisabled?: boolean;
}

export function getServersForLanguage(
	languageId: string,
	options: GetServersOptions = {},
): LspServerDefinition[] {
	const { includeDisabled = false } = options;
	const langKey = toKey(languageId);
	if (!langKey) return [];

	return listServers().filter((server) => {
		if (!includeDisabled && !server.enabled) return false;
		return server.languages.includes(langKey);
	});
}

export function onRegistryChange(listener: RegistryEventListener): () => void {
	if (typeof listener !== "function") return () => {};
	listeners.add(listener);
	return () => listeners.delete(listener);
}

function registerBuiltinServers(): void {
	const defaults: RawServerDefinition[] = [
		{
			id: "typescript",
			label: "TypeScript / JavaScript",
			languages: [
				"javascript",
				"javascriptreact",
				"typescript",
				"typescriptreact",
				"tsx",
				"jsx",
			],
			transport: {
				kind: "websocket",
				url: "ws://127.0.0.1:2090",
			},
			launcher: {
				bridge: {
					kind: "axs",
					port: 2090,
					command: "typescript-language-server",
					args: ["--stdio"],
				},
				checkCommand: "which typescript-language-server",
				install: {
					command:
						"apk add --no-cache nodejs npm && npm install -g typescript-language-server typescript",
				},
			},
			enabled: false,
			resolveLanguageId: ({ languageId, languageName }) =>
				resolveJsTsLanguageId(languageId, languageName),
		},
		{
			id: "vtsls",
			label: "TypeScript / JavaScript (vtsls)",
			languages: [
				"javascript",
				"javascriptreact",
				"typescript",
				"typescriptreact",
				"tsx",
				"jsx",
			],
			transport: {
				kind: "websocket",
				url: "ws://127.0.0.1:2095",
			},
			launcher: {
				bridge: {
					kind: "axs",
					port: 2095,
					command: "vtsls",
					args: ["--stdio"],
				},
				checkCommand: "which vtsls",
				install: {
					command:
						"apk add --no-cache nodejs npm && npm install -g @vtsls/language-server",
				},
			},
			enabled: false,
			resolveLanguageId: ({ languageId, languageName }) =>
				resolveJsTsLanguageId(languageId, languageName),
		},
		{
			id: "python",
			label: "Python (pylsp)",
			languages: ["python"],
			transport: {
				kind: "websocket",
				url: "ws://127.0.0.1:2087",
			},
			launcher: {
				command: "pylsp",
				args: ["--ws", "--host", "127.0.0.1", "--port", "2087"],
				checkCommand: "which pylsp",
				install: {
					command:
						"apk update && apk upgrade && apk add python3 py3-pip && PIP_BREAK_SYSTEM_PACKAGES=1 pip install 'python-lsp-server[websockets,all]'",
				},
			},
			initializationOptions: {
				pylsp: {
					plugins: {
						pyflakes: { enabled: true },
						pycodestyle: { enabled: true },
						mccabe: { enabled: true },
					},
				},
			},
			enabled: false,
		},
		{
			id: "eslint",
			label: "ESLint",
			languages: [
				"javascript",
				"javascriptreact",
				"typescript",
				"typescriptreact",
				"tsx",
				"jsx",
			],
			transport: {
				kind: "websocket",
				url: "ws://127.0.0.1:2096",
			},
			launcher: {
				bridge: {
					kind: "axs",
					port: 2096,
					command: "vscode-eslint-language-server",
					args: ["--stdio"],
				},
				checkCommand: "which vscode-eslint-language-server",
				install: {
					command:
						"apk add --no-cache nodejs npm && npm install -g vscode-langservers-extracted",
				},
			},
			enabled: false,
			clientConfig: {
				builtinExtensions: {
					hover: false,
					completion: false,
					signature: false,
					keymaps: false,
				},
			},
			resolveLanguageId: ({ languageId, languageName }) =>
				resolveJsTsLanguageId(languageId, languageName),
		},
		{
			id: "clangd",
			label: "C / C++ (clangd)",
			languages: ["c", "cpp"],
			transport: {
				kind: "websocket",
				url: "ws://127.0.0.1:2094",
			},
			launcher: {
				bridge: {
					kind: "axs",
					port: 2094,
					command: "clangd",
				},
				checkCommand: "which clangd",
				install: {
					command: "apk add --no-cache clang-extra-tools",
				},
			},
			enabled: false,
		},
		{
			id: "html",
			label: "HTML",
			languages: ["html", "vue", "svelte"],
			transport: {
				kind: "websocket",
				url: "ws://127.0.0.1:2091",
			},
			launcher: {
				bridge: {
					kind: "axs",
					port: 2091,
					command: "vscode-html-language-server",
					args: ["--stdio"],
				},
				checkCommand: "which vscode-html-language-server",
				install: {
					command:
						"apk add --no-cache nodejs npm && npm install -g vscode-langservers-extracted",
				},
			},
			enabled: false,
		},
		{
			id: "css",
			label: "CSS",
			languages: ["css", "scss", "less"],
			transport: {
				kind: "websocket",
				url: "ws://127.0.0.1:2092",
			},
			launcher: {
				bridge: {
					kind: "axs",
					port: 2092,
					command: "vscode-css-language-server",
					args: ["--stdio"],
				},
				checkCommand: "which vscode-css-language-server",
				install: {
					command:
						"apk add --no-cache nodejs npm && npm install -g vscode-langservers-extracted",
				},
			},
			enabled: false,
		},
		{
			id: "json",
			label: "JSON",
			languages: ["json", "jsonc"],
			transport: {
				kind: "websocket",
				url: "ws://127.0.0.1:2093",
			},
			launcher: {
				bridge: {
					kind: "axs",
					port: 2093,
					command: "vscode-json-language-server",
					args: ["--stdio"],
				},
				checkCommand: "which vscode-json-language-server",
				install: {
					command:
						"apk add --no-cache nodejs npm && npm install -g vscode-langservers-extracted",
				},
			},
			enabled: false,
		},
	];

	defaults.forEach((def) => {
		try {
			registerServer(def, { replace: false });
		} catch (error) {
			console.error("Failed to register builtin LSP server", def.id, error);
		}
	});
}

registerBuiltinServers();

export default {
	registerServer,
	unregisterServer,
	updateServer,
	getServer,
	getServersForLanguage,
	listServers,
	onRegistryChange,
};
