#!/bin/bash
# Builds build/DemoDriver.app (ad hoc signed). macOS asks for Accessibility again after each rebuild.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/DemoDriver.app
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/DemoDriver" DemoDriver.swift
codesign -s - --force "$APP"
echo "$PWD/$APP"
