#!/usr/bin/env bash

###########################################################################
# Packaging script which creates debian and RPM packages for influxdb-zabbix.
# Requirements: 
# - GOPATH must be set
# - 'fpm' must be on the path
#
#    https://github.com/voyagerwoo/influxdb-zabbix
#
# Packaging process: to install a build, simply execute:
#
#    package.sh
#
# The script will automatically determined the version number from git using
# `git describe --always --tags`
#

INSTALL_ROOT_DIR=/opt/influxdb-zabbix
CONFIG_ROOT_DIR=/etc/influxdb-zabbix
CONFIG_FILE=influxdb-zabbix.conf
PROG_LOG_DIR=/var/log/influxdb-zabbix
REGISTRY_ROOTDIR=/var/lib/influxdb-zabbix
REGISTRY_FILE=influxdb-zabbix.json
LOGROTATE_DIR=/etc/logrotate.d/

SCRIPTS_DIR=/usr/lib/influxdb-zabbix/scripts/
LOGROTATE_CONFIGURATION=scripts/influxdb-zabbix
INITD_SCRIPT=scripts/init.sh
SYSTEMD_SCRIPT=scripts/influxdb-zabbix.service

TMP_WORK_DIR=$(mktemp -d)
WORK_DIR=''
POST_INSTALL_PATH=$(mktemp)
ARCH=$(uname -i)
LICENSE=MIT
URL=https://github.com/voyagerwoo/influxdb-zabbix
MAINTAINER=sqlzen@hotmail.com
VENDOR=sqlzenmonitor
DESCRIPTION="Gather data from Zabbix back-end and load to InfluxDB in near real-time"
PKG_DEPS=(coreutils)
GO_VERSION="go1.8.3"
GOPATH_INSTALL=
BINS=(
    influxdb-zabbix
    )

###########################################################################
# Helper functions.

# usage prints simple usage information.
usage() {
    echo -e "$0\n"
    cleanup_exit $1
}

# make_dir_tree creates the directory structure within the packages.
make_dir_tree() {
    work_dir=$1
	  version=$2
     
    mkdir -p $work_dir/$INSTALL_ROOT_DIR/versions/$version/scripts
    if [ $? -ne 0 ]; then
        echo "Failed to create installation directory -- aborting."
        cleanup_exit 1
    fi
    mkdir -p $work_dir/$CONFIG_ROOT_DIR
    if [ $? -ne 0 ]; then
        echo "Failed to create configuration directory -- aborting."
        cleanup_exit 1
    fi
    mkdir -p $work_dir/$PROG_LOG_DIR
    if [ $? -ne 0 ]; then
        echo "Failed to create log directory -- aborting."
        cleanup_exit 1
    fi
    mkdir -p $work_dir/$REGISTRY_ROOTDIR
    if [ $? -ne 0 ]; then
        echo "Failed to create registry directory -- aborting."
        cleanup_exit 1
    fi
    mkdir -p $work_dir/$LOGROTATE_DIR
    if [ $? -ne 0 ]; then
        echo "Failed to create log rotate temporary directory -- aborting."
        cleanup_exit 1
    fi	
	
}

# cleanup_exit removes all resources created during the process and exits with
# the supplied returned code.
cleanup_exit() {
    rm -r $TMP_WORK_DIR
    rm $POST_INSTALL_PATH
    exit $1
}

# check_gopath sanity checks the value of the GOPATH env variable, and determines
# the path where build artifacts are installed. GOPATH may be a colon-delimited
# list of directories.
check_gopath() {
    [ -z "$GOPATH" ] && echo "GOPATH is not set." && cleanup_exit 1
    GOPATH_INSTALL=`echo $GOPATH | cut -d ':' -f 1`
    [ ! -d "$GOPATH_INSTALL" ] && echo "GOPATH_INSTALL is not a directory." && cleanup_exit 1
    echo "GOPATH ($GOPATH) looks sane, using $GOPATH_INSTALL for installation."
}

# check_clean_tree ensures that no source file is locally modified.
check_clean_tree() {
    modified=$(git ls-files --modified | wc -l)
    if [ $modified -ne 0 ]; then
        echo "The source tree is not clean -- aborting."
        cleanup_exit 1
    fi
    echo "Git tree is clean."
}

