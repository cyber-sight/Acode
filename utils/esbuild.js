#!/usr/bin/env node
const path = require("node:path");
const fs = require("node:fs/promises");
const babel = require("@babel/core");
const esbuild = require("esbuild");
const sass = require("sass");
const postcss = require("postcss");
const tagLoader = require("html-tag-js/jsx/tag-loader");

const postcssConfig = require("../postcss.config.js");

const args = process.argv.slice(2);
const modeArgIndex = args.indexOf("--mode");
const mode =
	modeArgIndex > -1 && args[modeArgIndex + 1]
		? args[modeArgIndex + 1]
		: "development";
const isProd = mode === "production";
const watch = args.includes("--watch");

const root = path.resolve(__dirname, "..");
const outdir = path.join(root, "www", "build");
const target = ["es5"];

async function ensureCleanOutdir() {
	await fs.rm(outdir, { recursive: true, force: true });
	await fs.mkdir(outdir, { recursive: true });
}

async function processCssFile(filePath) {
	const isSass = /\.(sa|sc)ss$/.test(filePath);
	let css;

	if (isSass) {
		const result = sass.compile(filePath, {
			style: isProd ? "compressed" : "expanded",
			loadPaths: [
				path.dirname(filePath),
				path.join(root, "src"),
				path.join(root, "node_modules"),
			],
		});
		css = result.css;
	} else {
		css = await fs.readFile(filePath, "utf8");
	}

	const postcssPlugins = postcssConfig.plugins || [];
	const processed = await postcss(postcssPlugins).process(css, {
		from: filePath,
		map: !isProd ? { inline: true } : false,
	});

	return processed.css;
}

const babelPlugin = {
	name: "babel-transform",
	setup(build) {
		build.onLoad({ filter: /\.[cm]?js$/ }, async (args) => {
			const source = await fs.readFile(args.path, "utf8");
			const result = await babel.transformAsync(source, {
				filename: args.path,
				configFile: path.join(root, ".babelrc"),
				sourceType: "unambiguous",
				caller: {
					name: "esbuild",
					supportsStaticESM: true,
					supportsDynamicImport: true,
				},
			});
			const transformed = result && result.code ? result.code : source;
			const contents = tagLoader(transformed);
			return { contents, loader: "js" };
		});
	},
};

const cssPlugin = {
	name: "css-modules-as-text",
	setup(build) {
		build.onLoad({ filter: /\.(sa|sc|c)ss$/ }, async (args) => {
			const isModule = /\.m\.(sa|sc|c)ss$/.test(args.path);
			const contents = await processCssFile(args.path);
			return {
				contents,
				loader: isModule ? "text" : "css",
			};
		});
	},
};

const nodeFallbackPlugin = {
	name: "node-fallbacks",
	setup(build) {
		const emptyNamespace = "empty-module";

		build.onResolve({ filter: /^path$/ }, () => ({
			path: require.resolve("path-browserify"),
		}));

		build.onResolve({ filter: /^crypto$/ }, () => ({
			path: "crypto",
			namespace: emptyNamespace,
		}));

		build.onLoad({ filter: /.*/, namespace: emptyNamespace }, () => ({
			contents: "export default {};",
			loader: "js",
		}));
	},
};

async function run() {
	await ensureCleanOutdir();

	const buildOptions = {
		absWorkingDir: root,
		entryPoints: {
			main: "./src/main.js",
			console: "./src/lib/console.js",
		},
		outdir,
		entryNames: "[name]",
		chunkNames: "[name].chunk",
		assetNames: "[name][ext]",
		publicPath: "/build/",
		bundle: true,
		format: "iife",
		platform: "browser",
		target,
		minify: isProd,
		sourcemap: !isProd,
		define: {
			"process.env.NODE_ENV": JSON.stringify(mode),
		},
		nodePaths: [path.join(root, "src")],
		loader: {
			".hbs": "text",
			".md": "text",
			".png": "file",
			".svg": "file",
			".jpg": "file",
			".jpeg": "file",
			".ico": "file",
			".ttf": "file",
			".woff2": "file",
			".webp": "file",
			".eot": "file",
			".woff": "file",
			".webm": "file",
			".mp4": "file",
			".wav": "file",
		},
		plugins: [babelPlugin, cssPlugin, nodeFallbackPlugin],
	};

	if (watch) {
		const ctx = await esbuild.context(buildOptions);
		await ctx.watch();
		console.log("esbuild is watching for changes...");
		return;
	}

	await esbuild.build(buildOptions);
}

run().catch((error) => {
	console.error(error);
	process.exit(1);
});
