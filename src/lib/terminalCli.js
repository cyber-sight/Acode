import fsOperation from "fileSystem";
// import InstallState from "lib/installState";
import openFile from "lib/openFile";
import appSettings from "lib/settings";
import Url from "utils/Url";

function formatValue(value) {
	if (typeof value === "string") return value;
	return JSON.stringify(value, null, 2);
}

function readSetting(path) {
	const parts = String(path || "")
		.split(".")
		.filter(Boolean);
	if (!parts.length) return appSettings.value;

	let value = appSettings.value;
	for (const part of parts) {
		if (
			value === null ||
			typeof value !== "object" ||
			!Object.prototype.hasOwnProperty.call(value, part)
		) {
			throw new Error(`Unknown setting: ${path}`);
		}
		value = value[part];
	}
	return value;
}

async function writeSetting(path, rawValue) {
	const parts = String(path || "")
		.split(".")
		.filter(Boolean);
	if (!parts.length) throw new Error("A setting key is required.");
	if (!(parts[0] in appSettings.value)) {
		throw new Error(`Unknown setting: ${path}`);
	}

	let value;
	try {
		value = JSON.parse(rawValue);
	} catch {
		value = rawValue;
	}

	const topLevel = structuredClone(appSettings.value[parts[0]]);
	if (parts.length === 1) {
		await appSettings.update({ [parts[0]]: value }, false);
		return value;
	}

	if (topLevel === null || typeof topLevel !== "object") {
		throw new Error(`Setting ${parts[0]} does not contain nested keys.`);
	}

	let target = topLevel;
	for (let index = 1; index < parts.length - 1; index++) {
		const part = parts[index];
		if (target[part] === null || typeof target[part] !== "object") {
			throw new Error(`Unknown setting: ${path}`);
		}
		target = target[part];
	}
	const leaf = parts.at(-1);
	if (!Object.prototype.hasOwnProperty.call(target, leaf)) {
		throw new Error(`Unknown setting: ${path}`);
	}
	target[leaf] = value;
	await appSettings.update({ [parts[0]]: topLevel }, false);
	return value;
}

async function listPlugins() {
	if (!(await fsOperation(PLUGIN_DIR).exists())) return "No plugins installed.";
	const entries = await fsOperation(PLUGIN_DIR).lsDir();
	const plugins = await Promise.all(
		entries.map(async (entry) => {
			const id = Url.basename(entry.url);
			try {
				const manifest = await fsOperation(
					Url.join(entry.url, "plugin.json"),
				).readFile("json");
				return {
					id,
					name: manifest.name || id,
					version: manifest.version || "?",
					disabled: appSettings.value.pluginsDisabled?.[id] === true,
				};
			} catch {
				return { id, name: id, version: "?", disabled: true };
			}
		}),
	);
	if (!plugins.length) return "No plugins installed.";
	return plugins
		.sort((left, right) => left.id.localeCompare(right.id))
		.map(
			(plugin) =>
				`${plugin.id}\t${plugin.version}\t${
					plugin.disabled ? "disabled" : "enabled"
				}\t${plugin.name}`,
		)
		.join("\n");
}

async function requireInstalledPlugin(id) {
	if (!id) throw new Error("A plugin ID is required.");
	if (!(await fsOperation(PLUGIN_DIR, id).exists())) {
		throw new Error(`Plugin is not installed: ${id}`);
	}
}

async function setPluginEnabled(id, enabled) {
	await requireInstalledPlugin(id);
	const disabled = { ...(appSettings.value.pluginsDisabled || {}) };
	if (enabled) delete disabled[id];
	else disabled[id] = true;
	await appSettings.update({ pluginsDisabled: disabled }, false);

	if (enabled) {
		const { loadPluginWithTimeout } = await import("lib/loadPlugins");
		await loadPluginWithTimeout(id);
	} else {
		acode.unmountPlugin(id);
	}
	return `${enabled ? "Enabled" : "Disabled"} ${id}`;
}

async function uninstallPlugin(id) {
	await requireInstalledPlugin(id);
	// const state = await InstallState.new(id);
	await Promise.all([
		fsOperation(PLUGIN_DIR, id).delete(),
		// state.delete(state.storeUrl),
	]);
	acode.unmountPlugin(id);
	const disabled = { ...(appSettings.value.pluginsDisabled || {}) };
	delete disabled[id];
	await appSettings.update({ pluginsDisabled: disabled }, false);
	return `Uninstalled ${id}`;
}

async function handlePluginCommand(action, args) {
	switch (action) {
		case "list":
			return listPlugins();
		case "install": {
			const source = args[0];
			if (!source) throw new Error("A plugin ID or URL is required.");
			const { default: installPlugin } = await import("lib/installPlugin");
			await installPlugin(source);
			return `Installed ${source}`;
		}
		case "uninstall":
			return uninstallPlugin(args[0]);
		case "enable":
			return setPluginEnabled(args[0], true);
		case "disable":
			return setPluginEnabled(args[0], false);
		default:
			throw new Error(`Unknown plugin action: ${action || "(missing)"}`);
	}
}

async function handleSettingsCommand(action, args) {
	switch (action) {
		case "list":
			return formatValue(appSettings.value);
		case "get":
			return formatValue(readSetting(args[0]));
		case "set": {
			if (args.length < 2) {
				throw new Error("Usage: acode settings set <key> <json-or-text-value>");
			}
			const value = await writeSetting(args[0], args.slice(1).join(" "));
			return `${args[0]} = ${formatValue(value)}`;
		}
		case "open":
			await openFile(appSettings.settingsFile, { render: true });
			return "Opened settings.json";
		default:
			throw new Error(`Unknown settings action: ${action || "(missing)"}`);
	}
}

export default async function handleTerminalCli(command, args = []) {
	switch (command) {
		case "plugins":
		case "plugin":
			return handlePluginCommand(args[0], args.slice(1));
		case "settings":
			return handleSettingsCommand(args[0], args.slice(1));
		case "command": {
			const id = args[0];
			if (!id) throw new Error("An Acode command ID is required.");
			await acode.exec(id, ...args.slice(1));
			return `Executed ${id}`;
		}
		case "version":
			return (
				window.BuildInfo?.version || window.BuildInfo?.versionName || "Acode"
			);
		case "info":
			return formatValue({
				platform: window.cordova?.platformId || "web",
				packageName: window.BuildInfo?.packageName,
				version: window.BuildInfo?.version || window.BuildInfo?.versionName,
				settingsFile: appSettings.settingsFile,
				installedPlugins: (await fsOperation(PLUGIN_DIR).exists())
					? (await fsOperation(PLUGIN_DIR).lsDir()).length
					: 0,
			});
		case "reload":
			setTimeout(() => location.reload(), 100);
			return "Reloading Acode";
		default:
			throw new Error(`Unknown acode command: ${command || "(missing)"}`);
	}
}
