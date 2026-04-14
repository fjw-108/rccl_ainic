#!/bin/bash -x

## change this if ROCm is installed in a non-standard path
ROCM_PATH=/opt/rocm

## to use pre-installed MPI, change `build_mpi` to 0 and ensure that libmpi.so exists at `MPI_INSTALL_DIR/lib`.
build_mpi=1
## MPI_INSTALL_DIR=/opt/ompi

## to use pre-installed RCCL, change `build_rccl` to 0 and ensure that librccl.so exists at`RCCL_INSTALL_DIR/lib`.
build_rccl=1
## RCCL_INSTALL_DIR=${ROCM_PATH}


WORKDIR=$PWD

MPI_DIR="${WORKDIR}/ompi/"
RCCL_INSTALL_DIR="${WORKDIR}/rccl/"
RCCL_BUILD="${WORKDIR}/rccl/build/release/"
MPI_INCLUDE="${MPI_DIR}/install/include/"
MPI_LIB_PATH="${MPI_DIR}/build/ompi/.libs/"

## building UCX and OpenMPI
if [ ${build_mpi} -eq 1 ]
then
    cd ${WORKDIR}
    if [ ! -d ompi ]
    then
        wget https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.6.tar.gz
        mkdir -p ompi

        tar -zxf openmpi-4.1.6.tar.gz -C ompi --strip-components=1
        cd ompi
        mkdir build
        cd build
        ../configure --prefix=${WORKDIR}/ompi/install --disable-oshmem --disable-mpi-fortran --enable-orterun-prefix-by-default
        make -j16 install
    fi
    MPI_INSTALL_DIR=${WORKDIR}/ompi/install
fi

echo "Buidling RCCL.."
cd ${WORKDIR}
if [ ! -d rccl ]
then
sleep 3
git clone https://github.com/ROCm/rccl.git
sleep 3
cd ${WORKDIR}/rccl
## old drop
#git checkout drop/2025-08
#new branch from Shanxin
## https://github.com/ROCm/rccl/tree/ainic-oob-fb67e5b
git checkout ainic-oob-fb67e5b
sleep 3
./install.sh -l --prefix build/ --disable-msccl-kernel
echo "Done with building RCCL..."
sleep 3
fi

echo "Buidling RCCL-Test .."
cd ${WORKDIR}
if [ ! -d rccl-tests ]
then
    echo "Start building rccl-tests..."
    sleep 3
    git clone https://github.com/ROCm/rccl-tests
    sleep 3
    cd rccl-tests
    #make MPI=1 MPI_HOME=${MPI_INSTALL_DIR} NCCL_HOME=${RCCL_INSTALL_DIR} -j
    make MPI=1 MPI_HOME=${MPI_INSTALL_DIR} NCCL_HOME=${ROCM_PATH} -j
    echo "Done building rccl-tests..."
fi
