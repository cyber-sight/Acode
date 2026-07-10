import fsOperation from "fileSystem";
import Url from "utils/Url";

const INSTALL_STATE_STORAGE = Url.join(DATA_STORAGE, ".install-state");
const NATIVE_CHECKSUM_TIMEOUT_MS = 1500;

export default class InstallState {
	/** @type Record<string, string> */
	store;
	/** @type Record<string, string> */
	updatedStore;

	/**
	 *
	 * @param {string} id
	 * @returns
	 */
	static async new(id) {
		try {
			const state = new InstallState();
			state.id = await checksumText(id);
			state.updatedStore = {};

			if (!(await fsOperation(INSTALL_STATE_STORAGE).exists())) {
				await fsOperation(DATA_STORAGE).createDirectory(".install-state");
			}

			state.storeUrl = Url.join(INSTALL_STATE_STORAGE, state.id);
			if (await fsOperation(state.storeUrl).exists()) {
				let raw = "{}";
				try {
					raw = await fsOperation(state.storeUrl).readFile("utf-8");
					state.store = JSON.parse(raw);
				} catch (err) {
					// Delete corrupted state file to avoid parse errors such as 'Unexpected end of JSON'
					state.store = {};
					try {
						await fsOperation(state.storeUrl).delete();
						// Recreate a fresh empty file to keep invariant
						await fsOperation(INSTALL_STATE_STORAGE).createFile(state.id);
					} catch (writeErr) {
						console.error(
							"InstallState: Failed to recreate state file:",
							writeErr,
						);
					}
				}

				const patchedStore = {};
				for (const [key, value] of Object.entries(state.store)) {
					patchedStore[key.toLowerCase()] = value;
				}

				state.store = patchedStore;
			} else {
				state.store = {};
				await fsOperation(INSTALL_STATE_STORAGE).createFile(state.id);
			}

			return state;
		} catch (e) {
			throw e;
		}
	}

	/**
	 *
	 * @param {string} url
	 * @param {ArrayBuffer | string} content
	 * @param {boolean} isString
	 * @returns
	 */
	async isUpdated(url, content) {
		url = url.toLowerCase();
		const current = this.store[url];
		const update =
			typeof content === "string"
				? await checksumText(content)
				: await checksum(content);
		this.updatedStore[url] = update;
		return current !== update;
	}

	/**
	 *
	 * @param {string} url
	 * @returns
	 */
	exists(url) {
		return typeof this.store[url.toLowerCase()] !== "undefined";
	}

	async save() {
		this.store = this.updatedStore;
		await fsOperation(this.storeUrl).writeFile(
			JSON.stringify(this.updatedStore),
		);
	}

	async delete(url) {
		url = url.toLowerCase();
		if (await fsOperation(url).exists()) {
			await fsOperation(url).delete();
		}
	}

	async clear() {
		try {
			this.store = {};
			this.updatedStore = {};
			// Delete the state file entirely to avoid corrupted/partial JSON issues
			if (await fsOperation(this.storeUrl).exists()) {
				try {
					await fsOperation(this.storeUrl).delete();
				} catch (delErr) {
					// As a fallback, overwrite with a valid empty JSON
					await fsOperation(this.storeUrl).writeFile("{}");
				}
			}
		} catch (error) {
			console.error("Failed to clear install state:", error);
		}
	}
}

/**
 * Derives the checksum of a Buffer
 * @param {BufferSource} data
 * @returns the derived checksum
 */
async function checksum(data) {
	const hashBuffer = await window.crypto.subtle.digest("SHA-256", data);
	const hashArray = Array.from(new Uint8Array(hashBuffer));
	const hashHex = hashArray
		.map((byte) => byte.toString(16).padStart(2, "0"))
		.join("");
	return hashHex;
}

/**
 *
 * @param {string} text
 * @returns
 */
async function checksumText(text) {
	if (typeof cordova === "undefined" || cordova.platformId === "ios") {
		return checksumTextInJs(text);
	}

	return new Promise((resolve, reject) => {
		let settled = false;
		const timeout = setTimeout(async () => {
			if (settled) return;
			settled = true;
			try {
				resolve(await checksumTextInJs(text));
			} catch (error) {
				reject(error);
			}
		}, NATIVE_CHECKSUM_TIMEOUT_MS);

		cordova.exec(
			(hash) => {
				if (settled) return;
				settled = true;
				clearTimeout(timeout);
				resolve(hash);
			},
			async (error) => {
				if (settled) return;
				settled = true;
				clearTimeout(timeout);
				try {
					resolve(await checksumTextInJs(text));
				} catch (fallbackError) {
					reject(fallbackError);
				}
			},
			"System",
			"checksumText",
			[text],
		);
	});
}

async function checksumTextInJs(text) {
	return checksum(new TextEncoder().encode(text || ""));
}
