#!/bin/bash
set -ue

function usage() {
  cat << EOF

  Update the node docker images.

  Usage:
    $0 [-s] [MAJOR_VERSION(S)] [VARIANT(S)]

  Examples:
    - update.sh                   # Update all images
    - update.sh -s                # Update all images, skip updating Alpine and Yarn
    - update.sh 8,10              # Update version 8 and 10 and variants (default, slim, alpine etc.)
    - update.sh -s 8              # Update version 8 and variants, skip updating Alpine and Yarn
    - update.sh 8 slim,stretch    # Update only slim and stretch variants for version 8
    - update.sh -s 8 slim,stretch # Update only slim and stretch variants for version 8, skip updating Alpine and Yarn
    - update.sh . alpine          # Update the alpine variant for all versions

  OPTIONS:
    -s Security update; skip updating the yarn and alpine versions.
    -h Show this message

EOF
}

SKIP=false
while getopts "sh" opt; do
  case "${opt}" in
    s)
      SKIP=true
      shift
      ;;
    h)
      usage
      exit
      ;;
    \?)
      usage
      exit
      ;;
  esac
done

. functions.sh

cd "$(cd "${0%/*}" && pwd -P)"

IFS=',' read -ra versions_arg <<< "${1:-}"
IFS=',' read -ra variant_arg <<< "${2:-}"

IFS=' ' read -ra versions <<< "$(get_versions .)"
IFS=' ' read -ra update_versions <<< "$(get_versions . "${versions_arg[@]:-}")"
IFS=' ' read -ra update_variants <<< "$(get_variants . "${variant_arg[@]:-}")"
if [ ${#versions[@]} -eq 0 ]; then
  fatal "No valid versions found!"
fi

# Global variables
# Get architecure and use this as target architecture for docker image
# See details in function.sh
# TODO: Should be able to specify target architecture manually
arch=$(get_arch)

if [ "${SKIP}" != true ]; then
  alpine_version=$(get_config "./" "alpine_version")
  yarnVersion="$(curl -sSL --compressed https://yarnpkg.com/latest-version)"
fi

function in_versions_to_update() {
  local version=$1

  if [ "${#update_versions[@]}" -eq 0 ]; then
    echo 0
    return
  fi

  for version_to_update in "${update_versions[@]}"; do
    if [ "${version_to_update}" = "${version}" ]; then
      echo 0
      return
    fi
  done

  echo 1
}

function in_variants_to_update() {
  local variant=$1

  if [ "${#update_variants[@]}" -eq 0 ]; then
    echo 0
    return
  fi

  for variant_to_update in "${update_variants[@]}"; do
    if [ "${variant_to_update}" = "${variant}" ]; then
      echo 0
      return
    fi
  done

  echo 1
}

function update_node_version() {

  local baseuri=${1}
  shift
  local version=${1}
  shift
  local template=${1}
  shift
  local dockerfile=${1}
  shift
  local variant=""
  if [ $# -eq 1 ]; then
    variant=${1}
    shift
  fi

  fullVersion="$(curl -sSL --compressed "${baseuri}" | grep '<a href="v'"${version}." | sed -E 's!.*<a href="v([^"/]+)/?".*!\1!' | cut -d'.' -f2,3 | sort -n | tail -1)"
  (
    cp "${template}" "${dockerfile}-tmp"
    local fromprefix=""
    if [ "${arch}" != "amd64" ] && [ "${variant}" != "onbuild" ]; then
      fromprefix="${arch}\\/"
    fi

    nodeVersion="${version}.${fullVersion:-0}"

    sed -Ei -e 's/^FROM (.*)/FROM '"$fromprefix"'\1/' "${dockerfile}-tmp"
    sed -Ei -e 's/^(ENV NODE_VERSION ).*/\1'"${nodeVersion}"'/' "${dockerfile}-tmp"

    if [ "${SKIP}" = true ]; then
      # Get the currently used Yarn version
      yarnVersion="$(grep "ENV YARN_VERSION" "${dockerfile}" | cut -d' ' -f3)"
    fi
    sed -Ei -e 's/^(ENV YARN_VERSION ).*/\1'"${yarnVersion}"'/' "${dockerfile}-tmp"

    # Only for onbuild variant
    sed -Ei -e 's/^(FROM .*node:)[^-]*(-.*)/\1'"${nodeVersion}"'\2/' "${dockerfile}-tmp"

    # shellcheck disable=SC1004
    new_line=' \\\
'

    # Add GPG keys
    for key_type in "node" "yarn"; do
      while read -r line; do
        pattern='"\$\{'$(echo "${key_type}" | tr '[:lower:]' '[:upper:]')'_KEYS\[@\]\}"'
        sed -Ei -e "s/([ \\t]*)(${pattern})/\\1${line}${new_line}\\1\\2/" "${dockerfile}-tmp"
      done < "keys/${key_type}.keys"
      sed -Ei -e "/${pattern}/d" "${dockerfile}-tmp"
    done

    if [ "${variant}" = "alpine" ]; then
      if [ "${SKIP}" = true ]; then
        # Get the currently used Alpine version
        alpine_version=$(grep "FROM" "${dockerfile}" | cut -d':' -f2)
      fi
      sed -Ei -e "s/(alpine:)0.0/\\1${alpine_version}/" "${dockerfile}-tmp"
    fi

    # Required for POSIX sed
    if [ -f "${dockerfile}-tmp-e" ]; then
      rm "${dockerfile}-tmp-e"
    fi
    mv -f "${dockerfile}-tmp" "${dockerfile}"
  )
}

