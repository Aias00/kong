#!/usr/bin/env bash

# unofficial strict mode
set -euo pipefail
IFS=$'\n\t'

if [ -n "${DEBUG:-}" ]; then
    set -x
fi

function main() {
    echo '--- installing kong-enterprise plugins ---'

    if [ -n "${BAZEL_BUILD:-}" ]; then
        scripts/enterprise_plugin.sh install-all

    else
        pushd /kong
            make install-plugins-ee #move the script to here someday
        popd
        cp -R /usr/local/lib /tmp/build/usr/local/
        cp -R /usr/local/share/lua /tmp/build/usr/local/share/
    fi

    luarocks purge --tree=/tmp/build/usr/local --old-versions
    echo '--- installed kong-enterprise plugins ---'
}
main
