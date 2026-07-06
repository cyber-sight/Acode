#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function main() {
  const projectRoot = process.cwd();
  const filePath = path.join(projectRoot, "platforms/ios/App/Plugins/cordova-plugin-server/Server.m");

  if (!fs.existsSync(filePath)) {
    console.log("Server iOS hook: generated Server.m not found, skipping.");
    return;
  }

  let contents = fs.readFileSync(filePath, "utf8");
  const before = contents;

  if (!contents.includes("#import <GCDWebServer/GCDWebServerDataRequest.h>")) {
    contents = contents.replace(
      "#import <GCDWebServer/GCDWebServer.h>\n",
      "#import <GCDWebServer/GCDWebServer.h>\n#import <GCDWebServer/GCDWebServerDataRequest.h>\n",
    );
  }

  contents = contents.replace(
    "NSError *error = nil;\n    if ([instance.server startWithPort:port.unsignedIntegerValue bonjourName:nil error:&error]) {",
    "if ([instance.server startWithPort:port.unsignedIntegerValue bonjourName:nil]) {",
  );
  contents = contents.replace(
    'messageAsString:error.localizedDescription ?: @"Failed to start server"',
    'messageAsString:@"Failed to start server"',
  );
  contents = contents.replaceAll(
    "fileResponse.additionalHeaders[key] = headers[key];",
    "[fileResponse setValue:headers[key] forAdditionalHeader:key];",
  );
  contents = contents.replaceAll(
    "dataResponse.additionalHeaders[key] = headers[key];",
    "[dataResponse setValue:headers[key] forAdditionalHeader:key];",
  );

  if (contents !== before) {
    fs.writeFileSync(filePath, contents);
    console.log("Server iOS hook: patched generated GCDWebServer API usage.");
    return;
  }

  console.log("Server iOS hook: generated GCDWebServer source already compatible.");
}

main();
