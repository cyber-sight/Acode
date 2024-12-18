import settingsPage from "components/settingsPage";
import confirm from "dialogs/confirm";
import rateBox from "dialogs/rateBox";
import actionStack from "lib/actionStack";
import openFile from "lib/openFile";
import removeAds from "lib/removeAds";
import appSettings from "lib/settings";
import settings from "lib/settings";
import Changelog from "pages/changelog/changelog";
import Donate from "pages/donate";
import plugins from "pages/plugins";
import themeSetting from "pages/themeSetting";
import helpers from "utils/helpers";
import About from "../pages/about";
import otherSettings from "./appSettings";
import backupRestore from "./backupRestore";
import editorSettings from "./editorSettings";
import filesSettings from "./filesSettings";
import formatterSettings from "./formatterSettings";
import previewSettings from "./previewSettings";
import scrollSettings from "./scrollSettings";
import searchSettings from "./searchSettings";

let CUSTOM_SETTINGS = [];

export function addCustomSettings(setting, settingPage) {
	if (typeof setting !== "object") throw new Error("Invalid object type");

	if (!setting.key) throw new Error("Setting key and text required");

	const entry = [setting, settingPage];
	CUSTOM_SETTINGS.push(entry);
	return () =>
		(CUSTOM_SETTINGS = CUSTOM_SETTINGS.filter((item) => item !== entry));
}

function editSettingsButton(callback) {
	const button = <span className="icon edit" attr-action="edit-settings"></span>;
	button.addEventListener("click", callback);
	return button;
}

export default function mainSettings() {
	const title = strings.settings.capitalize();
	const items = [
		{
			key: "about",
			text: strings.about,
			icon: "acode",
			index: 0,
		},
		{
			key: "donate",
			text: strings.support,
			icon: "favorite",
			iconColor: "orangered",
			sake: true,
			index: 1,
		},
		{
			key: "editor-settings",
			text: strings["editor settings"],
			icon: "text_format",
			index: 3,
		},
		{
			key: "app-settings",
			text: strings["app settings"],
			icon: "tune",
			index: 2,
		},
		{
			key: "formatter",
			text: strings.formatter,
			icon: "stars",
		},
		{
			key: "theme",
			text: strings.theme,
			icon: "color_lenspalette",
		},
		{
			key: "backup-restore",
			text: strings.backup.capitalize() + "/" + strings.restore.capitalize(),
			icon: "cached",
		},
		{
			key: "rateapp",
			text: strings["rate acode"],
			icon: "googleplay",
		},
		{
			key: "plugins",
			text: strings["plugins"],
			icon: "extension",
		},
		{
			key: "reset",
			text: strings["restore default settings"],
			icon: "historyrestore",
			index: 5,
		},
		{
			key: "preview-settings",
			text: strings["preview settings"],
			icon: "play_arrow",
			index: 4,
		},
		// {
		// 	key: "editSettings",
		// 	text: `${strings["edit"]} settings.json`,
		// 	icon: "edit",
		// },
		{
			key: "other-settings",
			text: strings["extra settings"] || "Extra Settings",
			icon: "settings_applications",
		},
		{
			key: "changeLog",
			text: `${strings["changelog"]}`,
			icon: "update",
		},
	];

	if (IS_FREE_VERSION) {
		items.push({
			key: "removeads",
			text: strings["remove ads"],
			icon: "cancel",
		});
	}

	/**
	 * Callback for settings page for handling click event
	 * @this {HTMLElement}
	 * @param {string} key
	 */
	async function callback(key) {
		switch (key) {
			case "app-settings":
			case "backup-restore":
			case "editor-settings":
			case "preview-settings":
			case "other-settings":
				appSettings.uiSettings[key].show();
				break;

			case "theme":
				themeSetting();
				break;

			case "about":
				About();
				break;

			case "donate":
				Donate();
				break;

			case "rateapp":
				rateBox();
				break;

			case "plugins":
				plugins();
				break;

			case "formatter":
				formatterSettings();
				break;

			case "editSettings": {
				actionStack.pop();
				openFile(settings.settingsFile);
				break;
			}

			case "reset":
				const confirmation = await confirm(
					strings.warning,
					strings["restore default settings"],
				);
				if (confirmation) {
					await appSettings.reset();
					location.reload();
				}
				break;

			case "removeads":
				try {
					await removeAds();
					this.remove();
				} catch (error) {
					helpers.error(error);
				}
				break;

			case "changeLog":
				Changelog();
				break;

			default:
				break;
		}
	}

	const page = settingsPage(title, items, callback, [
		editSettingsButton(() => callback("editSettings")),
	]);
	page.show();

	appSettings.uiSettings["main-settings"] = page;
	appSettings.uiSettings["app-settings"] = otherSettings();
	appSettings.uiSettings["file-settings"] = filesSettings();
	appSettings.uiSettings["backup-restore"] = backupRestore();
	appSettings.uiSettings["editor-settings"] = editorSettings();
	appSettings.uiSettings["scroll-settings"] = scrollSettings();
	appSettings.uiSettings["search-settings"] = searchSettings();
	appSettings.uiSettings["preview-settings"] = previewSettings();

	appSettings.uiSettings["other-settings"] = settingsPage(
		strings["extra settings"] || "Extra Settings",
		CUSTOM_SETTINGS.map((entry) => entry[0]),
		(key) => {
			const entry = CUSTOM_SETTINGS.find((item) => item[0].key === key);
			if (entry) entry[1]?.show();
		},
	);
}
