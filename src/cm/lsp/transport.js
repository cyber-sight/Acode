/*
	Language servers that expose stdio are proxied through a lightweight
	WebSocket bridge so the CodeMirror client can continue to speak WebSocket.
*/

/**
 * @typedef {Object} TransportHandle
 * @property {{ send(message: string): void, subscribe(handler: (value: string) => void): void, unsubscribe(handler: (value: string) => void): void }} transport
 * @property {() => Promise<void> | void} dispose
 * @property {Promise<void>} ready
 */

const DEFAULT_TIMEOUT = 5000;
const RECONNECT_BASE_DELAY = 500;
const RECONNECT_MAX_DELAY = 10000;
const RECONNECT_MAX_ATTEMPTS = 5;

function createWebSocketTransport(server, context) {
	const transport = server.transport;
	if (!transport) {
		throw new Error(
			`LSP server ${server.id} is missing transport configuration`,
		);
	}

	const { url, options = {} } = transport;
	if (!url) {
		throw new Error(`WebSocket transport for ${server.id} is missing a url`);
	}

	const listeners = new Set();
	const binaryMode = !!options.binary;
	const timeout = options.timeout ?? DEFAULT_TIMEOUT;
	const enableReconnect = options.reconnect !== false;
	const maxReconnectAttempts =
		options.maxReconnectAttempts ?? RECONNECT_MAX_ATTEMPTS;

	let socket = null;
	let disposed = false;
	let reconnectAttempts = 0;
	let reconnectTimer = null;
	let connected = false;

	const encoder = binaryMode ? new TextEncoder() : null;

	function createSocket() {
		try {
			// pylsp's websocket endpoint does not require subprotocol negotiation.
			// Avoid passing protocols to keep the handshake simple.
			const ws = new WebSocket(url);
			if (binaryMode) {
				ws.binaryType = "arraybuffer";
			}
			return ws;
		} catch (error) {
			throw new Error(
				`Failed to construct WebSocket for ${server.id} (${url}): ${error?.message || error}`,
			);
		}
	}

	function handleMessage(event) {
		let data;
		if (typeof event.data === "string") {
			data = event.data;
		} else if (event.data instanceof Blob) {
			// Handle Blob synchronously by queuing - avoids async ordering issues
			event.data
				.text()
				.then((text) => {
					dispatchToListeners(text);
				})
				.catch((err) => {
					console.error("Failed to read Blob message", err);
				});
			return;
		} else if (event.data instanceof ArrayBuffer) {
			data = new TextDecoder().decode(event.data);
		} else {
			console.warn(
				"Unknown WebSocket message type",
				typeof event.data,
				event.data,
			);
			data = String(event.data);
		}
		dispatchToListeners(data);
	}

	function dispatchToListeners(data) {
		// Debugging aid while stabilising websocket transport
		if (context?.debugWebSocket) {
			console.debug(`[LSP:${server.id}] <=`, data);
		}
		listeners.forEach((listener) => {
			try {
				listener(data);
			} catch (error) {
				console.error("LSP transport listener failed", error);
			}
		});
	}

	function handleClose(event) {
		connected = false;
		if (disposed) return;

		const wasClean = event.wasClean || event.code === 1000;
		if (wasClean) {
			console.info(`[LSP:${server.id}] WebSocket closed cleanly`);
			return;
		}

		console.warn(
			`[LSP:${server.id}] WebSocket closed unexpectedly (code: ${event.code})`,
		);

		if (enableReconnect && reconnectAttempts < maxReconnectAttempts) {
			scheduleReconnect();
		} else if (reconnectAttempts >= maxReconnectAttempts) {
			console.error(`[LSP:${server.id}] Max reconnection attempts reached`);
		}
	}

	function handleError(event) {
		if (disposed) return;
		const reason = event?.message || event?.type || "connection error";
		console.error(`[LSP:${server.id}] WebSocket error: ${reason}`);
	}

	function scheduleReconnect() {
		if (disposed || reconnectTimer) return;

		const delay = Math.min(
			RECONNECT_BASE_DELAY * Math.pow(2, reconnectAttempts),
			RECONNECT_MAX_DELAY,
		);
		reconnectAttempts++;

		console.info(
			`[LSP:${server.id}] Reconnecting in ${delay}ms (attempt ${reconnectAttempts}/${maxReconnectAttempts})`,
		);

		reconnectTimer = setTimeout(() => {
			reconnectTimer = null;
			if (disposed) return;
			attemptReconnect();
		}, delay);
	}

	function attemptReconnect() {
		if (disposed) return;

		try {
			socket = createSocket();
			setupSocketHandlers(socket);

			socket.onopen = () => {
				connected = true;
				reconnectAttempts = 0;
				console.info(`[LSP:${server.id}] Reconnected successfully`);
				socket.onopen = null;
			};
		} catch (error) {
			console.error(`[LSP:${server.id}] Reconnection failed`, error);
			if (reconnectAttempts < maxReconnectAttempts) {
				scheduleReconnect();
			}
		}
	}

	function setupSocketHandlers(ws) {
		ws.onmessage = handleMessage;
		ws.onclose = handleClose;
		ws.onerror = handleError;
	}

	// Initial socket creation
	socket = createSocket();

	const ready = new Promise((resolve, reject) => {
		const timeoutId = setTimeout(() => {
			socket.onopen = socket.onerror = null;
			try {
				socket.close();
			} catch (_) {}
			reject(new Error(`Timed out opening WebSocket for ${server.id}`));
		}, timeout);

		socket.onopen = () => {
			clearTimeout(timeoutId);
			connected = true;
			setupSocketHandlers(socket);
			resolve();
		};

		socket.onerror = (event) => {
			clearTimeout(timeoutId);
			socket.onopen = socket.onerror = null;
			const reason = event?.message || event?.type || "connection error";
			reject(new Error(`WebSocket error for ${server.id}: ${reason}`));
		};
	});

	const transportInterface = {
		send(message) {
			if (!connected || !socket || socket.readyState !== WebSocket.OPEN) {
				throw new Error("WebSocket transport is not open");
			}
			if (binaryMode) {
				socket.send(encoder.encode(message));
			} else {
				socket.send(message);
			}
		},
		subscribe(handler) {
			listeners.add(handler);
		},
		unsubscribe(handler) {
			listeners.delete(handler);
		},
	};

	const dispose = () => {
		disposed = true;
		connected = false;

		if (reconnectTimer) {
			clearTimeout(reconnectTimer);
			reconnectTimer = null;
		}

		listeners.clear();

		if (socket) {
			if (
				socket.readyState === WebSocket.CLOSED ||
				socket.readyState === WebSocket.CLOSING
			) {
				return;
			}
			try {
				socket.close(1000, "Client disposed");
			} catch (_) {}
		}
	};

	return { transport: transportInterface, dispose, ready };
}

