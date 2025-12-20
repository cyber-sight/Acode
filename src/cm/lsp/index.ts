export { default as clientManager, LspClientManager } from "./clientManager";
export {
	clearDiagnosticsEffect,
	getLspDiagnostics,
	LSP_DIAGNOSTICS_EVENT,
	lspDiagnosticsClientExtension,
	lspDiagnosticsExtension,
	lspDiagnosticsUiExtension,
} from "./diagnostics";
export { registerLspFormatter } from "./formatter";
export type { InlayHintsConfig } from "./inlayHints";
export {
	inlayHintsClientExtension,
	inlayHintsEditorExtension,
	inlayHintsExtension,
} from "./inlayHints";
export {
	ensureServerRunning,
	resetManagedServers,
	stopManagedServer,
} from "./serverLauncher";
export { default as serverRegistry } from "./serverRegistry";
export { createTransport } from "./transport";

export type {
	BuiltinExtensionsConfig,
	ClientManagerOptions,
	ClientState,
	FileMetadata,
	FormattingOptions,
	LSPDiagnostic,
	LSPFormattingOptions,
	LspDiagnostic,
	LspServerDefinition,
	Position,
	Range,
	TextEdit,
	TransportDescriptor,
	TransportHandle,
	WorkspaceOptions,
} from "./types";
export { default as AcodeWorkspace } from "./workspace";
