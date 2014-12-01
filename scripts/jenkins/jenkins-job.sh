#!/bin/bash

BUILD_SCRIPT_VERSION="1.0.0"
BUILD_SCRIPT_NAME=`basename ${0}`

# These are used by in following functions, declare them here so that
# they are defined even when we're only sourcing this script
BUILD_TIME_STR="TIME: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} %e %S %U %P %c %w %R %F %M %x %C"

BUILD_TIMESTAMP_START=`date -u +%s`
BUILD_TIMESTAMP_OLD=${BUILD_TIMESTAMP_START}

BUILD_TIME_LOG=${BUILD_TOPDIR}/time.txt

function print_timestamp {
    BUILD_TIMESTAMP=`date -u +%s`
    BUILD_TIMESTAMPH=`date -u +%Y%m%dT%TZ`

    local BUILD_TIMEDIFF=`expr ${BUILD_TIMESTAMP} - ${BUILD_TIMESTAMP_OLD}`
    local BUILD_TIMEDIFF_START=`expr ${BUILD_TIMESTAMP} - ${BUILD_TIMESTAMP_START}`
    BUILD_TIMESTAMP_OLD=${BUILD_TIMESTAMP}
    printf "TIME: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} ${1}: ${BUILD_TIMESTAMP}, +${BUILD_TIMEDIFF}, +${BUILD_TIMEDIFF_START}, ${BUILD_TIMESTAMPH}\n" | tee -a ${BUILD_TIME_LOG}
}

function parse_job_name {
    case ${JOB_NAME} in
        luneos-stable_*)
            BUILD_VERSION="stable"
            ;;
        luneos-testing_*)
            BUILD_VERSION="testing"
            ;;
        luneos-unstable_*)
            BUILD_VERSION="unstable"
            ;;
        *)
            echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Unrecognized version in JOB_NAME: '${JOB_NAME}', it should start with luneos- and 'stable', 'testing' or 'unstable'"
            exit 1
            ;;
    esac

    case ${JOB_NAME} in
        *_a500)
            BUILD_MACHINE="a500"
            ;;
        *_grouper)
            BUILD_MACHINE="grouper"
            ;;
        *_maguro)
            BUILD_MACHINE="maguro"
            ;;
        *_mako)
            BUILD_MACHINE="mako"
            ;;
        *_qemuarm)
            BUILD_MACHINE="qemuarm"
            ;;
        *_qemux86)
            BUILD_MACHINE="qemux86"
            ;;
        *_qemux86-64)
            BUILD_MACHINE="qemux86-64"
            ;;
        *_tenderloin)
            BUILD_MACHINE="tenderloin"
            ;;
        *_workspace_*)
            # global jobs
            ;;
        *)
            echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Unrecognized machine in JOB_NAME: '${JOB_NAME}', it should end with '_a500', '_grouper', '_maguro', '_mako', '_qemuarm', '_qemux86', '_qemux86-64' or '_tenderloin'"
            exit 1
            ;;
    esac

    case ${JOB_NAME} in
        *_workspace-cleanup)
            BUILD_TYPE="cleanup"
            ;;
        *_workspace-compare-signatures)
            BUILD_TYPE="compare-signatures"
            ;;
        *_workspace-prepare)
            BUILD_TYPE="prepare"
            ;;
        *_workspace-rsync)
            BUILD_TYPE="rsync"
            ;;
        *)
            BUILD_TYPE="build"
            ;;
    esac
}

function set_images {
    case ${BUILD_MACHINE} in
        grouper|maguro|mako)
            BUILD_IMAGES="webos-ports-dev-package"
            ;;
        qemuarm|tenderloin|a500)
            BUILD_IMAGES="webos-ports-dev-image"
            ;;
        qemux86|qemux86-64)
            BUILD_IMAGES="webos-ports-dev-emulator-appliance"
            ;;
        *)
            echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Unrecognized machine: '${BUILD_MACHINE}', script doesn't know which images to build"
            exit 1
            ;;
    esac
}

function run_build {
    make update 2>&1
    export CURRENT_STAGING=0
    export WEBOS_DISTRO_BUILD_ID="${CURRENT_STAGING}-${BUILD_NUMBER}"
    cd webos-ports
    . ./setup-env
    export MACHINE="${BUILD_MACHINE}"
    bitbake -k ${BUILD_IMAGES}
    delete_unnecessary_images
}

function run_cleanup {
    if [ -d webos-ports ] ; then
        cd webos-ports;
        du -hs sstate-cache
        openembedded-core/scripts/sstate-cache-management.sh -L --cache-dir=sstate-cache -d -y || true
        du -hs sstate-cache
        rm -f bitbake.lock pseudodone
        if [ -d tmp-glibc ] ; then
            cd tmp-glibc;
            mkdir old || true
            mv -f cooker* deploy log pkgdata sstate-control stamps sysroots work work-shared abi_version qa.log saved_tmpdir cache/default-glibc cache/bb_codeparser* cache/local_file_checksum_cache.dat old || true
            #~/daemonize.sh rm -rf old
            rm -rf old
        fi
    fi
    echo "Cleanup finished"
}

