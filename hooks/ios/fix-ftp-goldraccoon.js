#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function main() {
  const projectRoot = process.cwd();
  const sourcePath = path.join(projectRoot, "src/plugins/ftp/src/ios/Ftp.m");
  const generatedPath = path.join(projectRoot, "platforms/ios/App/Plugins/cordova-plugin-ftp/Ftp.m");

  if (!fs.existsSync(sourcePath) || !fs.existsSync(generatedPath)) {
    console.log("FTP iOS hook: source or generated Ftp.m not found, skipping.");
    return;
  }

  const source = fs.readFileSync(sourcePath, "utf8");
  const generated = fs.readFileSync(generatedPath, "utf8");

  if (source === generated) {
    console.log("FTP iOS hook: generated source already stubbed.");
    return;
  }

  fs.writeFileSync(generatedPath, source);
  console.log("FTP iOS hook: replaced generated source with iOS stub.");
}

main();
