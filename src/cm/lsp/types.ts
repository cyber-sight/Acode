import type {
	LSPClient,
	LSPClientConfig,
	LSPClientExtension,
	Transport,
	Workspace,
	WorkspaceFile,
} from "@codemirror/lsp-client";
import type { ChangeSet, Extension, Text } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";

export type {
	LSPClient,
	LSPClientConfig,
	LSPClientExtension,
	Transport,
	Workspace,
	WorkspaceFile,
};

export interface WorkspaceFileUpdate {
	file: WorkspaceFile;
	prevDoc: Text;
	changes: ChangeSet;
}

// ============================================================================
// Transport Types
// ============================================================================

export type TransportKind = "websocket" | "stdio" | "external";

export interface WebSocketTransportOptions {
	binary?: boolean;
	timeout?: number;
	reconnect?: boolean;
	maxReconnectAttempts?: number;
}

export interface TransportDescriptor {
	kind: TransportKind;
	url?: string;
	command?: string;
	args?: string[];
	options?: WebSocketTransportOptions;
	protocols?: string[];
	create?: (
		server: LspServerDefinition,
		context: TransportContext,
	) => TransportHandle;
}

export interface TransportHandle {
	transport: Transport;
	dispose: () => Promise<void> | void;
	ready: Promise<void>;
}

export interface TransportContext {
	uri?: string;
	file?: AcodeFile;
	view?: EditorView;
	languageId?: string;
	rootUri?: string | null;
	originalRootUri?: string;
	debugWebSocket?: boolean;
}

// ============================================================================
// Server Registry Types
// ============================================================================

export interface BridgeConfig {
	kind: "axs";
	port: number;
	command: string;
	args?: string[];
}

export interface LauncherInstallConfig {
	command: string;
}

export interface LauncherConfig {
	command?: string;
	args?: string[];
	startCommand?: string | string[];
	checkCommand?: string;
	install?: LauncherInstallConfig;
	bridge?: BridgeConfig;
}

export interface BuiltinExtensionsConfig {
	hover?: boolean;
	completion?: boolean;
	signature?: boolean;
	keymaps?: boolean;
	diagnostics?: boolean;
}

export interface ClientConfig {
	useDefaultExtensions?: boolean;
	builtinExtensions?: BuiltinExtensionsConfig;
	extensions?: Extension[];
	notificationHandlers?: Record<
		string,
		(client: LSPClient, params: unknown) => boolean
	>;
	workspace?: (client: LSPClient) => Workspace;
	rootUri?: string;
	timeout?: number;
}

export interface LanguageResolverContext {
	languageId: string;
	languageName?: string;
	uri?: string;
	file?: AcodeFile;
}

export interface LspServerDefinition {
	id: string;
	label: string;
	enabled: boolean;
	languages: string[];
	transport: TransportDescriptor;
	initializationOptions?: Record<string, unknown>;
	clientConfig?: ClientConfig;
	startupTimeout?: number;
	capabilityOverrides?: Record<string, unknown>;
	rootUri?: ((uri: string, context: RootUriContext) => string | null) | null;
	resolveLanguageId?:
		| ((context: LanguageResolverContext) => string | null)
		| null;
	launcher?: LauncherConfig;
}

export interface RootUriContext {
	uri?: string;
	file?: AcodeFile;
	view?: EditorView;
	languageId?: string;
	rootUri?: string;
}

export type RegistryEventType = "register" | "unregister" | "update";

export type RegistryEventListener = (
	event: RegistryEventType,
	server: LspServerDefinition,
) => void;

// ============================================================================
// Client Manager Types
// ============================================================================

export interface FileMetadata {
	uri: string;
	languageId?: string;
	languageName?: string;
	view?: EditorView;
	file?: AcodeFile;
	rootUri?: string;
}

export interface FormattingOptions {
	tabSize?: number;
	insertSpaces?: boolean;
	[key: string]: unknown;
}

export interface ClientManagerOptions {
	diagnosticsUiExtension?: Extension | Extension[];
	clientExtensions?: Extension | Extension[];
	resolveRoot?: (context: RootUriContext) => Promise<string | null>;
	displayFile?: (uri: string) => Promise<EditorView | null>;
	onClientIdle?: (info: ClientIdleInfo) => void;
}

export interface ClientIdleInfo {
	server: LspServerDefinition;
	client: LSPClient;
	rootUri: string | null;
}

export interface ClientState {
	server: LspServerDefinition;
	client: LSPClient;
	transport: TransportHandle;
	rootUri: string | null;
	attach: (uri: string, view: EditorView) => void;
	detach: (uri: string, view?: EditorView) => void;
	dispose: () => Promise<void>;
}

export interface NormalizedRootUri {
	normalizedRootUri: string | null;
	originalRootUri: string | null;
}

// ============================================================================
// Server Launcher Types
// ============================================================================

export interface ManagedServerEntry {
	uuid: string;
	command: string;
	startedAt: number;
}

export type InstallStatus = "present" | "declined" | "failed";

export interface WaitOptions {
	attempts?: number;
	delay?: number;
	probeTimeout?: number;
}

// ============================================================================
// Workspace Types
// ============================================================================

export interface WorkspaceOptions {
	displayFile?: (uri: string) => Promise<EditorView | null>;
}

// ============================================================================
// Diagnostics Types
// ============================================================================

export interface LspDiagnostic {
	from: number;
	to: number;
	severity: "error" | "warning" | "info" | "hint";
	message: string;
	source?: string;
}

export interface PublishDiagnosticsParams {
	uri: string;
	version?: number;
	diagnostics: RawDiagnostic[];
}

export interface RawDiagnostic {
	range: {
		start: { line: number; character: number };
		end: { line: number; character: number };
	};
	severity?: number;
	code?: number | string;
	source?: string;
	message: string;
}

// ============================================================================
// Formatter Types
// ============================================================================

export interface AcodeApi {
	registerFormatter: (
		id: string,
		extensions: string[],
		formatter: () => Promise<boolean>,
		label: string,
	) => void;
}

// LSP Text Edit
export interface TextEdit {
	range: {
		start: { line: number; character: number };
		end: { line: number; character: number };
	};
	newText: string;
}

/**
 * Uri utility interface
 */
export interface ParsedUri {
	docId?: string;
	rootUri?: string;
	isFileUri?: boolean;
}

// Extend the LSPClient with Acode-specific properties
declare module "@codemirror/lsp-client" {
	interface LSPClient {
		__acodeLoggedInfo?: boolean;
		serverInfo?: { name?: string; version?: string };
	}
}
