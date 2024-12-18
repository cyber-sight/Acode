import "styles/lsclient.scss";

import settingsPage from "components/settingsPage";
import { addCustomSettings } from "settings/mainSettings";

import {
	ReconnectingWebSocket,
	formatUrl,
	unFormatUrl,
	getCodeLens,
} from "./utils";

import * as converters from "./ace-linters/type-converters/lsp-converters";
import {
	fromPoint,
	fromRange,
	toRange,
} from "./ace-linters/type-converters/lsp-converters";
import { BaseService } from "./ace-linters/services/base-service";
import { LanguageClient } from "./ace-linters/services/language-client";

import appSettings from "lib/settings";

window.exports = {};

const commandId = "acodeLsExecuteCodeLens";
const HAS_BUILTIN_CLIENT = [
	"html",
	"css",
	"scss",
	"less",
	"lua",
	"xml",
	"yaml",
	"json",
	"json5",
	"javascript",
	"typescript",
	"jsx",
	"tsx",
	"php",
	// "python",
];

const BUILTIN_OPTIONS = {
	javascript: {
		// features: { signatureHelp: true },
		className: "TypescriptService",
		module: () =>
			import("./ace-linters/services/typescript/typescript-service"),
	},
	typescript: {
		// features: { signatureHelp: true },
		className: "TypescriptService",
		module: () =>
			import("./ace-linters/services/typescript/typescript-service"),
	},
	jsx: {
		// features: { signatureHelp: true },
		className: "TypescriptService",
		module: () =>
			import("./ace-linters/services/typescript/typescript-service"),
	},
	tsx: {
		// features: { signatureHelp: true },
		className: "TypescriptService",
		module: () =>
			import("./ace-linters/services/typescript/typescript-service"),
	},
	html: {
		features: { signatureHelp: false },
		className: "HtmlService",
		module: () => import("./ace-linters/services/html/html-service"),
	},
	css: {
		features: { signatureHelp: false },
		className: "CssService",
		module: () => import("./ace-linters/services/css/css-service"),
	},
	less: {
		features: { signatureHelp: false },
		className: "CssService",
		module: () => import("./ace-linters/services/css/css-service"),
	},
	scss: {
		features: { signatureHelp: false },
		className: "CssService",
		module: () => import("./ace-linters/services/css/css-service"),
	},
	json: {
		features: { signatureHelp: false, documentHighlight: false },
		className: "JsonService",
		module: () => import("./ace-linters/services/json/json-service"),
	},
	json5: {
		features: { signatureHelp: false, documentHighlight: false },
		className: "JsonService",
		module: () => import("./ace-linters/services/json/json-service"),
	},
	yaml: {
		features: { signatureHelp: false, documentHighlight: false },
		className: "YamlService",
		module: () => import("./ace-linters/services/yaml/yaml-service"),
	},
	lua: {
		features: { signatureHelp: false, documentHighlight: false },
		className: "LuaService",
		module: () => import("./ace-linters/services/lua/lua-service"),
	},
	php: {
		features: { signatureHelp: false, documentHighlight: false },
		className: "PhpService",
		module: () => import("./ace-linters/services/php/php-service"),
	},
	// python: {
	//   features: { signatureHelp: false, documentHighlight: false },
	//   className: "PythonService",
	//   module: () => import("./ace-linters/services/python/python-service"),
	// },
};

const SERVER_OPTIONS = {
	typescript: {
		format: ["js", "jsx", "ts", "tsx"],
		modes: "typescript|javascript|tsx|jsx",
	},
	c_cpp: {
		format: ["cpp", "c", "cc", "cxx", "h", "hh", "hpp", "ino"],
	},
	dart: {
		format: ["dart"],
	},
	svelte: {
		format: ["svelte"],
	},
	vue: {
		format: ["vue"],
	},
	rust: {
		format: ["rust"],
	},
	python: {
		format: ["py"],
	},
	php: {
		format: ["php"],
	},
	lua: {
		format: ["lua"],
	},
	go: {
		format: ["go"],
	},
	java: {
		format: ["java"],
	},
};

class CustomService extends BaseService {
	constructor(...args) {
		super(...args);
		this.$handlers = {};
	}

	async doComplete(document, position) {
		let handlers = this.$handlers["completion"];
		let allCompletions = [];
		if (handlers) {
			for (let handler of handlers) {
				let completions = await handler.bind(this)(document, position);
				if (completions) {
					completions.map((item) => allCompletions.push(item));
				}
			}
		}
		return allCompletions;
	}

	async doValidation(document) {
		let handlers = this.$handlers["validation"];
		let allValidations = [];
		if (handlers) {
			for (let handler of handlers) {
				let completions = await handler.bind(this)(document);
				if (completions) {
					completions.map((item) => allValidations.push(item));
				}
			}
		}
		return allValidations;
	}

