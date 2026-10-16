#!/bin/sh
# Runs the tests. The Command Line Tools ship Swift Testing, but `swift test`
# does not find Testing.framework and lib_TestingInterop.dylib there on its own.
set -eu
cd "$(dirname "$0")/.."

developer_dir=$(xcode-select -p)
case "$developer_dir" in
*/CommandLineTools)
    lib="$developer_dir/Library/Developer"
    exec swift test \
        -Xswiftc -F"$lib/Frameworks" \
        -Xlinker -F"$lib/Frameworks" \
        -Xlinker -rpath -Xlinker "$lib/Frameworks" \
        -Xlinker -rpath -Xlinker "$lib/usr/lib" \
        "$@"
    ;;
esac
exec swift test "$@"