function add_stage() {
  local baseuri=${1}
  shift
  local version=${1}
  shift
  local variant=${1}
  shift

  echo '
    - stage: Build
      before_script: *auto_skip
      env:
        - NODE_VERSION: "'"${version}"'"
        - VARIANT: "'"${variant}"'"' >> .travis.yml
  if [ "alpine" = "${variant}" ]; then
    echo '
      after_success:
        - ccache -s
      addons:
        apt:
          packages:
            - netcat
      before_cache:
        - mv ccache/new-cache.tar.gz ccache/cache.tar.gz
      cache:
        directories:
          - ccache/' >> .travis.yml
  fi
}

echo '# DO NOT MODIFY. THIS FILE IS AUTOGENERATED #
' | cat - travis.yml.template > .travis.yml

for version in "${versions[@]}"; do
  parentpath=$(dirname "${version}")
  versionnum=$(basename "${version}")
  baseuri=$(get_config "${parentpath}" "baseuri")
  update_version=$(in_versions_to_update "${version}")

  [ "${update_version}" -eq 0 ] && info "Updating version ${version}..."

  # Get supported variants according the target architecture
  # See details in function.sh
  IFS=' ' read -ra variants <<< "$(get_variants "${parentpath}")"

  if [ -f "${version}/Dockerfile" ]; then
    add_stage "${baseuri}" "${version}" "default"

    if [ "${update_version}" -eq 0 ]; then
      update_node_version "${baseuri}" "${versionnum}" "${parentpath}/Dockerfile.template" "${version}/Dockerfile" &
    fi
  fi

  for variant in "${variants[@]}"; do
    # Skip non-docker directories
    [ -f "${version}/${variant}/Dockerfile" ] || continue
    add_stage "${baseuri}" "${version}" "${variant}"

    update_variant=$(in_variants_to_update "${variant}")

    if [ "${update_version}" -eq 0 ] && [ "${update_variant}" -eq 0 ]; then
      update_node_version "${baseuri}" "${versionnum}" "${parentpath}/Dockerfile-${variant}.template" "${version}/${variant}/Dockerfile" "${variant}" &
    fi
  done
done

wait
info "Done!"
