#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function copyDir(src, dest) {
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
  const srcRootfs = path.join(pluginRoot, "src", "ios", "ish-rootfs");
  if (!fs.existsSync(srcRootfs)) {
    console.log("iSH rootfs hook: src/ios/ish-rootfs not found, skipping.");
    return;
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
  const destRootfs = path.join(iosPath, appName, "ish-rootfs");
  copyDir(srcRootfs, destRootfs);
  console.log("iSH rootfs hook: copied rootfs to", destRootfs);
}

main();
