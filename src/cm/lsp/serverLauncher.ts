import lspStatusBar from "components/lspStatusBar";
import toast from "components/toast";
import confirm from "dialogs/confirm";
import loader from "dialogs/loader";
import type {
	BridgeConfig,
	InstallStatus,
	LauncherConfig,
	LspServerDefinition,
	ManagedServerEntry,
	WaitOptions,
} from "./types";

const managedServers = new Map<string, ManagedServerEntry>();
const checkedCommands = new Map<string, InstallStatus>();
const pendingInstallChecks = new Map<string, Promise<boolean>>();
const announcedServers = new Set<string>();

const STATUS_PRESENT: InstallStatus = "present";
const STATUS_DECLINED: InstallStatus = "declined";
const STATUS_FAILED: InstallStatus = "failed";

const AXS_BINARY = "$PREFIX/axs";

function getExecutor(): Executor {
	const executor = (globalThis as unknown as { Executor?: Executor }).Executor;
	if (!executor) {
		throw new Error("Executor plugin is not available");
	}
	return executor;
}

function joinCommand(command: string, args: string[] = []): string {
	if (!Array.isArray(args)) return command;
	return [command, ...args].join(" ");
}

function wrapShellCommand(command: string): string {
	const script = command.trim();
	const escaped = script.replace(/"/g, '\\"');
	return `sh -lc "set -e; ${escaped}"`;
}

async function runCommand(command: string): Promise<string> {
	const wrapped = wrapShellCommand(command);
	return getExecutor().execute(wrapped, true);
}

function quoteArg(value: unknown): string {
	const str = String(value ?? "");
	if (!str.length) return "''";
	if (/^[A-Za-z0-9_@%+=:,./-]+$/.test(str)) return str;
	return `'${str.replace(/'/g, "'\\''")}'`;
}

function buildAxsBridgeCommand(
	bridge: BridgeConfig | undefined,
): string | null {
	if (!bridge || bridge.kind !== "axs") return null;
	const port = Number(bridge.port);
	if (!Number.isInteger(port) || port <= 0 || port > 65535) {
		throw new Error(
			`Bridge requires a valid TCP port (received ${bridge.port})`,
		);
	}
	const binary = bridge.command
		? String(bridge.command)
		: (() => {
				throw new Error("Bridge requires a command to execute");
			})();
	const args: string[] = Array.isArray(bridge.args)
		? bridge.args.map((arg) => String(arg))
		: [];

	const parts = [AXS_BINARY, "--port", String(port), "lsp", quoteArg(binary)];
	if (args.length) {
		parts.push("--");
		args.forEach((arg) => parts.push(quoteArg(arg)));
	}
	return parts.join(" ");
}

function resolveStartCommand(server: LspServerDefinition): string | null {
	const launcher = server.launcher;
	if (!launcher) return null;

	if (launcher.startCommand) {
		return Array.isArray(launcher.startCommand)
			? launcher.startCommand.join(" ")
			: String(launcher.startCommand);
	}
	if (launcher.command) {
		return joinCommand(launcher.command, launcher.args);
	}
	if (launcher.bridge) {
		return buildAxsBridgeCommand(launcher.bridge);
	}
	return null;
}

async function ensureInstalled(server: LspServerDefinition): Promise<boolean> {
	const launcher = server.launcher;
	if (!launcher?.checkCommand) return true;

	const cacheKey = `${server.id}:${launcher.checkCommand}`;

	// Return cached result if already checked
	if (checkedCommands.has(cacheKey)) {
		return checkedCommands.get(cacheKey) === STATUS_PRESENT;
	}

	// If there's already a pending check for this server, wait for it
	if (pendingInstallChecks.has(cacheKey)) {
		const pending = pendingInstallChecks.get(cacheKey);
		if (pending) return pending;
	}

	// Create and track the pending promise
	const checkPromise = performInstallCheck(server, launcher, cacheKey);
	pendingInstallChecks.set(cacheKey, checkPromise);

	try {
		return await checkPromise;
	} finally {
		pendingInstallChecks.delete(cacheKey);
	}
}

interface LoaderDialog {
	show: () => void;
	destroy: () => void;
}

async function performInstallCheck(
	server: LspServerDefinition,
	launcher: LauncherConfig,
	cacheKey: string,
): Promise<boolean> {
	try {
		if (launcher.checkCommand) {
			await runCommand(launcher.checkCommand);
		}
		checkedCommands.set(cacheKey, STATUS_PRESENT);
		return true;
	} catch (error) {
		if (!launcher.install) {
			checkedCommands.set(cacheKey, STATUS_FAILED);
			console.warn(
				`LSP server ${server.id} is missing check command result and has no installer.`,
				error,
			);
			throw error;
		}

		const install = launcher.install;
		const displayLabel = (
			server.label ||
			server.id ||
			"Language server"
		).trim();
		const promptMessage = `Install ${displayLabel} language server?`;
		const shouldInstall = await confirm(
			server.label || displayLabel,
			promptMessage,
		);

		if (!shouldInstall) {
			checkedCommands.set(cacheKey, STATUS_DECLINED);
			return false;
		}

		let loadingDialog: LoaderDialog | null = null;
		try {
			loadingDialog = loader.create(
				server.label,
				`Installing ${server.label}...`,
			);
			loadingDialog.show();
			await runCommand(install.command);
			toast(`${server.label} installed`);
			checkedCommands.set(cacheKey, STATUS_PRESENT);
			return true;
		} catch (installError) {
			console.error(`Failed to install ${server.id}`, installError);
			toast(strings?.error ?? "Error");
			checkedCommands.set(cacheKey, STATUS_FAILED);
			throw installError;
		} finally {
			loadingDialog?.destroy?.();
		}
	}
}

async function startInteractiveServer(
	command: string,
	serverId: string,
): Promise<string> {
	const executor = getExecutor();
	const callback: ExecutorCallback = (type, data) => {
		if (type === "stderr") {
			if (/proot warning/i.test(data)) return;
			console.warn(`[${serverId}] ${data}`);
		} else if (type === "stdout" && data && data.trim()) {
			console.info(`[${serverId}] ${data}`);
		}
	};
	const uuid = await executor.start(command, callback, true);
	managedServers.set(serverId, {
		uuid,
		command,
		startedAt: Date.now(),
	});
	return uuid;
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForWebSocket(
	url: string,
	options: WaitOptions = {},
): Promise<void> {
	const { attempts = 20, delay = 200, probeTimeout = 2000 } = options;

	let lastError: Error | null = null;
	for (let i = 0; i < attempts; i++) {
		try {
			await new Promise<void>((resolve, reject) => {
				let socket: WebSocket | null = null;
				let timer: ReturnType<typeof setTimeout> | null = null;
				try {
					socket = new WebSocket(url);
				} catch (error) {
					reject(error);
					return;
				}

				const cleanup = (cb?: () => void): void => {
					if (timer) clearTimeout(timer);
					if (socket) {
						socket.onopen = null;
						socket.onerror = null;
						try {
							socket.close();
						} catch (_) {
							// Ignore close errors
						}
					}
					if (cb) cb();
				};

				socket.onopen = () => cleanup(resolve);
				socket.onerror = (event: Event) =>
					cleanup(() =>
						reject(
							event instanceof Error ? event : new Error("websocket error"),
						),
					);
				timer = setTimeout(
					() => cleanup(() => reject(new Error("timeout"))),
					probeTimeout,
				);
			});
			return;
		} catch (error) {
			lastError = error instanceof Error ? error : new Error(String(error));
			await sleep(delay);
		}
	}
	const reason = lastError ? lastError.message || String(lastError) : "unknown";
	throw new Error(`WebSocket ${url} did not become ready (${reason})`);
}

interface LspError extends Error {
	code?: string;
}

export async function ensureServerRunning(
	server: LspServerDefinition,
): Promise<string | null> {
	const launcher = server.launcher;
	if (!launcher) return null;

	const installed = await ensureInstalled(server);
	if (!installed) {
		const unavailable: LspError = new Error(
			`Language server ${server.id} is not available.`,
		);
		unavailable.code = "LSP_SERVER_UNAVAILABLE";
		throw unavailable;
	}

	const key = server.id;
	if (managedServers.has(key)) {
		const existing = managedServers.get(key);
		return existing?.uuid ?? null;
	}

	const command = resolveStartCommand(server);
	if (!command) {
		return null;
	}

	try {
		const uuid = await startInteractiveServer(command, key);
		if (
			server.transport?.url &&
			(server.transport.kind === "websocket" ||
				server.transport.kind === "stdio")
		) {
			await waitForWebSocket(server.transport.url);
		}
		if (!announcedServers.has(key)) {
			lspStatusBar.show({
				message: `${server.label} connected`,
				title: server.label || server.id,
				type: "success",
				icon: "check",
				duration: 1500,
			});
			announcedServers.add(key);
		}
		return uuid;
	} catch (error) {
		console.error(`Failed to start language server ${server.id}`, error);
		const errorMessage = error instanceof Error ? error.message : String(error);
		lspStatusBar.show({
			message: errorMessage || "Connection failed",
			title: `${server.label} failed`,
			type: "error",
			icon: "error",
			duration: false,
		});
		const entry = managedServers.get(key);
		if (entry) {
			getExecutor()
				.stop(entry.uuid)
				.catch((err: Error) => {
					console.warn(
						`Failed to stop language server shell ${server.id}`,
						err,
					);
				});
			managedServers.delete(key);
		}
		const unavailable: LspError = new Error(
			`Language server ${server.id} failed to start (${errorMessage})`,
		);
		unavailable.code = "LSP_SERVER_UNAVAILABLE";
		throw unavailable;
	}
}

export function stopManagedServer(serverId: string): void {
	const entry = managedServers.get(serverId);
	if (!entry) return;
	getExecutor()
		.stop(entry.uuid)
		.catch((error: Error) => {
			console.warn(`Failed to stop language server ${serverId}`, error);
		});
	managedServers.delete(serverId);
	announcedServers.delete(serverId);
}

export function resetManagedServers(): void {
	for (const id of Array.from(managedServers.keys())) {
		stopManagedServer(id);
	}
	managedServers.clear();
}
