#!/usr/bin/env bash

#####
#
# add releases of kong-admin and kong-portal to the build
#
# paths must match the copyright headers script
#
#####

# unofficial strict mode
set -euo pipefail
IFS=$'\n\t'

if [ -n "${DEBUG:-}" ]; then
    set -x
fi

source .requirements

function main() {
    # just in case
    mkdir -pv '/tmp/build/usr/local/kong'

    function inner() {
        local name _dir _version
        name="${1:-kong-admin}"
        _dir="${2:-gui}"
        _version="${3:-nightly}"

        echo "--- installing ${name} ---"

        upper="$(echo "$name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"

        # KONG_ADMIN_DIRECTORY / KONG_PORTAL_DIRECTORY take precedence
        directory="$(eval "echo \${${upper}_DIRECTORY:-$_dir}" || true)"

        # KONG_ADMIN_VERSION / KONG_PORTAL_VERSION take precedence
        version="$(eval "echo \${${upper}_VERSION:-$_version}" || true)"

        release_url="https://api.github.com/repos/kong/${name}/releases/tags/${version}"

        mkdir -pv "/tmp/${name}"

        pushd "/tmp/${name}"
            asset_url="$(
                curl \
                    --fail \
                    -H "Authorization: token ${GITHUB_TOKEN}" \
                    -H 'Accept: application/json' \
                    "$release_url" \
                        | jq -r '.assets[0]|.url'
            )"

            curl \
                -L \
                --fail \
                -H "Authorization: token ${GITHUB_TOKEN}" \
                -H 'Accept: application/octet-stream' \
                "$asset_url" \
                    | tar -xzf -

            mv -v dist "/tmp/build/usr/local/kong/${directory}"
        popd

        if [[ "${name}" == 'portal' ]]; then
            # include the static portal copyright manifest
            #
            # this differs from the kong-admin manifest that arrives as part of
            # the release tarball above
            cp -v /kong/kong/portal/migrations/portal_manifest.json \
                /tmp/build/usr/local/kong || true
        fi

        echo "--- installed ${name} ---"
    }

    #     thing       dir    default version
    inner kong-admin  gui    nightly
    inner kong-portal portal v1.3.0-1
}

main
