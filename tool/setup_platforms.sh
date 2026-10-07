#!/usr/bin/env bash
# Generates the Android and Web platform folders (not stored in this repo)
# and adds the Internet permission Android release builds need.
# Safe to re-run: existing lib/ and test/ code is not overwritten.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter create . --platforms=android,web --org pk.accessoriessahiwal --project-name accessories_sahiwal

MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q "android.permission.INTERNET" "$MANIFEST"; then
  # Insert just before the <application> element.
  awk 'BEGIN{done=0} !done && /<application/ {print "    <uses-permission android:name=\"android.permission.INTERNET\"/>"; done=1} {print}' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  echo "Added INTERNET permission to $MANIFEST"
fi

# flutter create adds a counter-app sample test that does not apply here.
if [ -f test/widget_test.dart ] && grep -q "MyApp" test/widget_test.dart; then rm test/widget_test.dart; fi

# Friendly app label on the phone.
sed -i.bak 's/android:label="accessories_sahiwal"/android:label="Accessories Sahiwal"/' "$MANIFEST" && rm -f "$MANIFEST.bak"

flutter pub get
echo "Done. Next: cp env/example.json env/dev.json, fill in your Supabase URL and anon key, then:"
echo "  flutter run -d chrome --dart-define-from-file=env/dev.json"