function run_compare-signatures {
    cd webos-ports
    . ./setup-env
    openembedded-core/scripts/sstate-diff-machines.sh --machines="qemuarm maguro grouper a500" --targets=webos-ports-dev-image --tmpdir=tmp-glibc/;
    if [ ! -d sstate-diff ]; then mkdir sstate-diff; fi
    mv tmp-glibc/sstate-diff/* sstate-diff

    rsync -avir sstate-diff jenkins@milla.nao:~/htdocs/builds/webos-ports-master/
}

function run_prepare {
    [ -f Makefile ] && echo "Makefile exists (ok)" || wget https://raw.github.com/webOS-ports/webos-ports-setup/master/Makefile
    sed -i 's#^BRANCH_COMMON.*#BRANCH_COMMON = unstable#g' Makefile

    make update-common

    echo "UPDATE_CONFFILES_ENABLED = 1" > config.mk
    echo "RESET_ENABLED = 1" >> config.mk
    [ -d webos-ports ] && echo "webos-ports already checked out (ok)" || make setup-webos-ports 2>&1
    make update-conffiles 2>&1

    cp common/conf/local.conf webos-ports/conf/local.conf
    sed -i 's/#PARALLEL_MAKE.*/PARALLEL_MAKE = "-j 8"/'          webos-ports/conf/local.conf
    sed -i 's/#BB_NUMBER_THREADS.*/BB_NUMBER_THREADS = "4"/' webos-ports/conf/local.conf
    sed -i 's/# INHERIT += "rm_work"/INHERIT += "rm_work"/' webos-ports/conf/local.conf

    sed -i '/^DISTRO_FEED_/d' webos-ports/conf/local.conf
    echo 'DISTRO_FEED_PREFIX="luneos-unstable"' >> webos-ports/conf/local.conf
    echo 'DISTRO_FEED_URI="http://build.webos-ports.org/luneos-unstable/ipk/"' >> webos-ports/conf/local.conf

    echo 'BB_GENERATE_MIRROR_TARBALLS = "1"' >> webos-ports/conf/local.conf

    # remove default SSTATE_MIRRORS ?= "file://.* http://build.webos-ports.org/luneos-unstable/sstate-cache/PATH"
    sed -i '/^SSTATE_MIRRORS/d' webos-ports/conf/local.conf

    echo 'SSTATE_MIRRORS ?= "\
    file://.* http://build.webos-ports.org/luneos-unstable/sstate-cache/PATH \
    "' >> webos-ports/conf/local.conf

    echo 'CONNECTIVITY_CHECK_URIS = ""' >> webos-ports/conf/local.conf
    if [ ! -d webos-ports/buildhistory/ ] ; then
        cd webos-ports
        git clone git@github.com:webOS-ports/buildhistory.git
        cd buildhistory;
        git checkout -b luneos-unstable origin/webos-ports-setup
        cd ../..
    fi

    echo 'BUILDHISTORY_COMMIT ?= "1"' >> webos-ports/conf/local.conf
    echo 'BUILDHISTORY_COMMIT_AUTHOR ?= "Martin Jansa <Martin.Jansa@gmail.com>"' >> webos-ports/conf/local.conf
    echo 'BUILDHISTORY_PUSH_REPO ?= "origin luneos-unstable"' >> webos-ports/conf/local.conf

    echo 'IMAGE_FSTYPES_forcevariable = "tar.gz"' >> webos-ports/conf/local.conf
    echo 'IMAGE_FSTYPES_forcevariable_qemux86 = "tar.gz vmdk"' >> webos-ports/conf/local.conf
    echo 'IMAGE_FSTYPES_forcevariable_qemux86-64 = "tar.gz vmdk"' >> webos-ports/conf/local.conf
}

function run_rsync {
    scripts/staging_sync.sh webos-ports/tmp-glibc/deploy                                           jenkins@milla.nao:~/htdocs/builds/luneos-${BUILD_VERSION}/

    rsync -avir --delete webos-ports/sstate-cache                                                  jenkins@milla.nao:~/htdocs/builds/luneos-${BUILD_VERSION}/
    rsync -avir --no-links --exclude '*.done' --exclude git2 --exclude svn --exclude bzr downloads jenkins@milla.nao:~/htdocs/sources/
}

print_timestamp start
parse_job_name
set_images

echo "INFO: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Running: '${BUILD_TYPE}', machine: '${BUILD_MACHINE}', version: '${BUILD_VERSION}', images: '${BUILD_IMAGES}'"

case ${BUILD_TYPE} in
    cleanup)
        run_cleanup
        ;;
    compare-signatures)
        run_compare-signatures
        ;;
    prepare)
        run_prepare
        ;;
    rsync)
        run_rsync
        ;;
    build)
        run_build
        ;;
    *)
        echo "ERROR: ${BUILD_SCRIPT_NAME}-${BUILD_SCRIPT_VERSION} Unrecognized build type: '${BUILD_TYPE}', script doesn't know how to execute such job"
        exit 1
        ;;
esac
