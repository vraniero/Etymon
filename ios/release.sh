#!/bin/sh
# Archive Etymon and upload it to App Store Connect (TestFlight, then review).
# Needs the app record (com.ranierovirgilio.etymon) in App Store Connect and Xcode signed in
# to the team's account. Bump CURRENT_PROJECT_VERSION in project.yml for every upload.
#
# The dictionary's asset packs are uploaded separately (Transporter or the App Store
# Connect API): build them with  cd ../pipeline && .venv/bin/python export_packs.py --package
# and upload ../pipeline/data/packs/archives/*.aar before the build that needs them.
set -e
cd "$(dirname "$0")"
xcodegen generate
xcodebuild -project Etymon.xcodeproj -scheme Etymon -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Etymon.xcarchive \
  -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/Etymon.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
