#!/bin/bash
BASEDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/..
echo -e "\nBASEDIR is $BASEDIR"
cd "$BASEDIR"

# Reading arguments
while getopts tcdv: option; do
    case "${option}" in
        t) TAG="-t";; # Indicates that we're releasing a public version from a tag
        c) CRON_LAUNCHED="-c";; # Simulates a CRON_LAUNCHED run
        d) DRYRUN="-d";; # Indicates a dryrun test, that does not modify anything on the network
        v) VERSION=${OPTARG};; # Gives the version string to use like -v 0.0 (else it will use the commit id)
    esac
done

VERSION_TO_REPLACE="$(grep 'params\[.appVersion' www/js/app.js | sed -E "s/[^[:digit:]]+([^\"']+).*/\1/")"
MAJOR_NUMERIC_VERSION=$(sed 's/-WIP//' <<<"$VERSION_TO_REPLACE")

if [ -n $DRYRUN ]; then
    echo "Executing script as DRYRUN"
fi
echo "Version passed to script: $VERSION"
echo "Major Numeric Version: $MAJOR_NUMERIC_VERSION"
echo -e "Version to replace: $VERSION_TO_REPLACE\n"

# Set the secret environment variables if available
# The file set_secret_environment_variables.sh should not be commited for security reasons
# It is only useful to run the scripts locally.
# Travis injects the same environment variables by itself
if [ -r "$BASEDIR/scripts/set_secret_environment_variables.sh" ]; then
  . "$BASEDIR/scripts/set_secret_environment_variables.sh"
fi

# Use the passed version number, else use the commit id
if [ -n "${VERSION}" ]; then
    echo "Packaging version $VERSION because it has been passed as an argument"
    VERSION_FOR_MOZILLA_MANIFEST="$VERSION"
    if [ -n "${TAG}" ]; then
        echo "This version is a tag : we're releasing a public version"
    fi
else
    COMMIT_ID=$(git rev-parse --short HEAD)
    VERSION="${MAJOR_NUMERIC_VERSION}commit-${COMMIT_ID}"
    # Mozilla needs a unique version string for each version it signs
    # and we have to comply with their version string : https://developer.mozilla.org/en-US/docs/Mozilla/Toolkit_version_format
    # So we need to replace every number of the commit id by another string (with 32 cars max)
    # We are allowed only a few special caracters : +*.-_ so we prefered to use capital letters
    # (hoping this string is case-sensitive)
    COMMIT_ID_FOR_MOZILLA_MANIFEST=$(echo $COMMIT_ID | tr '[0123456789]' '[ABCDEFGHIJ]')
    VERSION_FOR_MOZILLA_MANIFEST="${MAJOR_NUMERIC_VERSION}commit${COMMIT_ID_FOR_MOZILLA_MANIFEST}"
    echo "Packaging version $VERSION"
    echo "Version string for Mozilla extension signing : $VERSION_FOR_MOZILLA_MANIFEST"
fi

# Copy only the necessary files in a temporary directory
mkdir -p tmp
rm -rf tmp/*
cp -r www webextension manifest.json manifest.webapp LICENSE-GPLv3.txt service-worker.js README.md tmp/
# Remove unwanted files
rm -f tmp/www/js/lib/libzim-*dev.*

# Replace the version number everywhere
# But Chrome would only accept a numeric version number : if it's not, we only use the prefix in manifest.json
regexpNumericVersion='^[0-9\.]+$'
if [[ $VERSION =~ $regexpNumericVersion ]] ; then
   sed -i -e "s/$VERSION_TO_REPLACE/$VERSION/" tmp/manifest.json
else
   sed -i -e "s/$VERSION_TO_REPLACE/$MAJOR_NUMERIC_VERSION/" tmp/manifest.json
fi
sed -i -e "s/$VERSION_TO_REPLACE/$VERSION/" tmp/manifest.webapp
sed -i -e "s/$VERSION_TO_REPLACE/$VERSION/" tmp/service-worker.js
sed -i -e "s/$VERSION_TO_REPLACE/$VERSION/" tmp/www/js/app.js

mkdir -p build
rm -rf build/*
# Package for Chromium/Chrome
scripts/package_chrome_extension.sh $DRYRUN $TAG -v $VERSION
# Package for Firefox and Firefox OS
# We have to put a unique version string inside the manifest.json (which Chrome might not have accepted)
# So we take the original manifest again, and replace the version inside it again
cp manifest.json tmp/
sed -i -e "s/$VERSION_TO_REPLACE/$VERSION_FOR_MOZILLA_MANIFEST/" tmp/manifest.json
scripts/package_firefox_extension.sh $DRYRUN $TAG -v $VERSION
scripts/package_firefoxos_app.sh $DRYRUN $TAG -v $VERSION
cp -f ubuntu_touch/* tmp/
sed -i -e "s/$VERSION_TO_REPLACE/$VERSION/" tmp/manifest.json
scripts/package_ubuntu_touch_app.sh $DRYRUN $TAG -v $VERSION

# Change permissions on source files to match those expected by the server
chmod 644 build/*
CURRENT_DATE=$(date +'%Y-%m-%d')
if [ -n "${CRON_LAUNCHED}" ]; then
    # It's a nightly build, so rename files to include the date and remove extraneous info so that permalinks can be generated
    echo -e "\nChanging filenames because it is a nightly build..."
    for file in build/*; do
        target=$(sed -E "s/-[0-9.]+commit[^.]+/_$CURRENT_DATE/" <<<"$file")
        mv "$file" "$target"
    done
fi
if [ -z "${DRYRUN}" ]; then
    # Upload the files on master.download.kiwix.org
    echo -e "\nUploading the files to https://download.kiwix.org/nightly/$CURRENT_DATE/"
    echo "mkdir /data/download/nightly/$CURRENT_DATE" | sftp -P 30022 -o StrictHostKeyChecking=no -i ./scripts/ssh_key ci@master.download.kiwix.org
    scp -P 30022 -r -p -o StrictHostKeyChecking=no -i ./scripts/ssh_key build/* ci@master.download.kiwix.org:/data/download/nightly/$CURRENT_DATE
else
    echo -e "\n[DRYRUN] Would have uploaded these files to https://download.kiwix.org/nightly/$CURRENT_DATE/ :\n"
    ls -l build/*
fi
# If we're dealing with a release, then we should also upload some files to the release directory
if [ -n "$TAG" ]; then
    if [ -z "${DRYRUN}" ]; then
        echo -e "\nUploading the files to https://download.kiwix.org/release/"
        scp -P 30022 -r -p -o StrictHostKeyChecking=no -i ./scripts/ssh_key build/kiwix-firefoxos* ci@master.download.kiwix.org:/data/download/release/firefox-os
        scp -P 30022 -r -p -o StrictHostKeyChecking=no -i ./scripts/ssh_key build/kiwix-ubuntu-touch* ci@master.download.kiwix.org:/data/download/release/ubuntu-touch
    else
        echo -e "\n[DRRUN] Would have uploaded these files to https://download.kiwix.org/release/ :\n"
        ls -l build/kiwix-firefoxos*
        ls -l build/kiwix-ubuntu-touch*
    fi
    echo -e "\n*** DEV: Please note that Firefox and Chrome signed extension packages will need to be copied manually to the ***"
    echo -e "*** release directory once they have been signed by the respective app stores. Unsigned versions in nightly.  ***\n"
fi