# do_build builds the code. The version and commit must be passed in.
do_build() {
    version=$1
    commit=`git rev-parse HEAD`
    if [ $? -ne 0 ]; then
        echo "Unable to retrieve current commit -- aborting"
        cleanup_exit 1
    fi

    for b in ${BINS[*]}; do
        rm -f $GOPATH_INSTALL/bin/$b
    done

    #gdm restore
	echo "Building..."
    go install -ldflags="-X main.Version=$version" ./...
    if [ $? -ne 0 ]; then
        echo "Build failed, unable to create package -- aborting"
        cleanup_exit 1
    fi
	
	# copy configuration file
	echo "Copying configuration file..."
	cp ././$CONFIG_FILE $GOPATH_INSTALL/bin
	if [ $? -ne 0 ]; then
        echo "Build failed, unable to Copying configuration file -- aborting"
        cleanup_exit 1
    fi
	
    echo "Build completed successfully."
}

# generate_postinstall_script creates the post-install script for the
# package. It must be passed the version.
generate_postinstall_script() {
    version=$1
    cat  <<EOF >$POST_INSTALL_PATH
#!/bin/sh
rm -f $INSTALL_ROOT_DIR/influxdb-zabbix
rm -f $INSTALL_ROOT_DIR/init.sh
ln -sfn $INSTALL_ROOT_DIR/versions/$version/influxdb-zabbix $INSTALL_ROOT_DIR/influxdb-zabbix

if ! id influxdb-zabbix >/dev/null 2>&1; then
    useradd --help 2>&1| grep -- --system > /dev/null 2>&1
    old_useradd=\$?
    if [ \$old_useradd -eq 0 ]
    then
        useradd --system -U -M influxdb-zabbix
    else
        groupadd influxdb-zabbix && useradd -M -g influxdb-zabbix influxdb-zabbix
    fi
fi
# Systemd
if which systemctl > /dev/null 2>&1 ; then
    cp $INSTALL_ROOT_DIR/versions/$version/scripts/influxdb-zabbix.service \
        /lib/systemd/system/influxdb-zabbix.service
    systemctl enable influxdb-zabbix
    #  restart on upgrade of package
    if [ "$#" -eq 2 ]; then
        systemctl restart influxdb-zabbix
    fi
# Sysv
else
    ln -sfn $INSTALL_ROOT_DIR/versions/$version/scripts/init.sh \
        $INSTALL_ROOT_DIR/init.sh
    rm -f /etc/init.d/influxdb-zabbix
    ln -sfn $INSTALL_ROOT_DIR/init.sh /etc/init.d/influxdb-zabbix
    chmod +x /etc/init.d/influxdb-zabbix
    # update-rc.d sysv service:
    if which update-rc.d > /dev/null 2>&1 ; then
        update-rc.d -f influxdb-zabbix remove
        update-rc.d influxdb-zabbix defaults
    # CentOS-style sysv:
    else
        chkconfig --add influxdb-zabbix
    fi
    #  restart on upgrade of package
    if [ "$#" -eq 2 ]; then
        /etc/init.d/influxdb-zabbix restart
    fi
    mkdir -p $influxdb-zabbix_LOG_DIR
    chown -R -L influxdb-zabbix:influxdb-zabbix $influxdb-zabbix_LOG_DIR
fi
chown -R -L influxdb-zabbix:influxdb-zabbix $INSTALL_ROOT_DIR
chmod -R a+rX $INSTALL_ROOT_DIR

chown -R -L influxdb-zabbix:influxdb-zabbix $REGISTRY_ROOTDIR
chown -R -L influxdb-zabbix:influxdb-zabbix $PROG_LOG_DIR
EOF
    echo "Post-install script created successfully at $POST_INSTALL_PATH"
}

###########################################################################
# Start the Packaging process.

if [ "$1" == "-h" ]; then
    usage 0
elif [ "$1" == "" ]; then
    VERSION=`git describe --always --tags | tr -d v`
else
    VERSION="$1"
fi

cd `git rev-parse --show-toplevel`
echo -e "\nStarting packaging process, version: $VERSION\n"

check_gopath
do_build  $VERSION
make_dir_tree $TMP_WORK_DIR $VERSION

###########################################################################
# Copy the assets to the installation directories.

for b in ${BINS[*]}; do
    cp $GOPATH_INSTALL/bin/$b $TMP_WORK_DIR/$INSTALL_ROOT_DIR/versions/$VERSION
    if [ $? -ne 0 ]; then
        echo "Failed to copy binaries to packaging directory -- aborting."
        cleanup_exit 1
    fi
