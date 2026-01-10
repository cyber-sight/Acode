import { oneDark } from "@codemirror/theme-one-dark";
import aura, { config as auraConfig } from "./aura";
import dracula, { config as draculaConfig } from "./dracula";
import githubDark, { config as githubDarkConfig } from "./githubDark";
import githubLight, { config as githubLightConfig } from "./githubLight";
import monokai, { config as monokaiConfig } from "./monokai";
import noctisLilac, { config as noctisLilacConfig } from "./noctisLilac";
import solarizedDark, { config as solarizedDarkConfig } from "./solarizedDark";
import solarizedLight, {
	config as solarizedLightConfig,
} from "./solarizedLight";
import tokyoNight, { config as tokyoNightConfig } from "./tokyoNight";
import tokyoNightDay, { config as tokyoNightDayConfig } from "./tokyoNightDay";
import vscodeDark, { config as vscodeDarkConfig } from "./vscodeDark";

const oneDarkConfig = {
	name: "one_dark",
	dark: true,
	background: "#282c34",
	foreground: "#abb2bf",
	keyword: "#c678dd",
	string: "#98c379",
	number: "#d19a66",
	comment: "#5c6370",
	function: "#61afef",
	variable: "#e06c75",
	type: "#e5c07b",
	class: "#e5c07b",
	constant: "#d19a66",
	operator: "#56b6c2",
	invalid: "#ff6b6b",
};

const themes = new Map();

export function addTheme(id, caption, isDark, getExtension, config = null) {
	const key = String(id).toLowerCase();
	if (themes.has(key)) return;
	themes.set(key, {
		id: key,
		caption: caption || id,
		isDark: !!isDark,
		getExtension,
		config: config || null,
	});
}

export function getThemes() {
	return Array.from(themes.values());
}

export function getThemeById(id) {
	if (!id) return null;
	return themes.get(String(id).toLowerCase()) || null;
}

export function getThemeConfig(id) {
	if (!id) return oneDarkConfig;
	const theme = themes.get(String(id).toLowerCase());
	return theme?.config || oneDarkConfig;
}

export function removeTheme(id) {
	if (!id) return;
	themes.delete(String(id).toLowerCase());
}

addTheme("one_dark", "One Dark", true, () => [oneDark], oneDarkConfig);
addTheme(auraConfig.name, "Aura", !!auraConfig.dark, () => aura(), auraConfig);
addTheme(
	noctisLilacConfig.name,
	noctisLilacConfig.caption || "Noctis Lilac",
	!!noctisLilacConfig.dark,
	() => noctisLilac(),
	noctisLilacConfig,
);
addTheme(
	draculaConfig.name,
	"Dracula",
	!!draculaConfig.dark,
	() => dracula(),
	draculaConfig,
);
addTheme(
	githubDarkConfig.name,
	"GitHub Dark",
	!!githubDarkConfig.dark,
	() => githubDark(),
	githubDarkConfig,
);
addTheme(
	githubLightConfig.name,
	"GitHub Light",
	!!githubLightConfig.dark,
	() => githubLight(),
	githubLightConfig,
);
addTheme(
	solarizedDarkConfig.name,
	"Solarized Dark",
	!!solarizedDarkConfig.dark,
	() => solarizedDark(),
	solarizedDarkConfig,
);
addTheme(
	solarizedLightConfig.name,
	"Solarized Light",
	!!solarizedLightConfig.dark,
	() => solarizedLight(),
	solarizedLightConfig,
);
addTheme(
	tokyoNightDayConfig.name,
	"Tokyo Night Day",
	!!tokyoNightDayConfig.dark,
	() => tokyoNightDay(),
	tokyoNightDayConfig,
);
addTheme(
	tokyoNightConfig.name,
	"Tokyo Night",
	!!tokyoNightConfig.dark,
	() => tokyoNight(),
	tokyoNightConfig,
);
addTheme(
	monokaiConfig.name,
	"Monokai",
	!!monokaiConfig.dark,
	() => monokai(),
	monokaiConfig,
);
addTheme(
	vscodeDarkConfig.name,
	"VS Code Dark",
	!!vscodeDarkConfig.dark,
	() => vscodeDark(),
	vscodeDarkConfig,
);

export default {
	getThemes,
	getThemeById,
	getThemeConfig,
	addTheme,
	removeTheme,
};
