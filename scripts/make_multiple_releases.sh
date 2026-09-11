#!/usr/bin/env bash
set -e

PLUGIN_VERSION="$1"

if [ -z "$PLUGIN_VERSION" ]; then
	echo "Plugin version is required"
	exit 1
fi

# The Crystal Tempest fork is built and tested against 4.7.2 only.
GODOT_VERSIONS="4.7.2"
PLUGIN_NAME=godot-storekit2

cd godot
git fetch
cd ..

for VERSION in $GODOT_VERSIONS; do
	echo Making $VERSION...
	cd godot
	git switch -d $VERSION-stable
	cd ..
	./scripts/generate_headers.sh
	./scripts/make_release.sh

	mv bin/$PLUGIN_NAME.zip bin/$PLUGIN_NAME-$PLUGIN_VERSION-Godot-$VERSION.zip
done

