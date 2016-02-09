#!/bin/bash

SCRIPT=$(readlink -f $0)
SCRIPT_DIR=$(readlink -f $(dirname ${SCRIPT})/../)

ENABLED_BRANCHES="master 1.6 1.7"
#DOCKER_REPO="tarantool/build"
DOCKER_REPO="rtsisyk/build"

usage() {
    echo "$1"
    echo
    echo "Usage"
    echo "====="
    echo
    echo "PACK=rpm OS=fedora DIST=rawhide $0"
    echo
    echo "Please refer to README.md for additional information"
    echo
    exit 1
}

update_submodules() {
    git submodule update --init --recursive
    if [ $? -ne 0 ]; then
        echo "Failed to update submodules"
        exit -1
    fi
}

if [ "$PACK" == "none" ]; then
    echo 'Test-only mode'
    update_submodules
    if [ -f test.sh ]; then
        echo 'Found test script'
        exec bash test.sh
    fi
    exit 0
fi

echo 'Packaging mode'

[ -n "${OS}" ] || usage "Missing OS"
if [ "${OS}" == "el" ]; then
    OS=centos
fi
[ -n "${DIST}" ] || usage "Missing DIST"
[ -x ${SCRIPT_DIR}/build ] || usage "Missing ./build"

VERSION=$(git describe --long --always)
if [ -z "${VERSION}" ]; then
    echo "get describe failed"
    exit -1
fi

if [ -n "${TRAVIS_REPO_SLUG}" ]; then
    echo "Travis CI detected"
    if [ -z "${PRODUCT}" ]; then
        PRODUCT=$(echo $TRAVIS_REPO_SLUG | cut -d '/' -f 2)
    fi
    BRANCH="${TRAVIS_BRANCH}"
    if [[ ! ${ENABLED_BRANCHES} =~ "${BRANCH}" ]] ; then
        echo "Build skipped - the branch ${BRANCH} is not for packaging"
        exit 0
    fi
    if [ -z "${PACKAGECLOUD_REPO}" ]; then
        TRAVIS_REPO_USER=$(echo $TRAVIS_REPO_SLUG | cut -d '/' -f 1)
        PACKAGECLOUD_REPO=${TRAVIS_REPO_USER}/$(echo ${BRANCH} | sed -e "s/\./_/")
    fi
    update_submodules
else
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ -z "${BRANCH}" ]; then
        echo "git rev-parse failed"
        exit -1
    fi

    if [ -z "${PACKAGECLOUD_REPO}" ]; then
        PACKAGECLOUD_REPO=${USER}/$(echo ${BRANCH} | sed -e "s/\./_/")
    fi
    if [ -z "${PRODUCT}" ]; then
        origin=$(git config --get remote.origin.url)
        name=$(basename "$origin")
        PRODUCT="${name%.*}"
    fi
fi

[ -n "${PRODUCT}" ] || usage "Missing PRODUCT"

if echo "${DIST}" | grep -c '^[0-9]\+$' > /dev/null; then
    # Numeric dist, e.g. centos6 or fedora23
    OSDIST="${OS}${DIST}"
else
    # Non-numeric dist, e.g. debian-sid, ubuntu-precise, etc.
    OSDIST="${OS}-${DIST}"
fi

DOCKER_TAG=${DOCKER_REPO}:${OSDIST}
DOCKERDO="${SCRIPT_DIR}/dockerdo ${DOCKER_TAG}"

echo
echo '-----------------------------------------------------------'
echo "Product:          ${PRODUCT}"
echo "Version:          ${VERSION} (branch ${BRANCH})"
echo "Target:           ${OSDIST}"
echo "Docker Image:     ${DOCKER_TAG}"
if [ -n "${PACKAGECLOUD_TOKEN}" ]; then
    echo "PackageCloud:     ${PACKAGECLOUD_REPO}"
else
    echo "PackageCloud:     skipped - missing PACKAGECLOUD_TOKEN"
fi
echo '-----------------------------------------------------------'
echo

# Clean buildroot
echo "Cleaning buildroot"
rm -rf buildroot/
git clean -f -X -d

# Save git describe result to VERSION file
echo "Generating VERSION"
echo ${VERSION} > VERSION

ROCKSPEC=$(ls -1 *.rockspec rockspec/*-scm*.rockspec 2> /dev/null)

echo "Make version is:"
make --version

if [ "${PACK}" == "rpm" ]; then
    if [ -f "rpm/${PRODUCT}.spec" ] ; then
        echo "Found RPM: rpm/${PRODUCT}.spec"
        echo ${SCRIPT_DIR}/build PRODUCT=${PRODUCT} \
            DOCKER_REPO=${DOCKER_REPO} ${OSDIST}
        ${SCRIPT_DIR}/build PRODUCT=${PRODUCT} \
            DOCKER_REPO=${DOCKER_REPO} ${OSDIST}
    elif [ -f "${ROCKSPEC}" ]; then
        ${SCRIPT_DIR}/build PRODUCT=${PRODUCT} \
            DOCKER_REPO=${DOCKER_REPO} rock-${OSDIST}
    else
        echo "Can't find RPM spec"
        exit 1
    fi
elif [ "${PACK}" == "deb" ]; then
    if [ -d "debian/" ]; then
        echo "Found debian/"
        ${SCRIPT_DIR}/build PRODUCT=${PRODUCT} \
            DOCKER_REPO=${DOCKER_REPO} ${OSDIST}
    elif [ -f "${ROCKSPEC}" ]; then
        ${SCRIPT_DIR}/build PRODUCT=${PRODUCT} \
            DOCKER_REPO=${DOCKER_REPO} rock-${OSDIST}
    else
        echo "Can't find debian/"
        exit 1
    fi
else
    usage "Invalid PACK value"
fi

if [ $? -ne 0 ]; then
    echo "Build failed"
    exit -1
fi

RESULTS=${SCRIPT_DIR}/root/${PACK}-${OSDIST}/results/

if [ -n "${PACKAGECLOUD_TOKEN}" ]; then
    echo "Exporting packages to packagecloud.io repo ${PACKAGECLOUD_REPO}"
    if [ "${OS}" == "centos" ]; then
        # Packagecloud doesn't support CentOS, but supports RHEL
        echo "PackageCloud doesn't support ${OSDIST}"
        echo "Using repository for RHEL"
        OS=el
    elif [ "${DIST}" == "rawhide" ] || [ "${DIST}" == "sid" ]; then
        echo "PackageCloud doesn't support ${OSDIST}"
        echo "Skipping..."
        exit 0
    fi
    gem install package_cloud
    if [ "${PACK}" == "rpm" ]; then
        package_cloud push ${PACKAGECLOUD_REPO}/${OS}/${DIST}/ \
            ${RESULTS}/*[!src].rpm --skip-errors
        package_cloud push ${PACKAGECLOUD_REPO}/${OS}/${DIST}/SRPMS/ \
            ${RESULTS}/*.src.rpm --skip-errors
    elif [ "${PACK}" == "deb" ]; then
        package_cloud push ${PACKAGECLOUD_REPO}/${OS}/${DIST}/ \
            ${RESULTS}/*.deb --skip-errors
        package_cloud push ${PACKAGECLOUD_REPO}/${OS}/${DIST}/ \
            ${RESULTS}/*.dsc --skip-errors
    fi
fi
