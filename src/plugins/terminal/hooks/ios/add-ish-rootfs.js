#!/usr/bin/env node
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

function copyDir(src, dest) {
  fs.rmSync(dest, { recursive: true, force: true });
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src)) {
    const srcPath = path.join(src, entry);
    const destPath = path.join(dest, entry);
    const stat = fs.statSync(srcPath);
    if (stat.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

// Cheap, dependency-free fingerprint of the source rootfs: meta.db size plus
// the number of files under data/. Not a full integrity check — just enough
// drift detection to notice when generated copies no longer match the source.
function rootfsFingerprint(rootPath) {
  const metaDbSize = fs.statSync(path.join(rootPath, "meta.db")).size;
  let fileCount = 0;
  const countFiles = (dir) => {
    for (const entry of fs.readdirSync(dir)) {
      const entryPath = path.join(dir, entry);
      if (fs.statSync(entryPath).isDirectory()) {
        countFiles(entryPath);
      } else {
        fileCount += 1;
      }
    }
  };
  countFiles(path.join(rootPath, "data"));
  return crypto
    .createHash("sha256")
    .update(`${metaDbSize}:${fileCount}`)
    .digest("hex");
}

function checkFreshness(fingerprintPath, fingerprint, legacyAppRootfs) {
  let previous = null;
  try {
    previous = JSON.parse(fs.readFileSync(fingerprintPath, "utf8"));
  } catch {
    previous = null;
  }
  if (previous && previous.fingerprint && previous.fingerprint !== fingerprint) {
    console.log("============================================================");
    console.log("WARNING: iSH rootfs source changed since the last prepare.");
    console.log(`  previous fingerprint: ${previous.fingerprint}`);
    console.log(`  current  fingerprint: ${fingerprint}`);
    console.log("Previously generated rootfs copies are STALE. In particular:");
    console.log(`  ${legacyAppRootfs}`);
    console.log("is no longer refreshed by this hook and must be removed or");
    console.log("regenerated manually if anything still consumes it.");
    console.log("============================================================");
  }
  fs.writeFileSync(
    fingerprintPath,
    `${JSON.stringify({ fingerprint }, null, 2)}\n`,
  );
}

function main() {
  const projectRoot = process.cwd();
  const pluginRoot = path.join(projectRoot, "plugins", "com.foxdebug.acode.rk.exec.terminal");
  const rootfsCandidates = [
    path.join(projectRoot, "src", "plugins", "terminal", "src", "ios", "ish-rootfs"),
    path.join(pluginRoot, "src", "ios", "ish-rootfs"),
  ];
  const srcRootfs = rootfsCandidates.find((candidate) => fs.existsSync(candidate));
  if (!srcRootfs) {
    console.log("iSH rootfs hook: src/ios/ish-rootfs not found, skipping.");
    return;
  }

  const sqliteSidecars = ["meta.db-shm", "meta.db-wal"].filter((name) =>
    fs.existsSync(path.join(srcRootfs, name)),
  );
  if (sqliteSidecars.length) {
    throw new Error(
      `iSH rootfs metadata is not checkpointed; remove ${sqliteSidecars.join(
        ", ",
      )} only after checkpointing meta.db. SQLite sidecars must never be bundled.`,
    );
  }

  const iosPath = path.join(projectRoot, "platforms", "ios");
  const xcodeProject = fs.existsSync(iosPath)
    ? fs.readdirSync(iosPath).find((entry) => entry.endsWith(".xcodeproj"))
    : null;
  if (!xcodeProject) {
    console.log("iSH rootfs hook: no iOS Xcode project found, skipping.");
    return;
  }

  const appName = xcodeProject.replace(/\.xcodeproj$/, "");
  const legacyAppRootfs = path.join(iosPath, appName, "ish-rootfs");
  const wwwRootfs = path.join(iosPath, "www", "ish-rootfs");
  const fingerprintPath = path.join(iosPath, ".ish-rootfs-fingerprint.json");

  // Only platforms/ios/www/ish-rootfs ships ([IshBridge
  // installBundledDefaultRootfs] reads bundlePath/www/ish-rootfs); never
  // maintain a second copy inside the app target directory.
  copyDir(srcRootfs, wwwRootfs);
  console.log("iSH rootfs hook: copied rootfs to", wwwRootfs);

  checkFreshness(fingerprintPath, rootfsFingerprint(srcRootfs), legacyAppRootfs);
}

main();