	async doHover(document) {
		let handlers = this.$handlers["hover"];
		if (handlers) {
			let allHovers = [];
			for (let handler of handlers) {
				let completions = await handler.bind(this)(document);
				if (completions) {
					completions.map((item) => allHovers.push(item));
				}
			}
		}
		return allHovers;
	}

	async doCodeLens() {
		let handlers = this.$handlers["codeLens"];
		let allCodeLens = [];
		if (handlers) {
			for (let handler of handlers) {
				let completions = await handler.bind(this)();
				if (completions) {
					completions.map((item) => {
						item.command && (iten.command.id = commandId);
						allCodeLens.push(item);
					});
				}
			}
		}
		return allCodeLens;
	}

	addHandler(target, handler) {
		(this.$handlers[target] ??= []).push(handler);
		return handler;
	}
}

/**
 * @param {string} mode
 * @returns {CustomService}
 */
function get(mode) {
	return (s[mode] ??= new CustomService(mode));
}

const wrap = (mode, callback) => {
	return async (...args) => {
		let activeMode = editorManager.editor.session.$modeId.substring(9);
		if (mode.split("|").includes(activeMode)) {
			return await callback(...args);
		}
		return [];
	};
};

const defaultService = new CustomService("any");

export class LanguageClientService {
	#client;
	#manager;
	#servers;
	#folders;
	#completers;
	#providerTarget;