done
echo "${BINS[*]} copied to $TMP_WORK_DIR$INSTALL_ROOT_DIR/versions/$VERSION"

cp $GOPATH_INSTALL/bin/$CONFIG_FILE $TMP_WORK_DIR/$CONFIG_ROOT_DIR
if [ $? -ne 0 ]; then
    echo "Failed to copy configuration file to packaging directory -- aborting."
    cleanup_exit 1
fi
echo "$CONFIG_FILE copied to $TMP_WORK_DIR$CONFIG_ROOT_DIR"

cp $SYSTEMD_SCRIPT $TMP_WORK_DIR/$INSTALL_ROOT_DIR/versions/$VERSION/scripts
if [ $? -ne 0 ]; then
    echo "Failed to copy systemd file to packaging directory -- aborting."
    cleanup_exit 1
fi
echo "$SYSTEMD_SCRIPT copied to $TMP_WORK_DIR/$INSTALL_ROOT_DIR/scripts"

cp $INITD_SCRIPT $TMP_WORK_DIR/$INSTALL_ROOT_DIR/versions/$VERSION/scripts
if [ $? -ne 0 ]; then
    echo "Failed to copy init.d script to packaging directory -- aborting."
    cleanup_exit 1
fi
echo "$INITD_SCRIPT copied to $TMP_WORK_DIR/$INSTALL_ROOT_DIR/versions/$VERSION/scripts"

cp $LOGROTATE_CONFIGURATION $TMP_WORK_DIR/$LOGROTATE_DIR/influxdb-zabbix
if [ $? -ne 0 ]; then
    echo "Failed to copy $LOGROTATE_CONFIGURATION to packaging directory -- aborting."
    cleanup_exit 1
fi
echo "$LOGROTATE_CONFIGURATION copied to $TMP_WORK_DIR/$LOGROTATE_DIR/influxdb-zabbix"

generate_postinstall_script $VERSION

###########################################################################
# Create the actual packages.

if [ "$CIRCLE_BRANCH" == "" ]; then
    echo -n "Commence creation of $ARCH packages, version $VERSION? [Y/n] "
    read response
    response=`echo $response | tr 'A-Z' 'a-z'`
    if [ "x$response" == "xn" ]; then
        echo "Packaging aborted."
        cleanup_exit 1
    fi
fi

if [ $ARCH == "i386" ]; then
    rpm_package=influxdb-zabbix-$VERSION-1.i686.rpm
    debian_package=influxdb-zabbix_${VERSION}_i686.deb
    deb_args="-a i686"
    rpm_args="setarch i686"
elif [ $ARCH == "arm" ]; then
    rpm_package=influxdb-zabbix-$VERSION-1.armel.rpm
    debian_package=influxdb-zabbix_${VERSION}_armel.deb
else
    rpm_package=influxdb-zabbix-$VERSION-1.x86_64.rpm
    debian_package=influxdb-zabbix_${VERSION}_amd64.deb
fi

COMMON_FPM_ARGS="-C $TMP_WORK_DIR --vendor $VENDOR --url $URL --license $LICENSE \
                --maintainer $MAINTAINER --after-install $POST_INSTALL_PATH \
                --name influxdb-zabbix --provides influxdb-zabbix --version $VERSION \
				        --config-files $CONFIG_ROOT_DIR --package ./$rpm_package"
                                                        
$rpm_args fpm -s dir -t rpm --description "$DESCRIPTION" $COMMON_FPM_ARGS
if [ $? -ne 0 ]; then
    echo "Failed to create RPM package -- aborting."
    cleanup_exit 1
fi
echo "RPM package created successfully."

COMMON_FPM_ARGS="-C $TMP_WORK_DIR --vendor $VENDOR --url $URL --license $LICENSE \
                --maintainer $MAINTAINER --after-install $POST_INSTALL_PATH \
                --name influxdb-zabbix --provides influxdb-zabbix --version $VERSION \
				        --config-files $CONFIG_ROOT_DIR --package ./$debian_package"
                                                        
fpm -s dir -t deb $deb_args --description "$DESCRIPTION" $COMMON_FPM_ARGS
if [ $? -ne 0 ]; then
    echo "Failed to create Debian package -- aborting."
    cleanup_exit 1
fi
echo "Debian package created successfully."

###########################################################################
# All done.

echo -e "\nPackaging process complete."
cleanup_exit 0