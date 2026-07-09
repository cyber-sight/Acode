const CORDOVA_FETCH_OPTIONS = [
	"nativeFetch",
	"useNativeFetch",
	"fallbackToNativeFetch",
	"cordovaResponseType",
	"cordovaSerializer",
	"cordovaFollowRedirect",
	"cordovaTimeout",
];

const BODY_METHODS = new Set(["POST", "PUT", "PATCH"]);
const BINARY_EXT_RE =
	/\.(?:avif|bmp|gif|ico|jpe?g|pdf|png|webp|zip)(?:[?#].*)?$/i;

let browserFetch;

export default function installCordovaFetch() {
	if (window.__acodeCordovaFetchInstalled) return;
	if (typeof window.fetch !== "function") return;

	browserFetch = window.fetch.bind(window);
	window.__acodeBrowserFetch = browserFetch;

	window.fetch = cordovaFetch;
	window.__acodeCordovaFetchInstalled = true;
}

async function cordovaFetch(input, init = {}) {
	const request = new Request(input, init);
	const options = normalizeInit(init);

	if (shouldUseBrowserFetch(request, options)) {
		return browserFetch(request);
	}

	try {
		return await sendNativeRequest(request, options);
	} catch (error) {
		if (options.fallbackToNativeFetch) {
			return browserFetch(request);
		}
		throw error;
	}
}

function shouldUseBrowserFetch(request, options) {
	return (
		options.nativeFetch ||
		options.useNativeFetch ||
		!isCordovaHttpReady() ||
		!isHttpUrl(request.url)
	);
}

function isCordovaHttpReady() {
	return typeof cordova !== "undefined" && !!cordova.plugin?.http?.sendRequest;
}

function isHttpUrl(url) {
	const protocol = new URL(url).protocol.toLowerCase();
	return protocol === "http:" || protocol === "https:";
}

function normalizeInit(init = {}) {
	const options = { ...init };
	for (const key of CORDOVA_FETCH_OPTIONS) {
		delete options[key];
	}

	return {
		...options,
		nativeFetch: init.nativeFetch === true,
		useNativeFetch: init.useNativeFetch === true,
		fallbackToNativeFetch: init.fallbackToNativeFetch === true,
		cordovaResponseType: init.cordovaResponseType,
		cordovaSerializer: init.cordovaSerializer,
		cordovaFollowRedirect: init.cordovaFollowRedirect,
		cordovaTimeout: init.cordovaTimeout,
	};
}

function sendNativeRequest(request, options) {
	if (request.signal?.aborted) {
		return Promise.reject(createAbortError());
	}

	return new Promise((resolve, reject) => {
		let requestId = null;
		let settled = false;

		const abort = () => {
			if (settled) return;
			settled = true;
			if (requestId != null && cordova.plugin.http.abort) {
				cordova.plugin.http.abort(requestId, () => {}, () => {});
			}
			reject(createAbortError());
		};

		request.signal?.addEventListener("abort", abort, { once: true });

		buildRequestOptions(request, options)
			.then((nativeOptions) => {
				if (settled) return;
				requestId = cordova.plugin.http.sendRequest(
					request.url,
					nativeOptions,
					(response) => {
						if (settled) return;
						settled = true;
						request.signal?.removeEventListener("abort", abort);
						resolve(toFetchResponse(response, nativeOptions.responseType));
					},
					(response) => {
						if (settled) return;
						settled = true;
						request.signal?.removeEventListener("abort", abort);
						if (response?.status > 0) {
							resolve(toFetchResponse(response, nativeOptions.responseType));
						} else {
							reject(createNetworkError(response));
						}
					},
				);
			})
			.catch((error) => {
				if (settled) return;
				settled = true;
				request.signal?.removeEventListener("abort", abort);
				reject(error);
			});
	});
}

async function buildRequestOptions(request, options) {
	const method = request.method.toUpperCase();
	const headers = headersToObject(request.headers);
	const nativeOptions = {
		method: method.toLowerCase(),
		headers,
		responseType: getResponseType(request, options),
	};

	if (typeof options.cordovaTimeout === "number") {
		nativeOptions.timeout = options.cordovaTimeout;
	}

	if (typeof options.cordovaFollowRedirect === "boolean") {
		nativeOptions.followRedirect = options.cordovaFollowRedirect;
	}

	if (BODY_METHODS.has(method)) {
		const body = await readBody(request);
		if (body !== undefined) {
			nativeOptions.data = body.data;
			nativeOptions.serializer = options.cordovaSerializer || body.serializer;
		}
	}

	return nativeOptions;
}

function headersToObject(headers) {
	const result = {};
	headers.forEach((value, key) => {
		if (key.toLowerCase() === "cookie") return;
		result[key] = value;
	});
	return result;
}

async function readBody(request) {
	const contentType = request.headers.get("content-type") || "";

	if (request.bodyUsed) return undefined;

	if (contentType.includes("application/json")) {
		const text = await request.clone().text();
		if (!text) return undefined;
		try {
			return { data: JSON.parse(text), serializer: "json" };
		} catch (_) {
			return { data: text, serializer: "utf8" };
		}
	}

	if (
		contentType.includes("application/x-www-form-urlencoded") ||
		contentType.startsWith("text/") ||
		contentType.includes("xml")
	) {
		return { data: await request.clone().text(), serializer: "utf8" };
	}

	if (contentType.includes("multipart/form-data")) {
		return { data: await request.clone().formData(), serializer: "multipart" };
	}

	const arrayBuffer = await request.clone().arrayBuffer();
	if (arrayBuffer.byteLength) {
		return { data: arrayBuffer, serializer: "raw" };
	}

	return undefined;
}

function getResponseType(request, options) {
	if (options.cordovaResponseType) return options.cordovaResponseType;

	const accept = request.headers.get("accept") || "";
	if (accept.includes("application/json")) return "text";
	if (accept.includes("image/") || accept.includes("application/octet-stream")) {
		return "blob";
	}
	if (BINARY_EXT_RE.test(request.url)) return "blob";

	return "text";
}

function toFetchResponse(nativeResponse, responseType) {
	const status = nativeResponse.status || 0;
	const body = getResponseBody(nativeResponse, responseType);
	const headers = new Headers(nativeResponse.headers || {});

	return new Response(body, {
		status,
		statusText: String(status),
		headers,
	});
}

function getResponseBody(nativeResponse, responseType) {
	if (nativeResponse.status === 204 || nativeResponse.status === 205) {
		return null;
	}
	if (nativeResponse.data != null) return nativeResponse.data;
	if (nativeResponse.error == null) return null;
	if (responseType === "blob" && nativeResponse.error instanceof Blob) {
		return nativeResponse.error;
	}
	return String(nativeResponse.error);
}

function createNetworkError(response) {
	const message = response?.error || "Cordova native HTTP request failed";
	const error = new TypeError(message);
	error.response = response;
	error.status = response?.status;
	return error;
}

function createAbortError() {
	try {
		return new DOMException("The operation was aborted.", "AbortError");
	} catch (_) {
		const error = new Error("The operation was aborted.");
		error.name = "AbortError";
		return error;
	}
}
