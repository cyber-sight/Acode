import Url from "utils/Url";

/**
 * CORS-safe fetch for Acode API endpoints.
 *
 * On iOS the WKWebView origin is not allowed by acode.app's CORS policy,
 * so WebView fetch() fails opaquely for EVERY api call. Native requests
 * via cordova-plugin-http bypass CORS entirely. On other platforms this
 * is a thin fetch() passthrough.
 *
 * @param {string} url absolute URL (must start with https://acode.app/api or BASE_URL origin)
 * @param {{method?: string, body?: any, json?: boolean, responseType?: "json"|"arraybuffer"|"text", headers?: Record<string,string>}} [opts]
 * @returns {Promise<any>} parsed body (json object | ArrayBuffer | string)
 */
export default async function apiFetch(url, opts = {}) {
	const {
		method = "get",
		body,
		json = false,
		responseType = json ? "json" : "text",
		headers = {},
	} = opts;

	const sameOriginApi =
		typeof url === "string" &&
		(url.startsWith(`${Url.join(configBase(), "/api")}`) ||
			url.startsWith("https://acode.app/") ||
			url.startsWith("https://api.acode.dev/"));

	const useNative =
		window.cordova?.platformId === "ios" &&
		window.cordova?.plugin?.http &&
		sameOriginApi;

	if (!useNative) {
		const init = { method, headers };
		if (body !== undefined) {
			init.body = json ? JSON.stringify(body) : body;
			if (json)
				init.headers = {
					"Content-Type": "application/json",
					...init.headers,
				};
		}
		const res = await fetch(url, init);
		if (!res.ok) {
			const e = new Error(`HTTP ${res.status}`);
			e.status = res.status;
			throw e;
		}
		if (responseType === "json") return await res.json();
		if (responseType === "arraybuffer") return await res.arrayBuffer();
		return await res.text();
	}

	// native path
	return await new Promise((resolve, reject) => {
		const options = {
			method,
			responseType: responseType === "json" ? "json" : responseType,
		};
		if (headers && Object.keys(headers).length) options.headers = headers;
		let serialized;
		if (body !== undefined) {
			serialized = json ? JSON.stringify(body) : String(body);
			options.data = serialized;
			if (json)
				options.headers = {
					"Content-Type": "application/json",
					...(options.headers || {}),
				};
		}
		cordova.plugin.http.sendRequest(
			url,
			options,
			(response) => {
				const { data } = response;
				if (responseType === "json") {
					if (typeof data === "string") {
						try {
							resolve(JSON.parse(data));
						} catch (e) {
							reject(e);
						}
					} else resolve(data);
					return;
				}
				resolve(data);
			},
			(error) => {
				const e = new Error(
					error?.error || error?.statusText || `HTTP ${error?.status ?? "?"}`,
				);
				e.status = error?.status;
				reject(e);
			},
		);
	});
}

function configBase() {
	try {
		// lazy import cycle avoidance
		// eslint-disable-next-line global-require
		return require("./config").BASE_URL;
	} catch (_) {
		return "https://acode.app";
	}
}
