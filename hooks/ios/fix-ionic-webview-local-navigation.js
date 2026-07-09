#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

module.exports = function fixIonicWebViewLocalNavigation(context) {
	const projectRoot = context.opts.projectRoot;
	const targets = [
		path.join(
			projectRoot,
			"plugins",
			"cordova-plugin-ionic-webview",
			"src",
			"ios",
			"CDVWKWebViewEngine.m",
		),
		path.join(
			projectRoot,
			"platforms",
			"ios",
			"App",
			"Plugins",
			"cordova-plugin-ionic-webview",
			"CDVWKWebViewEngine.m",
		),
	];

	for (const target of targets) {
		if (!fs.existsSync(target)) continue;
		patchEngine(target);
	}
};

function patchEngine(target) {
	let source = fs.readFileSync(target, "utf8");
	if (source.includes("[url.host isEqualToString:localServerUrl.host]")) {
		return;
	}

	const marker = `    if ([url isFileURL]) {
        return YES;
    }
`;
	if (!source.includes(marker)) {
		throw new Error(`[ionic webview] Could not patch ${target}: policy marker missing`);
	}

	source = source.replace(
		marker,
		`${marker}
    NSURL *localServerUrl = [NSURL URLWithString:self.CDV_LOCAL_SERVER];
    if (localServerUrl &&
        [url.scheme isEqualToString:localServerUrl.scheme] &&
        [url.host isEqualToString:localServerUrl.host]) {
        return YES;
    }
`,
	);
	fs.writeFileSync(target, source);
	console.log(`[ionic webview] Patched local navigation policy in ${target}`);
}
