import { cpp } from "@codemirror/lang-cpp";

// Import CodeMirror language extensions that are bundled with the app
import { css } from "@codemirror/lang-css";
import { go } from "@codemirror/lang-go";
import { html } from "@codemirror/lang-html";
import { java } from "@codemirror/lang-java";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { php } from "@codemirror/lang-php";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import { sass } from "@codemirror/lang-sass";
import { vue } from "@codemirror/lang-vue";
import { xml } from "@codemirror/lang-xml";
import { yaml } from "@codemirror/lang-yaml";
import { addMode } from "./modelist";

const modeList = {
	// Plain text (fallback/selectable)
	Text: { extensions: "txt|text|log|plain", extension: null },
	CSS: { extensions: "css", extension: css },
	Cpp: { extensions: "cpp|c|cc|cxx|h|hh|hpp|ino", extension: cpp },
	golang: { extensions: "go", extension: go },
	HTML: { extensions: "html|htm|xhtml|we|wpy", extension: html },
	Java: { extensions: "java", extension: java },
	JavaScript: { extensions: "js|jsm|jsx|cjs|mjs", extension: javascript },
	JSON: { extensions: "json", extension: json },
	Markdown: { extensions: "md|markdown", extension: markdown },
	PHP: {
		extensions: "php|inc|phtml|shtml|php3|php4|php5|phps|phpt|aw|ctp|module",
		extension: php,
	},
	Python: { extensions: "py", extension: python },
	Rust: { extensions: "rs", extension: rust },
	Sass: { extensions: "sass|scss", extension: sass },
	Vue: { extensions: "vue", extension: vue },
	XML: {
		extensions: "xml|rdf|rss|wsdl|xslt|atom|mathml|mml|xul|xbl|xaml",
		extension: xml,
	},
	YAML: { extensions: "yaml|yml", extension: yaml },
};

const languageNames = {
	golang: "Go",
	JavaScript: "JavaScript/JSX",
	Cpp: "C/C++",
	Text: "Plain Text",
};

Object.keys(modeList).forEach((key) => {
	const { extensions, extension } = modeList[key];
	const caption = languageNames[key] || key;
	// Pass null extension for Text; modelist will still register it
	addMode(key, extensions, caption, extension || null);
});
