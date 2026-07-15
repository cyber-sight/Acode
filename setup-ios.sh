#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended for macOS with Xcode installed."
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are not installed."
  echo "Run: xcode-select --install"
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is not installed or not configured."
  echo "Install Xcode from the App Store and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

sudo xcodebuild -license accept >/dev/null
\
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install it from https://brew.sh and re-run this script."
  exit 1
fi

brew update
brew install cocoapods ios-deploy

pod repo update

echo "iOS tooling setup complete."

if ! command -v cordova >/dev/null 2>&1; then
  echo "Cordova CLI not found. Install with: npm install -g cordova"
fi
