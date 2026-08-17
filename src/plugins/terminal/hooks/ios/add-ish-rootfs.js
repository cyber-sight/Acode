#!/usr/bin/env node
"use strict";

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
  const appRootfs = path.join(iosPath, appName, "ish-rootfs");
  const wwwRootfs = path.join(iosPath, "www", "ish-rootfs");

  copyDir(srcRootfs, appRootfs);
  copyDir(srcRootfs, wwwRootfs);
  console.log("iSH rootfs hook: copied rootfs to", appRootfs, "and", wwwRootfs);
}

main();
