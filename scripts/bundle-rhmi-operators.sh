#!/usr/bin/env bash

# Prereq:
# - opm
# - operator-sdk
# - oc (optional if OC_INSTALL is set)
# Function:
# Script creates olm bundles and indexes for RHOAM
# Usage:
# make create/olm/bundle OLM_TYPE=<managed||managed-api> UPGRADE=<true||false> BUNDLE_VERSIONS=<VERSION_n, VERSION_n-X...> ORG=<QUAY ORG> REG=<REGISTRY>
# OLM_TYPE - must be specified, refers to type of operator lifecycle manager type, can be managed-api-service (RHOAM)
# UPGRADE - defaults to false, if upgrade is false the oldest version specified in the BUNDLE_VERSIONS will have it's replaces removed, otherwise, replaces will stay
# BUNDLE_VERSIONS - specifies the versions that are going to have the bundles build. Versions must exists in the bundle/OLM_TYPE folder and must be listed in a descending order
# ORG - organization of where to push the bundles and indexes 
# REG - registry of where to push the bundles and indexes, defaults to quay.io
# BUILD_TOOL - tool used for building the bundle and index, defaults to docker
# OC_INSTALL - set to true if you want the catalogue source to be created pointing to the "oldest" version within the versions specified (version must have no replaces field)(must be oc logged in)
# OVERWRITE - set to true to overwrite any existing bundle/index image tags from the specified ORG
# Example:
# make create/olm/bundle OLM_TYPE=managed-api-service UPGRADE=false BUNDLE_VERSIONS=1.16.0,1.15.2 ORG=mstoklus

if [[ -z "$OLM_TYPE" ]]; then
  OLM_TYPE="managed-api-service"
fi

case $OLM_TYPE in
  "managed-api-service")
    LATEST_VERSION=$(grep $OLM_TYPE bundles/$OLM_TYPE/$OLM_TYPE.package.yaml | awk -F v '{print $3}')
    ;;
  "multitenant-managed-api-service")
    LATEST_VERSION=$(grep $OLM_TYPE bundles/$OLM_TYPE/$OLM_TYPE.package.yaml | awk -F v '{print $3}')
    ;;
  *)
    printf "Invalid OLM_TYPE set\n"
    printf "Use either \"managed-api-service\" or \"multitenant-managed-api-service\""
    exit 1
    ;;
esac

ORG="${ORG}"
REG="${REG:-quay.io}"
BUILD_TOOL="${BUILD_TOOL:-docker}"
UPGRADE_RHOAM="${UPGRADE:-false}"
VERSIONS="${BUNDLE_VERSIONS:-$LATEST_VERSION}"
CATALOG_SOURCE_INSTALL="${OC_INSTALL:-false}"
ROOT=$(pwd)
INDEX=""
OLDEST_IMAGE=""
OVERWRITE="${OVERWRITE:-false}"

start() {
  clean_up
  create_work_area
  copy_bundles
  check_upgrade_install
  generate_bundles
  generate_index
  if [ "$CATALOG_SOURCE_INSTALL" = true ] ; then
  create_catalog_source
  fi
  clean_up
  printf "Index images are:\n%s\n" "$INDEX"
}

create_work_area() {
  printf "Creating Work Area \n"
  cd ./bundles/$OLM_TYPE/ || exit
  mkdir temp && cd temp || exit
}

copy_bundles() {
  for i in $(echo $VERSIONS | sed "s/,/ /g")
  do
      printf "Copying bundle version: %s\n" "$i"
      cp -R ../"$i" ./
  done
}

