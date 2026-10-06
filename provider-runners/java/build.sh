#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 /path/to/gson.jar /output/directory" >&2
  exit 64
fi

gson_jar=$1
output_dir=$2
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
classes_dir="$output_dir/runner-classes"
fixture_dir="$output_dir/fixture-classes"
cms_fixture_dir="$output_dir/cms-fixture-classes"
manifest_file="$output_dir/runner-manifest.mf"
mkdir -p "$classes_dir" "$fixture_dir" "$cms_fixture_dir" "$output_dir/lib"

javac --release 21 -cp "$gson_jar" -d "$classes_dir" \
  "$script_dir/src/main/java/com/netvplayer/provider/NetVplayerProvider.java" \
  "$script_dir/src/main/java/com/netvplayer/provider/NetVplayerProviderFactory.java" \
  "$script_dir/src/main/java/com/netvplayer/provider/ProviderRunner.java"
printf '%s\n' \
  'Manifest-Version: 1.0' \
  'Main-Class: com.netvplayer.provider.ProviderRunner' \
  'Class-Path: lib/gson.jar' \
  > "$manifest_file"
jar --create --file "$output_dir/java-runner.jar" --manifest "$manifest_file" -C "$classes_dir" .
cp "$gson_jar" "$output_dir/lib/gson.jar"
javac --release 21 -d "$fixture_dir" "$script_dir/fixtures/src/MockProvider.java"
jar --create --file "$output_dir/mock-provider.jar" -C "$fixture_dir" .
javac --release 21 -cp "$gson_jar" -d "$cms_fixture_dir" "$script_dir/fixtures/src/JsonCmsProvider.java"
jar --create --file "$output_dir/json-cms-provider.jar" -C "$cms_fixture_dir" .

echo "Runner: $output_dir/java-runner.jar"
echo "Classpath dependency: $output_dir/lib/gson.jar"
echo "Fixture: $output_dir/mock-provider.jar"
echo "Fixture: $output_dir/json-cms-provider.jar"
