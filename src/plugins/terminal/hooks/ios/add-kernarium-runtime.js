#!/usr/bin/env node
"use strict";

// Opt-in: prepares the iOS project to run the terminal on a Kernarium Linux
// guest instead of iSH. Does nothing unless KERNARIUM_DIR and
// KERNARIUM_XCFRAMEWORKS are set, so the default iSH build is unchanged.
//
//   KERNARIUM_DIR           Kernarium checkout (for Kernarium/Runtime/KernariumRuntime.h)
//   KERNARIUM_XCFRAMEWORKS  directory of packaged XCFrameworks
//                           (Kernarium/scripts/package-ios-frameworks.sh output)
//   ACODE_KERNARIUM_IMAGE   guest image; defaults to the output of
//                           src/plugins/terminal/kernarium/build-guest-image.sh

const fs = require("fs");
const path = require("path");

const PHASE_NAME = "Embed Kernarium runtime";
const ENTITLEMENTS = [
  // The runtime reserves a large fixed window for the guest kernel and RAM.
  "com.apple.developer.kernel.extended-virtual-addressing",
  "com.apple.developer.kernel.increased-memory-limit",
];

function loadXcode(projectRoot) {
  const searchPaths = [path.join(projectRoot, "node_modules", "cordova-ios"), projectRoot];
  return require(require.resolve("xcode", { paths: searchPaths }));
}

function findIosProject(iosPath) {
  if (!fs.existsSync(iosPath)) return null;
  const projectDir = fs.readdirSync(iosPath).find((entry) => entry.endsWith(".xcodeproj"));
  if (!projectDir) return null;
  return {
    appName: projectDir.replace(/\.xcodeproj$/, ""),
    pbxprojPath: path.join(iosPath, projectDir, "project.pbxproj"),
  };
}

function addEntitlements(file) {
  if (!fs.existsSync(file)) return false;
  let text = fs.readFileSync(file, "utf8");
  let changed = false;
  for (const key of ENTITLEMENTS) {
    if (text.includes(`<key>${key}</key>`)) continue;
    text = text.replace(/<\/dict>\s*<\/plist>\s*$/, `\t<key>${key}</key>\n\t<true/>\n</dict>\n</plist>\n`);
    changed = true;
  }
  if (changed) fs.writeFileSync(file, text);
  return true;
}

function main() {
  const projectRoot = process.cwd();
  const kernariumDir = process.env.KERNARIUM_DIR;
  const xcframeworks = process.env.KERNARIUM_XCFRAMEWORKS;
  if (!kernariumDir || !xcframeworks) {
    console.log("Kernarium hook: KERNARIUM_DIR/KERNARIUM_XCFRAMEWORKS not set; the terminal uses iSH.");
    return;
  }

  const runtimeHeaderDir = path.resolve(kernariumDir, "Kernarium", "Runtime");
  if (!fs.existsSync(path.join(runtimeHeaderDir, "KernariumRuntime.h"))) {
    throw new Error(`Kernarium hook: ${runtimeHeaderDir}/KernariumRuntime.h not found`);
  }
  const runtime = path.resolve(xcframeworks, "KRuntime_6_18_4K.xcframework");
  if (!fs.existsSync(runtime)) {
    throw new Error(`Kernarium hook: ${runtime} not found; run Kernarium/scripts/package-ios-frameworks.sh`);
  }
  const image = path.resolve(
    process.env.ACODE_KERNARIUM_IMAGE ||
      path.join(projectRoot, "src", "plugins", "terminal", "kernarium", "build", "acode-kernarium-rootfs.ext4"),
  );
  if (!fs.existsSync(image)) {
    console.warn(`Kernarium hook: ${image} does not exist yet; the Xcode build will fail until it does.`);
  }

  const iosPath = path.join(projectRoot, "platforms", "ios");
  const project = findIosProject(iosPath);
  if (!project) {
    console.log("Kernarium hook: no iOS Xcode project found, skipping.");
    return;
  }

  // The build phase reads its inputs from a file beside it, so the project
  // file holds no machine-specific paths.
  const supportDir = path.join(iosPath, "kernarium");
  fs.mkdirSync(supportDir, { recursive: true });
  fs.copyFileSync(path.join(__dirname, "kernarium-embed.sh"), path.join(supportDir, "kernarium-embed.sh"));
  fs.chmodSync(path.join(supportDir, "kernarium-embed.sh"), 0o755);
  const quote = (value) => `'${value.replace(/'/g, "'\\''")}'`;
  fs.writeFileSync(
    path.join(supportDir, "kernarium-embed.env"),
    `KERNARIUM_XCFRAMEWORKS=${quote(path.resolve(xcframeworks))}\nACODE_KERNARIUM_IMAGE=${quote(image)}\n`,
  );

  const xcode = loadXcode(projectRoot);
  const pbx = xcode.project(project.pbxprojPath);
  pbx.parseSync();

  const target = pbx.getFirstTarget();
  const header = `"${runtimeHeaderDir}"`;
  const configurations = pbx.pbxXCBuildConfigurationSection();
  for (const key of Object.keys(configurations)) {
    const configuration = configurations[key];
    if (typeof configuration !== "object" || !configuration.buildSettings) continue;
    if (configuration.buildSettings.PRODUCT_NAME === undefined) continue;
    const settings = configuration.buildSettings;
    let paths = settings.HEADER_SEARCH_PATHS || ['"$(inherited)"'];
    if (!Array.isArray(paths)) paths = [paths];
    if (!paths.includes(header)) settings.HEADER_SEARCH_PATHS = [...paths, header];
  }

  const phases = pbx.hash.project.objects.PBXShellScriptBuildPhase || {};
  const exists = Object.values(phases).some(
    (phase) => typeof phase === "object" && phase.name === `"${PHASE_NAME}"`,
  );
  if (!exists) {
    pbx.addBuildPhase([], "PBXShellScriptBuildPhase", PHASE_NAME, target.uuid, {
      shellPath: "/bin/bash",
      shellScript: '"${SRCROOT}/kernarium/kernarium-embed.sh"',
    });
  }
  fs.writeFileSync(project.pbxprojPath, pbx.writeSync());

  const appDir = path.join(iosPath, project.appName);
  for (const name of ["Entitlements-Debug.plist", "Entitlements-Release.plist"]) {
    if (!addEntitlements(path.join(appDir, name))) {
      console.warn(`Kernarium hook: ${name} not found; add ${ENTITLEMENTS.join(" and ")} by hand.`);
    }
  }

  console.log(`Kernarium hook: the terminal will run on Kernarium (${path.basename(runtime)}).`);
}

main();
