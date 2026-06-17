#!/bin/sh -e

# only execute anything if either
# - running under orb with package = aussi
# - not running under opam at all
if [ "$ORB_BUILDING_PACKAGE" != "aussi" -a "$OPAM_PACKAGE_NAME" != "" ]; then
    exit 0;
fi

basedir=$(realpath "$(dirname "$0")"/../..)
bdir=$basedir/_build/install/default/bin
tmpd=$basedir/_build/stage
rootdir=$tmpd/rootdir
bindir=$rootdir/usr/bin
sharedir=$rootdir/usr/share/aussi
debiandir=$rootdir/DEBIAN

trap 'rm -rf $tmpd' 0 INT EXIT

mkdir -p "$bindir" "$sharedir" "$debiandir"

# stage client binary and configure script
install $bdir/aussi $bindir/aussi
install $basedir/dist/aussi-configure.sh $sharedir/aussi-configure.sh

# install debian metadata
install -m 0644 $basedir/dist/debian/control $debiandir/control
install -m 0644 $basedir/dist/debian/changelog $debiandir/changelog
install -m 0644 $basedir/dist/debian/copyright $debiandir/copyright
install -m 0755 $basedir/dist/debian/postinst $debiandir/postinst

ARCH=$(dpkg-architecture -q DEB_TARGET_ARCH)
sed -i -e "s/^Architecture:.*/Architecture: ${ARCH}/" $debiandir/control

dpkg-deb --root-owner-group --build $rootdir $basedir/aussi.deb
echo 'bin: [ "aussi.deb" ]' > $basedir/aussi.install
echo 'doc: [ "README.md" ]' >> $basedir/aussi.install
