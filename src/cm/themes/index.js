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

// Registry of CodeMirror editor themes
// key: id, value: { id, caption, isDark, getExtension: () => Extension[] }
const themes = new Map();

export function addTheme(id, caption, isDark, getExtension) {
	const key = String(id).toLowerCase();
	if (themes.has(key)) return;
	themes.set(key, {
		id: key,
		caption: caption || id,
		isDark: !!isDark,
		getExtension,
	});
}

export function getThemes() {
	return Array.from(themes.values());
}

export function getThemeById(id) {
	if (!id) return null;
	return themes.get(String(id).toLowerCase()) || null;
}

export function removeTheme(id) {
	if (!id) return;
	themes.delete(String(id).toLowerCase());
}

// Register built-ins
addTheme("one_dark", "One Dark", true, () => [oneDark]);
addTheme(auraConfig.name, "Aura", !!auraConfig.dark, () => aura());
addTheme(
	noctisLilacConfig.name,
	noctisLilacConfig.caption || "Noctis Lilac",
	!!noctisLilacConfig.dark,
	() => noctisLilac(),
);
addTheme(draculaConfig.name, "Dracula", !!draculaConfig.dark, () => dracula());
addTheme(githubDarkConfig.name, "GitHub Dark", !!githubDarkConfig.dark, () =>
	githubDark(),
);
addTheme(githubLightConfig.name, "GitHub Light", !!githubLightConfig.dark, () =>
	githubLight(),
);
addTheme(
	solarizedDarkConfig.name,
	"Solarized Dark",
	!!solarizedDarkConfig.dark,
	() => solarizedDark(),
);
addTheme(
	solarizedLightConfig.name,
	"Solarized Light",
	!!solarizedLightConfig.dark,
	() => solarizedLight(),
);
addTheme(
	tokyoNightDayConfig.name,
	"Tokyo Night Day",
	!!tokyoNightDayConfig.dark,
	() => tokyoNightDay(),
);
addTheme(tokyoNightConfig.name, "Tokyo Night", !!tokyoNightConfig.dark, () =>
	tokyoNight(),
);
addTheme(noctisLilacConfig.name, "Noctis Lilac", !!noctisLilacConfig.dark, () =>
	noctisLilac(),
);
addTheme(monokaiConfig.name, "Monokai", !!monokaiConfig.dark, () => monokai());
addTheme(vscodeDarkConfig.name, "VS Code Dark", !!vscodeDarkConfig.dark, () =>
	vscodeDark(),
);

export default { getThemes, getThemeById, addTheme, removeTheme };
