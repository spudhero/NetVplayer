#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /output/jre" >&2
    exit 64
fi

output_dir=$1
if [ -e "$output_dir" ]; then
    echo "refusing to overwrite existing runtime directory: $output_dir" >&2
    exit 73
fi

if [ -n "${NETVPLAYER_JAVA_HOME:-}" ]; then
    java_home=$NETVPLAYER_JAVA_HOME
elif [ -n "${JAVA_HOME:-}" ]; then
    java_home=$JAVA_HOME
elif command -v /usr/libexec/java_home >/dev/null 2>&1; then
    java_home=$(/usr/libexec/java_home -v 21 2>/dev/null || true)
else
    java_home=
fi

if [ -z "$java_home" ] || [ ! -x "$java_home/bin/java" ] || [ ! -x "$java_home/bin/jlink" ]; then
    echo "a full Java 21 JDK is required; set NETVPLAYER_JAVA_HOME or JAVA_HOME" >&2
    exit 78
fi

version=$($java_home/bin/java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\)\..*/\1/p' | head -n 1)
if [ "$version" != "21" ]; then
    echo "expected Java 21, found Java ${version:-unknown}" >&2
    exit 78
fi

modules="java.base,java.logging,java.net.http,java.naming,java.security.jgss,java.xml,jdk.crypto.ec"
mkdir -p "$(dirname "$output_dir")"
"$java_home/bin/jlink" \
    --add-modules "$modules" \
    --strip-debug \
    --no-man-pages \
    --no-header-files \
    --compress=2 \
    --output "$output_dir"

echo "Java 21 runtime: $output_dir"
