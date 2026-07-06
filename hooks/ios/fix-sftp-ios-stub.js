#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function main() {
  const projectRoot = process.cwd();
  const sourcePath = path.join(projectRoot, "src/plugins/sftp/src/ios/Sftp.m");
  const generatedPath = path.join(projectRoot, "platforms/ios/App/Plugins/cordova-plugin-sftp/Sftp.m");

  if (!fs.existsSync(sourcePath) || !fs.existsSync(generatedPath)) {
    console.log("SFTP iOS hook: source or generated file missing, skipping.");
    return;
  }

  const source = fs.readFileSync(sourcePath, "utf8");
  const generated = fs.readFileSync(generatedPath, "utf8");

  if (source === generated) {
    console.log("SFTP iOS hook: generated source already stubbed.");
    return;
  }

  fs.writeFileSync(generatedPath, source);
  console.log("SFTP iOS hook: replaced generated source with iOS unsupported stub.");
}

main();
