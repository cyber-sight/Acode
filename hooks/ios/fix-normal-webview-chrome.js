#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

module.exports = function normalWebViewChromeHook(context) {
	const projectRoot = context.opts.projectRoot;
	const iosRoot = path.join(projectRoot, "platforms", "ios");
	const controller = findFile(iosRoot, "ViewController.swift");
	const plist = findFile(iosRoot, "App-Info.plist");
	const storyboard = findFile(iosRoot, "Main.storyboard");

	if (plist) {
		setPlistBool(plist, "UIStatusBarHidden", false);
		setPlistBool(plist, "UIViewControllerBasedStatusBarAppearance", false);
	}
	if (storyboard) {
		patchStoryboardColors(storyboard);
	}

	if (!controller) {
		console.warn("[ios chrome] ViewController.swift not found; skipping");
		return;
	}

	let source = fs.readFileSync(controller, "utf8");
	if (source.includes("AcodeNormalWebViewChrome")) {
		const updated = ensureSafeAreaWebViewLayout(source);
		if (updated !== source) {
			fs.writeFileSync(controller, updated);
			console.log(`[ios chrome] Updated safe-area layout in ${controller}`);
		}
		return;
	}
	if (!source.includes("class ViewController: MainViewController")) {
		throw new Error(`[ios chrome] Could not patch ${controller}: missing ViewController`);
	}

	source = source.replace(
		/class ViewController: MainViewController\s*\{\s*\}/,
		`class ViewController: MainViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        acodeConfigureNormalWebViewChrome()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        acodeLayoutWebViewInSafeArea()
    }

    private func acodeConfigureNormalWebViewChrome() {
        // AcodeNormalWebViewChrome
        let background = UIColor(red: 31.0 / 255.0, green: 36.0 / 255.0, blue: 39.0 / 255.0, alpha: 1.0)
        view.backgroundColor = background
        webView?.backgroundColor = background
        webView?.isOpaque = true
        acodeLayoutWebViewInSafeArea()
    }

    private func acodeLayoutWebViewInSafeArea() {
        guard let webView else {
            return
        }

        webView.frame = view.safeAreaLayoutGuide.layoutFrame
    }
}`,
	);
	fs.writeFileSync(controller, source);
	console.log(`[ios chrome] Patched ${controller}`);
};

function ensureSafeAreaWebViewLayout(source) {
	if (source.includes("acodeLayoutWebViewInSafeArea")) {
		return source;
	}

	source = source.replace(
		`    private func acodeConfigureNormalWebViewChrome() {`,
		`    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        acodeLayoutWebViewInSafeArea()
    }

    private func acodeConfigureNormalWebViewChrome() {`,
	);
	source = source.replace(
		`        webView?.isOpaque = true
    }
}`,
		`        webView?.isOpaque = true
        acodeLayoutWebViewInSafeArea()
    }

    private func acodeLayoutWebViewInSafeArea() {
        guard let webView else {
            return
        }

        webView.frame = view.safeAreaLayoutGuide.layoutFrame
    }
}`,
	);

	return source;
}

function setPlistBool(plist, key, value) {
	let source = fs.readFileSync(plist, "utf8");
	const boolTag = value ? "<true/>" : "<false/>";
	const pattern = new RegExp(`(<key>${escapeRegExp(key)}</key>\\s*)<(?:true|false)\\s*/>`);

	if (pattern.test(source)) {
		source = source.replace(pattern, `$1${boolTag}`);
	} else {
		source = source.replace("</dict>", `\t<key>${key}</key>\n\t${boolTag}\n</dict>`);
	}

	fs.writeFileSync(plist, source);
}

function patchStoryboardColors(storyboard) {
	let source = fs.readFileSync(storyboard, "utf8");
	const color =
		'<color red="0.1215686275" green="0.1411764706" blue="0.1529411765" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>';

	for (const name of ["BackgroundColor", "StatusBarBackgroundColor"]) {
		const pattern = new RegExp(
			`(<namedColor name="${escapeRegExp(name)}">)\\s*<color[^>]+/>\\s*(</namedColor>)`,
			"m",
		);
		source = source.replace(pattern, `$1\n            ${color}\n        $2`);
	}

	fs.writeFileSync(storyboard, source);
}

function findFile(root, filename) {
	if (!fs.existsSync(root)) return null;

	const entries = fs.readdirSync(root, { withFileTypes: true });
	for (const entry of entries) {
		const fullPath = path.join(root, entry.name);
		if (entry.isDirectory()) {
			const match = findFile(fullPath, filename);
			if (match) return match;
		} else if (entry.name === filename) {
			return fullPath;
		}
	}

	return null;
}

function escapeRegExp(value) {
	return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