function createStdioTransport(server, context) {
	if (!server.transport) {
		throw new Error(
			`LSP server ${server.id} is missing transport configuration`,
		);
	}
	if (!server.transport.url) {
		throw new Error(
			`STDIO transport for ${server.id} is missing a websocket bridge url`,
		);
	}
	if (!server.transport.options?.binary) {
		console.info(
			`LSP server ${server.id} is using stdio bridge without binary mode. Falling back to text frames.`,
		);
	}
	return createWebSocketTransport(server, context);
}

export function createTransport(server, context = {}) {
	if (!server) {
		throw new Error("createTransport requires a server configuration");
	}
	if (!server.transport) {
		throw new Error(
			`LSP server ${server.id || "unknown"} is missing transport configuration`,
		);
	}

	const kind = server.transport.kind;
	if (!kind) {
		throw new Error(
			`LSP server ${server.id} transport is missing 'kind' property`,
		);
	}

	switch (kind) {
		case "websocket":
			return createWebSocketTransport(server, context);
		case "stdio":
			return createStdioTransport(server, context);
		case "external":
			if (typeof server.transport.create === "function") {
				return server.transport.create(server, context);
			}
			throw new Error(
				`LSP server ${server.id} declares an external transport without a create() factory`,
			);
		default:
			throw new Error(`Unsupported transport kind: ${kind}`);
	}
}

export default { createTransport };
