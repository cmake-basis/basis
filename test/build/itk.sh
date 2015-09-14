#!/bin/bash
set -e

## Travis script to install ITK

version=${1:-4.8.0}
prefix=${2:-/opt/itk-$version}

# Install from binary package when $version equals major version number only
# and if binary package for given OS is available
if [[ $TRAVIS_OS_NAME == linux ]]; then
  if [[ $version == 3 ]]; then
    exec sudo apt-get install -qq libgdcm2-dev libvtkgdcm2-dev libfftw3-dev libvtk5-dev libinsighttoolkit3-dev
  fi
fi

if [[ $version == 3 ]]; then
  version=3.20.1
elif [[ $version == 4 ]]; then
  version=4.8.0
fi

# Download and extract source files
wget -O InsightToolkit-${version}.tar.gz http://sourceforge.net/projects/itk/files/itk/${version%.*}/InsightToolkit-${version}.tar.gz/download
tar xzf InsightToolkit-${version}.tar.gz

# Configure build
cd InsightToolkit-$version
mkdir build && cd build

if [ ${version/.*} -ge 4 ]; then
  cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DITK_BUILD_DEFAULT_MODULES=OFF \
        -DITKGroup_Core=ON \
        -DITKGroup_IO=ON \
        ..
else
  cmake -Wno-dev \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DITK_USE_SYSTEM_TIFF=ON \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_SHARED_LIBS=ON \
        ..
fi

# Build and install
make -j8 install