# Remove the replaces field in the csv to allow for a single bundle install or an upgrade install. i.e.
# The install will not require a previous version to replace.
check_upgrade_install() {
  if [ "$UPGRADE_RHOAM" = true ] ; then
    # We can return as the csv will have the replaces field by default
    printf "Not removing replaces field in CSV\n"
    return
  fi
  # Get the oldest version, example: VERSIONS="2.5,2.4,2.3" oldest="2.3"
  OLDEST_VERSION=${VERSIONS##*,}
  file="$(ls "./$OLDEST_VERSION/manifests" | grep .clusterserviceversion.yaml)"

  sed '/replaces/d' './'$OLDEST_VERSION'/manifests/'$file > newfile ; mv newfile './'$OLDEST_VERSION'/manifests/'$file

  OLDEST_IMAGE=$REG/$ORG/${OLM_TYPE}-index:$OLDEST_VERSION
}

# Generates a bundle for each of the version specified or, the latest version if no BUNDLE_VERSIONS  specified
generate_bundles() {
  printf "Generating Bundle \n"

  for VERSION in $(echo $VERSIONS | sed "s/,/ /g")
  do
    # Checks if script should preserve existing bundle images at $REG/$ORG/${OLM_TYPE}-bundle:$VERSION
    # If the bundle image doesn't already exist, it will be created
    # If the bundle image does already exist, the script continues to the next VERSION
    if [ "$OVERWRITE" = false ] ; then
      exists="$($BUILD_TOOL manifest inspect "$REG/$ORG/${OLM_TYPE}-bundle:$VERSION" > /dev/null ; echo $?)"
      # Expression will 0 on success (image does exist) and 1 on failure (image does not exist)
      if [[ "$exists" -eq "0" ]] ; then
        printf "Not building or pushing this bundle image because it already exists and OVERWRITE is set to false: %s\n" "$REG/$ORG/${OLM_TYPE}-bundle:$VERSION"
        continue
      fi
    fi
    pwd
    cd ../../..
    $BUILD_TOOL build -f ./bundles/$OLM_TYPE/bundle.Dockerfile -t "$REG/$ORG/${OLM_TYPE}-bundle:$VERSION" --build-arg manifest_path="./bundles/$OLM_TYPE/temp/$VERSION/manifests" --build-arg metadata_path="./bundles/$OLM_TYPE/temp/$VERSION/metadata" --build-arg version="$VERSION" .
    $BUILD_TOOL push "$REG/$ORG/${OLM_TYPE}-bundle:$VERSION"
    operator-sdk bundle validate "$REG/$ORG/${OLM_TYPE}-bundle:$VERSION"
    cd ./bundles/${OLM_TYPE}/temp || exit
  done
}

# calls the push index differently for a single version install or upgrade scenario
generate_index() {
  if [[ " ${VERSIONS[@]} " > 1 ]]; then
    INITIAL_VERSION=${VERSIONS##*,}
    push_index "$INITIAL_VERSION"
    push_index "$VERSIONS"
  else
    push_index "$VERSIONS"
  fi
}

# builds and pushes the index for each version included
push_index() {
  VERSIONS_TO_PUSH=$1
  bundles=""
  for VERSION in $(echo "$VERSIONS_TO_PUSH" | sed "s/,/ /g")
  do
      bundles=$bundles"$REG/$ORG/${OLM_TYPE}-bundle:$VERSION,"
  done
  # remove last comma
  bundles=${bundles%?}

  NEWEST_VERSION="$( cut -d ',' -f 1 <<< "$VERSIONS_TO_PUSH" )"
  INDEX_IMAGE=$REG/$ORG/${OLM_TYPE}-index:$NEWEST_VERSION

  # Checks if script should preserve existing index images at $REG/$ORG/${OLM_TYPE}-index:$NEWEST_VERSION
  # If the index image doesn't already exist, it will be created
  # If the index image does already exist, the script continues
  if [ "$OVERWRITE" = false ] ; then
    exists="$($BUILD_TOOL manifest inspect "$INDEX_IMAGE" > /dev/null ; echo $?)"
    # exists will by 0 on success (image does exist) and 1 on failure (image does not exist)
    if [ "$exists" -eq "0" ] ; then
      printf "Not building or pushing this index image because it already exists and OVERWRITE is set to false: %s\n" "$INDEX_IMAGE"
      INDEX="$INDEX $INDEX_IMAGE"
      return
    fi
  fi

  opm index add \
      --bundles "$bundles" \
      --container-tool "$BUILD_TOOL" \
      --tag "$REG/$ORG/${OLM_TYPE}-index:$NEWEST_VERSION"

  printf "Pushing index image: %s\n" "$INDEX_IMAGE"
  $BUILD_TOOL push "$INDEX_IMAGE"

  INDEX="$INDEX $INDEX_IMAGE"
}

# creates catalog source on the cluster
create_catalog_source() {
  printf "Creating catalog source using: %s\n" "$OLDEST_IMAGE"
  cd "$ROOT" || exit
  oc delete catalogsource rhmi-operators -n openshift-marketplace --ignore-not-found=true
  oc process -p INDEX_IMAGE="$OLDEST_IMAGE"  -f ./config/olm/catalog-source-template.yml | oc apply -f - -n openshift-marketplace
}

# cleans up the working space
clean_up() {
  printf "Cleaning up work area \n"
  rm -rf "$ROOT/bundles/$OLM_TYPE/temp"
}

start