#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function main() {
  const projectRoot = process.cwd();
  const filePath = path.join(projectRoot, "platforms/ios/App/Plugins/com.foxdebug.acode.rk.exec.terminal/IshRootfs.h");

  if (!fs.existsSync(filePath)) {
    console.log("iSH rootfs header hook: generated header not found, skipping.");
    return;
  }

  const before = fs.readFileSync(filePath, "utf8");
  const after = before.replace('#import <Foundation/Foundation.h>\n\n', "");

  if (after === before) {
    console.log("iSH rootfs header hook: generated header already C-compatible.");
    return;
  }

  fs.writeFileSync(filePath, after);
  console.log("iSH rootfs header hook: removed Foundation import from C header.");
}

main();
