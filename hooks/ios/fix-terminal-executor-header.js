#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function main() {
  const projectRoot = process.cwd();
  const sourcePath = path.join(projectRoot, "src/plugins/terminal/src/ios/Executor.h");
  const generatedPath = path.join(projectRoot, "platforms/ios/App/Plugins/com.foxdebug.acode.rk.exec.terminal/Executor.h");

  if (!fs.existsSync(sourcePath) || !fs.existsSync(generatedPath)) {
    console.log("Terminal executor header hook: source or generated Executor.h not found, skipping.");
    return;
  }

  const source = fs.readFileSync(sourcePath, "utf8");
  const generated = fs.readFileSync(generatedPath, "utf8");

  if (source === generated) {
    console.log("Terminal executor header hook: generated header already patched.");
    return;
  }

  fs.writeFileSync(generatedPath, source);
  console.log("Terminal executor header hook: patched generated Executor.h.");
}

main();