	async init() {
		const { LanguageProvider, MessageController } = await import(
			"./ace-linters"
		);

		const { ServiceManager } = await import(
			"./ace-linters/services/service-manager"
		);

		const serviceTarget = new EventTarget();
		this.#providerTarget = new EventTarget();

		this.#manager = new ServiceManager({
			addEventListener: (...args) =>
				this.#providerTarget.addEventListener(...args),
			postMessage: (message) =>
				serviceTarget.dispatchEvent(
					new MessageEvent("message", { data: message }),
				),
			dispatchEvent: (event, data) =>
				this.#providerTarget.dispatchEvent(
					new CustomEvent(event, { detail: data }),
				),
		});

		this.#client = LanguageProvider.create({
			addEventListener: (...args) => serviceTarget.addEventListener(...args),
			postMessage: (message) => {
				this.#providerTarget.dispatchEvent(
					new MessageEvent("message", { data: message }),
				);
			},
		});

		this.#setup();

		const exports = {
			BaseService,
			LanguageClient,
			LanguageProvider,
			MessageController,
			ReconnectingWebSocket,

			utils: { converters },

			setupLangaugeClient: (name, { command, args, config, modes, format }) => {
				let client = new LanguageClient({
					type: "stdio",
					args: args || [],
					command,
				});

				exports.registerService(modes, client, config || {});

				format &&
					acode.registerFormatter(name + " Language Client", format, () =>
						this.#client.format(),
					);
			},

			format: () => this.#client.format(),
			dispatchEvent: (name, data) =>
				this.#providerTarget.dispatchEvent(
					new CustomEvent(name, { detail: data }),
				),

			registerService: (mode, client, options) => {
				if (Array.isArray(mode)) {
					mode = mode.join("|");
				}

				if (client instanceof BaseService || client instanceof LanguageClient) {
					options = options || {};
					client.ctx = this.#manager.ctx;

					client.serviceData.modes = mode;
					client.serviceData.options = options;
					client.serviceData.rootUri = () => this.#getRootUri();
					client.serviceData.workspaceFolders = () => this.#getFolders();

					this.#manager.registerService(options.alias || mode.split("|")[0], {
						options: options,
						serviceInstance: client,
						rootUri: () => this.#getRootUri(),
						workspaceFolders: () => this.#getFolders(),
						modes: mode,
						features: (client.serviceData.features =
							this.#setDefaultFeaturesState(client.serviceData.features || {})),
					});

					if (client instanceof LanguageClient) {
						client.enqueueIfNotConnected(() => {
							client.connection.onNotification(
								"$/typescriptVersion",
								(params) => {
									let serverInfo = {
										name: "typescript",
										version: params.version,
									};
									this.#setServerInfo(mode, serverInfo);
								},
							);
						});
					}

					this.#client.setGlobalOptions(mode, options);
				} else {
					throw new Error("Invalid client.");
				}
			},
			registerEditor: (editor) => {
				this.#client.registerEditor(editor);
			},

			getSocket: (url) => {
				if (url.startsWith("server") || url.startsWith("auto")) {
					return new ReconnectingWebSocket(
						this.settings.url + url,
						null,
						false,
						true,
						this.settings.reconnectDelay,
						this.settings.closeTimeout,
					);
				}
				throw new Error(
					"Invalid url. Use ReconnectingWebSocket directly instead.",
				);
			},
			getSocketForCommand: (command, args = []) => {
				let url =
					"auto/" +
					encodeURIComponent(command) +
					"?args=" +
					JSON.stringify(args);
				return new ReconnectingWebSocket(
					this.settings.url + url,
					null,
					false,
					true,
					this.settings.reconnectDelay,
					this.settings.closeTimeout,
				);
			},

			provideHover(mode, callback) {
				return defaultService.addHandler("hover", wrap(mode, callback));
			},
			provideCodeLens(mode, callback) {
				return defaultService.addHandler("codeLens", wrap(mode, callback));
			},
			provideCompletion(mode, callback) {
				return defaultService.addHandler("completion", wrap(mode, callback));
			},
			provideCodeAction(mode, callback) {
				return defaultService.addHandler("codeAction", wrap(mode, callback));
			},
			provideValidation(mode, callback) {
				return defaultService.addHandler("validation", wrap(mode, callback));
			},
		};

		acode.define("language-client", exports);

		for (const [mode, server] of Object.entries(this.settings.servers)) {
      console.log(mode, server)
			if (server.enabled) {
				if (server.builtin) {
					this.#manager.registerService(mode, {
						modes: mode,
						...BUILTIN_OPTIONS[mode],
						rootUri: () => this.#getRootUri(),
						workspaceFolders: () => this.#getFolders(),
					});
				} else {
					exports.setupLangaugeClient(mode, {
						modes: mode,
						command: server.command,
						args: server.args.split(" "),
						config: server.config,
						...(SERVER_OPTIONS[mode] || {}),
					});
				}
			}
		}

		if (this.settings.enabled) {
		}
		this.#client.registerEditor(editorManager.editor);
	}

	async #startServer() {
		const pty = acode.require("pty");

		if (!pty || pty.host.isPtyAvailable()) {
			return alert("PtyError", "Pty is not available or unsupported");
		}

		let commandPath = await pty.host.getCommandPath("acode-ls");
		if (!commandPath) {
			const confirmation = acode.require("confirm")(
				"Server not found",
				"Do you want to install it?",
			);
			if (!confirmation) {
				return;
			}

			let installLoader = acode
				.require("loader")
				.create(
					"Installing acode language server",
					`Running 'npm install -g acode-lsp'`,
				);
			installLoader.show();

			try {
				await pty.run("npm", ["install", "-g", "acode-lsp"], {
					background: false,
					sessionAction: 0,
				});
				installLoader.setMessage("Server sucessfully installed");
			} catch (error) {
				alert("PtyError", "Server install failed. Try manually in termux.");
				console.error(error?.toString?.() || error);
			} finally {
				setTimeout(() => installLoader.destroy(), 2000);
			}
		}

		await pty.host.run({
			command: "acode-ls",
			type: "process",
			background: true,
		});
	}

	#setup() {
		if (window.acode && this.settings.format) {
			acode.registerFormatter(
				"Acode",
				["html", "css", "scss", "less", "lua", "xml", "yaml", "json", "json5"],
				() => this.#client.format(),
			);
		}

		this.#client.setGlobalOptions("", {
			...(this.settings.options?.global || {}),
		});

		this.#setupCommands();

		if (this.settings.codelens) {
			this.#setupCodelens(editorManager.editor);
		}

		this.#setupAcodeEvents();
		this.#registerEditor(editorManager.editor);

		if (this.settings.replaceCompleters) {
			this.#completers = editorManager.editor.completers.splice(1, 2);
		}

		const { list, cb } = this.#settingsObj;
		addCustomSettings(
			{
				key: "languageclient-settings",
				text: strings["languageclient"] || "Language Client",
				index: 2,
				icon: "code",
			},
			settingsPage("Language Client", list, cb, [
				toggleLanguageClientButton(this.settings.enabled, (value) =>
					cb("enabled", value),
				),
			]),
		);

		function toggleLanguageClientButton(enabled, callback) {
			const pauseButton = (
				<span className="icon pause" attr-action="pause-languageclient"></span>
			);
			pauseButton.addEventListener("click", () => {
				callback(false);
				pauseButton.replaceWith(playButton);
			});

			const playButton = (
				<span
					className="icon play_arrow"
					attr-action="start-languageclient"
				></span>
			);
			playButton.addEventListener("click", () => {
				callback(true);
				playButton.replaceWith(pauseButton);
			});

			return enabled ? pauseButton : playButton;
		}

		this.#providerTarget.addEventListener("initialized", ({ detail }) => {
			let mode =
				detail.lsp.serviceData.options?.alias ||
				detail.lsp.serviceData.modes.split("|")[0];

			if (!detail.params.serverInfo) return;

			this.#setServerInfo(mode, detail.params.serverInfo);
		});

		// let titles = new Map();
		this.#providerTarget.addEventListener("progress", ({ detail }) => {
			// let progress = this.#getProgress(detail.token);
			// if (progress) {
			//   if (detail.value.kind === "begin") {
			//     titles.set(detail.token, detail.title);
			//   } else if (detail.value.kind === "report") {
			//     progress.show();
			//   } else if (detail.value.kind === "end") {
			//     titles.delete(detail.token);
			//     return progress.remove();
			//   }
			//   progress.setTitle(titles.get(detail.token));
			//   if (detail.value.message) {
			//     let percentage = detail.value.percentage;
			//     progress.setMessage(
			//       detail.value.message +
			//       (percentage ? " <br/>(" + String(percentage) + "%)" : "")
			//     );
			//   }
			// }
		});

		this.#providerTarget.addEventListener(
			"create/progress",
			({ detail }) => {},
		);
		this.#providerTarget.addEventListener("initialized", ({ detail }) => {});
	}

	#languageServersSettings() {
		const title = strings["language servers"] || "Langauge Servers";
		const values = appSettings.value;
		const { modes } = ace.require("ace/ext/modelist");

		if (!this.settings.servers) {
			values["languageclient"].servers = this.settings.servers = {};
			appSettings.update();
		}

		const items = modes.map((mode) => {
			const { name, caption } = mode;
			const server = appSettings.value["languageClient"].servers[name] || {
				command: "",
				args: "",
				formatter: true,
				enabled: true,
				builtin: HAS_BUILTIN_CLIENT.includes(name),
			};

			return {
				key: name,
				text: caption,
				icon: `file file_type_default file_type_${name}`,
				value: `${server.command} ${server.args}`,
			};
		});

		settingsPage(title, items, (key) =>
			this.#languageServerSettings(modes.find((mode) => mode.name === key)),
		).show();
	}

	#languageServerSettings({ name, caption }) {
		const title = `${
			caption[0].toUpperCase() + caption.slice(1)
		} Language Server`;
		const hasBuiltIn = HAS_BUILTIN_CLIENT.includes(name);

		const server = appSettings.value["languageClient"].servers[name] || {
			command: "",
			args: "",
			config: {},
			formatter: true,
			enabled: true,
			builtin: hasBuiltIn,
		};

		const items = [
			{
				index: 0,
				key: "enabled",
				text: "Enable Language Client",
				checkbox: !!server.enabled,
			},
			{
				index: 1,
				key: "serverPath",
				text: "Server Command",
				value: `${server.command} ${server.args}`,
				prompt: "Server Command",
			},
			{
				index: 2,
				key: "formatter",
				text: "Register Formatter",
				checkbox: !!server.formatter,
			},
		];

		hasBuiltIn &&
			items.push({
				index: 3,
				key: "builtin",
				text: "Use Builtin Language Server",
				checkbox: !!server.builtin,
			});

		const callback = (key, value) => {
			switch (key) {
				case "serverPath":
					const [command, ...extra] = value.trim().split(" ");
					value = { ...server, command, args: extra.join(" ") };
					break;
				case "formatter":
					value = { ...server, formatter: !!value };
					break;
				default:
					value = { ...server, [key]: value };
					break;
			}
			appSettings.value["languageClient"].servers[name] = value;
			appSettings.update();
		};
		settingsPage(title, items, callback).show();
	}

	#setServerInfo(mode, { name, version }) {}

	#setDefaultFeaturesState(serviceFeatures) {
		let features = serviceFeatures ?? {};
		features.hover ??= true;
		features.completion ??= true;
		features.completionResolve ??= true;
		features.format ??= true;
		features.diagnostics ??= true;
		features.signatureHelp ??= true;
		features.documentHighlight ??= true;
		return features;
	}

	#log(message, type = "debug") {
		window.log(type, message);
	}

	destroy() {}

	async #openFile(uri, range) {
		uri = decodeURIComponent(uri);

		let url = acode.require("url");
		let helpers = acode.require("helpers");
		let file = acode.require("editorfile");
		let filename = url.basename(uri);

		uri = unFormatUrl(uri);

		let activeFile = editorManager.getFile(uri, "uri");

		if (!activeFile) {
			activeFile = new file(filename, { uri });
			let promise = new Promise((cb) => activeFile.on("loadend", cb));
			await promise;
		}

		activeFile.makeActive();
		if (range) {
			let cursor = toRange(range);
			activeFile.session.selection.moveCursorTo(
				cursor.start.row,
				cursor.start.column,
			);
			editorManager.editor.focus();
		}
		return activeFile;
	}

	#applyEdits(fileEdits, session) {
		for (let edit of fileEdits.reverse()) {
			session.replace(toRange(edit.range), edit.newText);
		}
	}

	#getRootUri() {
		if (editorManager.activeFile?.uri) {
			let openfolder = acode.require("openfolder");
			let folder = openfolder.find(editorManager.activeFile.uri);
			if (folder?.url) {
				return "file://" + formatUrl(folder.url, false);
			}
		}

		// if (this.#rootUri) return this.#rootUri;

		let folders = this.#getFolders();

		if (folders?.length) {
			return folders[0].url;
		} else {
			return null;
		}
		return null;
	}

	get workspaceFolders() {
		return this.#getFolders();
	}

	#getFolders() {
		const folders = JSON.parse(localStorage.folders || "[]");
		if (!window.acode && !folders.length) {
			return null;
		}

		this.#folders = folders.map((item) => ({
			name: item.opts.name,
			uri: "file://" + formatUrl(item.url, false),
			url: "file://" + formatUrl(item.url, false),
		}));
		return this.#folders;
	}

	#getServices(session) {
		return this.#manager.findServicesByMode(
			(session || editorManager.editor.session).$modeId.substring(9),
		);
	}

	#filterService(validate, services) {
		services = services || this.#getServices();
		return services.filter((service) => {
			let instance = service.serviceInstance;
			if (!instance) return false;

			let capabilities = instance.serviceCapabilities;
			if (validate(capabilities)) {
				return true;
			}
			return false;
		});
	}

	#registerEditor(editor) {
		this.#client.registerEditor(editor);
		editor.on("focus", () => {
			if (this.$mainNode?.classList.contains("visible")) {
				this.$mainNode?.classList.remove("visible");
			}
			if (this.$currentRange !== undefined) {
				editor.session.removeMarker(this.$currentRange);
			}
		});
	}

	#setupAcodeEvents() {
		if (!window.acode) return;

		editorManager.on("remove-file", (file) => {
			if (!file.session) return;
			let services = this.#getServices(file.session);
			try {
				services.map((service) => {
					service.serviceInstance?.removeDocument({
						uri: this.#client.$getFileName(file.session),
					});
				});
			} catch (e) {
				console.error(e);
			}
		});

		editorManager.on("rename-file", (file) => {
			let services = this.#getServices(file.session);
			try {
				services.map((service) => {
					service.serviceInstance?.removeDocument({
						uri: this.#client.$getFileName(file.session),
					});
				});
			} catch (e) {
				console.error(e);
			}

			this.#client.$registerSession(file.session, editorManager.editor);
		});

		editorManager.on("remove-folder", (folder) => {
			let allServices = Object.values(this.#manager.$services);
			let services = this.#filterService((capabilities) => {
				return capabilities.workspace?.workspaceFolders?.changeNotifications;
			}, allServices);
			try {
				services.map((service) => {
					service.serviceInstance.connection.sendRequest(
						"workspace/didChangeWorkspaceFolders",
						{
							event: {
								added: [],
								removed: [
									{
										name: folder.opts?.name,
										uri: "file://" + formatUrl(folder.url, false),
										url: "file://" + formatUrl(folder.url, false),
									},
								],
							},
						},
					);
				});
			} catch (e) {
				console.error(e);
			}
		});

		editorManager.on("add-folder", (folder) => {
			let allServices = Object.values(this.#manager.$services);
			let services = this.#filterService((capabilities) => {
				return capabilities.workspace?.workspaceFolders?.changeNotifications;
			}, allServices);
			try {
				services.map((service) => {
					service.serviceInstance.connection.sendRequest(
						"workspace/didChangeWorkspaceFolders",
						{
							event: {
								removed: [],
								added: [
									{
										name: folder.opts?.name,
										uri: "file://" + formatUrl(folder.url, false),
										url: "file://" + formatUrl(folder.url, false),
									},
								],
							},
						},
					);
				});
			} catch (e) {
				console.error(e);
			}
		});
	}

	#setupCodelens(editor) {
		return new Promise((resolve, reject) => {
			getCodeLens((codeLens) => {
				if (!codeLens) return reject("CodeLens not available.");

				editor.commands.addCommand({
					name: commandId,
					exec: (editor, args) => {
						console.log("Executing:", args);
						let item = args[0];
						if (item.exec) {
							item.exec();
						}
					},
				});

				editor.commands.addCommand({
					name: "acodeLsClearCodeLenses",
					exec: (editor, args) => {
						codeLens.clear(editor.session);
					},
				});
				editor.setOption("enableCodeLens", true);

				codeLens.registerCodeLensProvider(editor, {
					provideCodeLenses: async (session, callback) => {
						let services = this.#filterService(
							(capabilities) => capabilities.codeLensProvider,
						).map((service) => service.serviceInstance);
						let uri = this.#client.$getFileName(editor.session);
						let result = [...(await defaultService.doCodeLens())];

						let promises = services.map(async (service) => {
							if (service.connection) {
								let response = await service.connection.sendRequest(
									"textDocument/codeLens",
									{ textDocument: { uri } },
								);
								// console.log("CodeLens:", response);
								if (!response) return;
								for (let item of response) {
									if (!item.command && !item.data) continue;

									result.push({
										...toRange(item.range),
										command: {
											id: commandId,
											title:
												item.command?.tooltip ||
												item.command?.title ||
												(item.data || [])[2] ||
												"Unknown Action",
											arguments: [item],
										},
									});
								}
							} else {
								let response = await service.doCodeLens?.({ uri });
								if (response) {
									response.map((i) => result.push(i));
								}
							}
						});
						await Promise.all(promises);

						callback(null, result);
					},
				});
				resolve(codeLens);
			});
		});
	}

	#showReferences(references) {}

	#setupCommands() {
		let commands = [
			{
				name: "Go To Declaration",
				exec: () => this.#goToDeclaration(),
			},
			{
				name: "Go To Definition",
				exec: () => this.#goToDefinition(),
			},
			{
				name: "Go To Type Definition",
				exec: () => this.#goToDefinition(true),
			},
			{
				name: "Go To Implementations",
				exec: () => this.#findImplementations(),
			},
			{
				name: "Show References",
				exec: () => this.#findReferences(),
			},
			{
				name: "Show Code Actions",
				exec: () => this.#codeActions(),
			},
			{
				name: "Rename Symbol",
				exec: () => this.#renameSymbol(),
			},
			{
				name: "Format Code",
				exec: () => this.#client.format(),
			},
		];

		let selection = window.acode?.require("selectionMenu");
		selection?.add(
			async () => {
				let action = await acode.select(
					"Select Action",
					commands.map((command, index) => [index, command.name]),
				);
				if (action) {
					return commands[action]?.exec();
				}
			},
			tag("span", {
				className: "icon edit",
			}),
			"all",
			false,
		);

		editorManager.editor.commands.addCommands(commands);
		// EditorManager.on("create", ({ editor }) => {
		//   editor.commands.addCommands(commands);
		// });
	}

	#goToDefinition(type = false) {
		let services = this.#filterService((capabilities) => {
			if (type) return capabilities.typeDefinitionProvider;
			return capabilities.definitionProvider;
		}).map((service) => service.serviceInstance);
		let cursor = editorManager.editor.getCursorPosition();
		let position = fromPoint(cursor);

		services.map((service) => {
			if (service.connection) {
				service.connection
					.sendRequest(
						"textDocument/" + (type ? "typeDefinition" : "definition"),
						{
							textDocument: {
								uri: this.#client.$getFileName(editorManager.editor.session),
							},
							position,
						},
					)
					.then((response) => {
						window.log("debug", `Definition: ${response}`);
						if (response) {
							if (!Array.isArray(response)) {
								response = [response];
							}

							response.map((item) => {
								this.#openFile(item.uri, item.range);
							});
						}
					});
			}
		});
	}

	#goToDeclaration() {
		let services = this.#filterService(
			(capabilities) => capabilities.declarationProvider,
		).map((service) => service.serviceInstance);
		let cursor = editorManager.editor.getCursorPosition();
		let position = fromPoint(cursor);

		services.map(async (service) => {
			if (service.connection) {
				service.connection
					.sendRequest("textDocument/declaration", {
						textDocument: {
							uri: this.#client.$getFileName(editorManager.editor.session),
						},
						position,
					})
					.then((response) => {
						window.log("debug", `Declaration: ${response}`);
						if (!Array.isArray(response)) {
							response = [response];
						}

						response.map((item) => {
							this.#openFile(item.uri, item.range);
						});
					});
			} else {
				let response = await service.findCodeLens?.({ uri });
				if (response) {
					response.map((item) => {
						this.#openFile(item.uri, item.range);
					});
				}
			}
		});
	}

	#findReferences() {
		let services = this.#filterService(
			(capabilities) => capabilities.referencesProvider,
		).map((service) => service.serviceInstance);
		let cursor = editorManager.editor.getCursorPosition();
		let position = fromPoint(cursor);

		services.map(async (service) => {
			if (service.connection) {
				service.connection
					.sendRequest("textDocument/references", {
						textDocument: {
							uri: this.#client.$getFileName(editorManager.editor.session),
						},
						position,
						context: { includeDeclaration: true },
					})
					.then((response) => {
						window.log("debug", `References: ${response}`);
						if (!Array.isArray(response)) {
							response = [response];
						}
						this.#showReferences(response);

						// response.map((item) => {
						// this.#openFile(item.uri, item.range);
						// });
					});
			} else {
				let response = await service.findReferences?.({ uri }, position);
				if (response) {
					this.#showReferences(response);
				}
			}
		});
	}

	#findImplementations() {
		let services = this.#filterService(
			(capabilities) => capabilities.implementationProvider,
		).map((service) => service.serviceInstance);
		let cursor = editorManager.editor.getCursorPosition();
		let position = fromPoint(cursor);

		services.map(async (service) => {
			if (service.connection) {
				service.connection
					.sendRequest("textDocument/implementation", {
						textDocument: {
							uri: this.#client.$getFileName(editorManager.editor.session),
						},
						position,
					})
					.then((response) => {
						window.log("debug", `Implementation: ${response}`);
						if (!Array.isArray(response)) {
							response = [response];
						}

						response.map((item) => {
							this.#openFile(item.uri, item.range);
						});
					});
			} else if (service.findImplememtations) {
				let response = await service.findImplememtations({ uri }, position);
				if (response) {
					response.map((i) => result.push(i));
				}
			}
		});
	}

	#codeActions() {
		let services = this.#filterService(
			(capabilities) => capabilities.codeActionProvider,
		).map((service) => service.serviceInstance);
		let cursor = editorManager.editor.getCursorPosition();
		let position = fromPoint(cursor);
		let range = fromRange(editorManager.editor.selection.getRange());

		services.map((service) => {
			if (service.connection) {
				service.connection
					.sendRequest("textDocument/codeAction", {
						textDocument: {
							uri: this.#client.$getFileName(editorManager.editor.session),
						},
						range,
						context: {
							diagnostics: [],
						},
						triggerKind: 2,
					})
					.then(async (actions) => {
						window.log("debug", `Actions: ${actions}`);
						if (!window.acode) return;

						if (actions?.length) {
							let action = await acode.select(
								"Code Action",
								actions.map((action, index) => [index, action.title]),
							);
							if (action) {
								service.connection
									.sendRequest("codeAction/resolve", actions[action])
									.then((resolved) => {
										console.log("Resolved:", resolved);
									});
							}
						}
					});
			}
		});
	}

	async #renameSymbol() {
		let services = this.#filterService(
			(capabilities) => capabilities.renameProvider,
		).map((service) => service.serviceInstance);

		let cursor = editorManager.editor.getCursorPosition();
		let position = fromPoint(cursor);

		let currentName = editorManager.editor.getSelectedText();
		let newName = await (window.acode?.prompt || prompt)(
			"New name",
			currentName,
		);

		services.map((service) => {
			if (service.connection) {
				service.connection
					.sendRequest("textDocument/rename", {
						textDocument: {
							uri: this.#client.$getFileName(editorManager.editor.session),
						},
						newName,
						position,
					})
					.then(async (response) => {
						window.log("debug", `Rename: ${response}`);
						let changes = response.changes || response.documentChanges;
						if (Array.isArray(changes)) {
							for (let change of changes) {
								let efile = await this.#openFile(change.textDocument.uri);
								this.#applyEdits(changes.edits, efile.session);
							}
						} else {
							for (let file in changes) {
								// console.log(file, changes[file])
								let efile = await this.#openFile(file);
								this.#applyEdits(changes[file], efile.session);
							}
						}
					});
			}
		});
	}

	async getDocumentSymbols() {
		let services = this.#filterService(
			(capabilities) => capabilities.documentSymbolProvider,
		);

		if (!services.length) return [];

		try {
			if (services[0].serviceInstance instanceof LanguageClient) {
				return await services[0].serviceInstance.connection.sendRequest(
					"textDocument/documentSymbol",
					{
						textDocument: {
							uri: this.#client.$getFileName(editorManager.editor.session),
						},
					},
				);
			} else {
				return services[0].serviceInstance.findDocumentSymbols({
					uri: this.#client.$getFileName(editorManager.editor.session),
				});
			}
		} catch (e) {
			console.error(e);
		}
	}

	getDefaultValue(settingValue, defaultValue = true) {
		if (typeof settingValue === "undefined") {
			return defaultValue;
		}
		return settingValue;
	}

	get settings() {
		if (!window.acode) {
			return this.#defaultSettings;
		}

		let value = appSettings.value["languageClient"];
		if (!value) {
			value = appSettings.value["languageClient"] = this.#defaultSettings;
			appSettings.update();
		}
		return value;
	}

	get #defaultSettings() {
		const DEFAULTS = {
			enabled: true,
			formatter: true,
			builtin: false,
		};

		const TS_CONFIG = {
			parserOptions: { sourceType: "module" },
			errorCodesToIgnore: [
				"2304",
				"2732",
				"2554",
				"2339",
				"2580",
				"2307",
				"2540",
			],
		};

		const PY_CONFIG = {
			configuration: { ignore: ["E501", "E401", "F401", "F704"] },
			pylsp: {
				configurationSources: ["pycodestyle"],
				plugins: {
					pycodestyle: {
						enabled: true,
						ignore: ["E501"],
						maxLineLength: 10,
					},
					pyflakes: {
						enabled: false,
					},
					pylint: {
						enabled: false,
					},
					pyls_mypy: {
						enabled: false,
					},
				},
			},
		};

		return {
			enabled: true,
			servers: {
				typescript: {
					command: "typescript-language-server",
					args: "--stdio",
					config: TS_CONFIG,
					...DEFAULTS,
				},
				javascript: {
					command: "typescript-language-server",
					args: "--stdio",
					config: TS_CONFIG,
					...DEFAULTS,
				},
				tsx: {
					command: "typescript-language-server",
					args: "--stdio",
					config: TS_CONFIG,
					...DEFAULTS,
				},
				jsx: {
					command: "typescript-language-server",
					args: "--stdio",
					config: TS_CONFIG,
					...DEFAULTS,
				},
				c_cpp: {
					command: "clangd",
					args: "",
					config: {},
					...DEFAULTS,
				},
				dart: {
					command: "dart",
					args: "--language-server",
					config: {},
					...DEFAULTS,
				},
				svelte: {
					command: "svelteserver",
					args: "--stdio",
					config: {},
					...DEFAULTS,
				},
				vue: {
					command: "vls",
					args: "",
					config: {},
					...DEFAULTS,
				},
				rust: {
					command: "rust-analyzer",
					args: "",
					config: {},
					...DEFAULTS,
				},
				python: {
					command: "pylsp",
					args: "--check-parent-process",
					config: PY_CONFIG,
					...DEFAULTS,
				},
				php: {
					command: "phpactor",
					args: "",
					config: {},
					...DEFAULTS,
				},
				lua: {
					command: "lua-language-server",
					args: "",
					config: {},
					...DEFAULTS,
				},
				go: {
					command: "gopls",
					args: "serve",
					config: {},
					...DEFAULTS,
				},
				java: {
					command: "/data/data/com.termux/files/home/jdtls/bin/jdtls",
					args: "",
					config: {},
					...DEFAULTS,
				},
				html: { ...DEFAULTS, builtin: true },
				css: { ...DEFAULTS, builtin: true },
				less: { ...DEFAULTS, builtin: true },
				scss: { ...DEFAULTS, builtin: true },
				json: { ...DEFAULTS, builtin: true },
				json5: { ...DEFAULTS, builtin: true },
				// python: { ...DEFAULTS, builtin: true },
				php: { ...DEFAULTS, builtin: true },
				lua: { ...DEFAULTS, builtin: true },
			},
			hover: true,
			format: true,
			completion: true,
			completionResolve: true,
			replaceCompleters: true,
			codelens: true,
		};
	}

	get #settingsObj() {
		const AppSettings = acode.require("settings");
		return {
			list: [
				{
					index: 0,
					key: "languageServers",
					text: "Language Servers",
					info: "Language server config for each mode",
				},
				{
					index: 4,
					key: "hover",
					text: "Show Tooltip",
					checkbox: this.getDefaultValue(this.settings.hover),
					info: "Show Tooltip on hover or selection",
				},
				{
					index: 5,
					key: "codelens",
					text: "Code Lens",
					checkbox: this.getDefaultValue(this.settings.codelens),
					info: "Enable codelens.",
				},
				{
					index: 2,
					key: "completion",
					text: "Code Completion",
					checkbox: this.getDefaultValue(this.settings.completion),
					info: "Enable code completion.",
				},
				{
					index: 3,
					key: "completionResolve",
					text: "Completion Resolve",
					checkbox: this.getDefaultValue(this.settings.completionResolve),
					info: "Enable code completion resolve.",
				},
				{
					index: 1,
					key: "replaceCompleters",
					text: "Replace Completers",
					checkbox: this.getDefaultValue(this.settings.replaceCompleters),
					info: "Disable the default code completers.",
				},
			],
			cb: (key, value) => {
				switch (key) {
					case "enabled":
						break;
					case "languageServers":
						this.#languageServersSettings();
						return;
					case "replaceCompleters":
						if (value) {
							this.#completers = editorManager.editor.completers.splice(1, 2);
						} else {
							if (this.#completers) {
								editorManager.editor.completers = [
									...this.#completers,
									...editorManager.editor.completers,
								];
							}
						}
						break;
					default:
						acode.alert(
							"Acode Language Server",
							"Settings updated. Restart acode app.",
						);
				}
				AppSettings.value["languageClient"][key] = value;
				AppSettings.update();
			},
		};
	}
}

export default LanguageClientService;
