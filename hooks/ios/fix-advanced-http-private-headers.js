#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const files = [
  "platforms/ios/App/Plugins/cordova-plugin-advanced-http/SM_AFNetworking/SM_AFNetworkReachabilityManager.m",
  "platforms/ios/App/Plugins/cordova-plugin-advanced-http/SM_AFNetworking/SM_AFHTTPSessionManager.m",
  "platforms/ios/App/Plugins/cordova-plugin-advanced-http/SM_AFNetworkReachabilityManager.m",
  "platforms/ios/App/Plugins/cordova-plugin-advanced-http/SM_AFHTTPSessionManager.m",
];

const activityIndicatorFiles = [
  "platforms/ios/App/Plugins/cordova-plugin-advanced-http/SDNetworkActivityIndicator.m",
];

function main() {
  const projectRoot = process.cwd();
  const changed = [];

  for (const relativePath of files) {
    const filePath = path.join(projectRoot, relativePath);
    if (!fs.existsSync(filePath)) continue;

    const before = fs.readFileSync(filePath, "utf8");
    const after = before.replace(/#import <netinet6\/in6\.h>\n/g, "");

    if (after === before) continue;

    fs.writeFileSync(filePath, after);
    changed.push(relativePath);
  }

  for (const relativePath of activityIndicatorFiles) {
    const filePath = path.join(projectRoot, relativePath);
    if (!fs.existsSync(filePath)) continue;

    const before = fs.readFileSync(filePath, "utf8");
    const after = before.replace(
      /\s*\[\[UIApplication sharedApplication\] setNetworkActivityIndicatorVisible:(?:YES|NO)\];/g,
      "",
    );

    if (after === before) continue;

    fs.writeFileSync(filePath, after);
    changed.push(relativePath);
  }

  if (changed.length) {
    console.log(`advanced-http iOS hook: patched generated compatibility issues in ${changed.join(", ")}`);
  } else {
    console.log("advanced-http iOS hook: generated sources already compatible.");
  }
}

main();
