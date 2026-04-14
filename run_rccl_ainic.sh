#!/usr/bin/bash
#
# Copyright(C) Advanced Micro Devices, Inc. All rights reserved. #
# You may not use this software and documentation (if any) (collectively,
# the "Materials") except in compliance with the terms and conditions of
# the Software License Agreement included with the Materials or otherwise as
# set forth in writing and signed by you and an authorized signatory of AMD.
# If you do not have a copy of the Software License Agreement, contact your # AMD representativefor a copy.
#
# You agree that you will not reverse engineer or decompile the Materials,
# in whole or in part, except as allowed by applicable law.
# THE MATERIALS ARE DISTRIBUTED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OR
# REPRESENTATIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED.#
 # input/test params

HOST_LIST=$1
GROUP_SIZE=$2
COLLECTIVE=${3:-all_reduce}   # collective to run (all_reduce, alltoall, allgather, etc.)
DRY_RUN=$4                    # --dry-run as last arg to preview without executing

# Validate inputs
if [ -z "$HOST_LIST" ] || [ -z "$GROUP_SIZE" ]; then
    echo "Usage: $0 <hostfile> <group_size> [--dry-run]"
    echo "  hostfile: File containing one hostname per line"
    echo "  group_size: Number of nodes per group"
    echo "  --dry-run: (optional) Show groups and commands without running"
    exit 1
fi

#cat $HOST_LIST

# Read all nodes from hostfile
mapfile -t all_nodes < $HOST_LIST
TOTAL_NODES=${#all_nodes[@]}

echo "Total nodes in hostfile: $TOTAL_NODES"
echo "Group size: $GROUP_SIZE"

# Calculate number of groups and handle remainder
NUM_FULL_GROUPS=$((TOTAL_NODES / GROUP_SIZE))
REMAINDER=$((TOTAL_NODES % GROUP_SIZE))

if [ $REMAINDER -gt 0 ]; then
    NUM_GROUPS=$((NUM_FULL_GROUPS + 1))
    echo "Number of groups to test: $NUM_GROUPS ($NUM_FULL_GROUPS groups of $GROUP_SIZE nodes + 1 group of $REMAINDER nodes)"
else
    NUM_GROUPS=$NUM_FULL_GROUPS
    echo "Number of groups to test: $NUM_GROUPS (all groups have $GROUP_SIZE nodes)"
fi

# Print group summary
echo ""
echo "=== GROUP SUMMARY ==="
for ((i=0; i<NUM_GROUPS; i++)); do
    start_idx=$((i * GROUP_SIZE))

    # Determine group size
    if [ $i -eq $NUM_FULL_GROUPS ] && [ $REMAINDER -gt 0 ]; then
        current_group_size=$REMAINDER
    else
        current_group_size=$GROUP_SIZE
    fi

    # Extract nodes for this group
    group_nodes=("${all_nodes[@]:$start_idx:$current_group_size}")
    echo "Group $((i+1)) ($current_group_size nodes):"
    for node in "${group_nodes[@]}"; do
        echo "  - $node"
    done
done
echo "===================="
echo ""

# If dry-run, show commands and exit
if [ "$DRY_RUN" == "--dry-run" ]; then
    echo "=== DRY RUN: COMMANDS THAT WOULD BE EXECUTED ==="
    echo ""

    for ((i=0; i<NUM_GROUPS; i++)); do
        start_idx=$((i * GROUP_SIZE))

        # Determine group size
        if [ $i -eq $NUM_FULL_GROUPS ] && [ $REMAINDER -gt 0 ]; then
            current_group_size=$REMAINDER
        else
            current_group_size=$GROUP_SIZE
        fi

        # Extract nodes for this group
        group_nodes=("${all_nodes[@]:$start_idx:$current_group_size}")

        echo "--- Group $((i+1)) ---"
        echo "Nodes:"
        for node in "${group_nodes[@]}"; do
            echo "  - $node"
        done
        echo "Hostfile: ${RESULTS_DIR}/rccl-group$((i+1)).txt (would contain above nodes)"

        # Build the host string
        NUM_GPUS_PER_NODE=8
        local_host_str=$(printf "%s," "${group_nodes[@]/%/:${NUM_GPUS_PER_NODE}}")
        local_host_str=${local_host_str%,}
        local_num_process=$((NUM_GPUS_PER_NODE*${#group_nodes[@]}))

        echo "Number of processes: $local_num_process"
        echo "Command:"
        echo "${DIR}/ompi/install/bin/mpirun -np ${local_num_process} -N 8 --allow-run-as-root --hostfile ${RESULTS_DIR}/rccl-group$((i+1)).txt --bind-to numa [... NCCL flags ...] ${DIR}/rccl-tests/build/${COLLECTIVE}_perf -b 2K -e 16G -f 2 -g 1 -n 20 -c 1 -w 5"
        echo ""
    done

    echo "=== END DRY RUN ==="
    exit 0
fi

# Create output directory for results
RESULTS_DIR="./rccl_results_${GROUP_SIZE}nodes_$(date +%Y%m%d_%H%M%S)"

# Clean up any previous temporary files
rm -rf ./rccl_results_${GROUP_SIZE}nodes_*/rccl-group*.txt 2>/dev/null

if [ "$DRY_RUN" != "--dry-run" ]; then
    mkdir -p $RESULTS_DIR
    echo "Results will be saved to: $RESULTS_DIR"
else
    echo "DRY RUN MODE - No tests will be executed"
fi

DIR=$PWD
echo ${DIR}

# Set global parameters from command-line arguments (used by all groups)
# COLLECTIVE already set from $3 above
START_MSG_SIZE=${5:-16}
END_MSG_SIZE=${6:-16G}
NUM_ITER=${7:-20}
NUM_WARMUP=${8:-5}
NUM_QP_PER_CHANNEL=${9:-1}

# Set other global constants
NUM_GPUS_PER_NODE=8
NCCL_IB_QPS_PER_CONNECTION=8
NUM_CHANNEL=64

echo "Test configuration:"
echo "  Collective: $COLLECTIVE"
echo "  Message size: $START_MSG_SIZE to $END_MSG_SIZE"
echo "  Iterations: $NUM_ITER (warmup: $NUM_WARMUP)"
echo ""

# Function to run RCCL test for a group
run_group_test() {
    local group_id=$1
    local start_idx=$2
    local end_idx=$3
    local group_nodes=("${@:4}")

    echo "=== Starting test for Group $group_id (nodes $start_idx-$end_idx) ==="

    # Create hostfile for this group
    local group_hostfile="${RESULTS_DIR}/rccl-group${group_id}.txt"
    printf "%s\n" "${group_nodes[@]}" > $group_hostfile

    local group_log="${RESULTS_DIR}/group${group_id}.log"

    # Prepare compute_nodes array for this group
    local compute_nodes=("${group_nodes[@]}")

    # Verify the output
    echo "Group $group_id nodes: ${compute_nodes[@]}" >> $group_log
    echo "Total nodes in group: ${#compute_nodes[@]}" >> $group_log

    local host_str=$(printf "%s," "${compute_nodes[@]/%/:${NUM_GPUS_PER_NODE}}")
    host_str=${host_str%,}
    local NUM_PROCESS=$((NUM_GPUS_PER_NODE*${#compute_nodes[@]}))

    echo "Group $group_id host_str: $host_str" >> $group_log
    echo "Group $group_id compute_nodes: ${compute_nodes[@]}" >> $group_log
    echo "Running $COLLECTIVE, channels ${NUM_CHANNEL}, qps ${NUM_QP_PER_CHANNEL} ..." >> $group_log

    local PER_NET_PEER_ARG_OPT_STR=""
    local EXT_STR=""

    local num_nodes=${#compute_nodes[@]}
    echo "Group $group_id num nodes: $num_nodes" >> $group_log

    if [[ "$num_nodes" -eq "2" ]]; then
        if [[ "$COLLECTIVE" == "alltoall" ]] || [[ "$COLLECTIVE" == "alltoallv" ]]; then
            PER_NET_PEER_ARG_OPT_STR=" -x RCCL_DISABLE_RAIL_TREES=1"
        fi
    fi

    if [[ "$COLLECTIVE" == "alltoall" ]]; then
        EXT_STR=" -x NCCL_WORK_FIFO_BYTES=17179869184"
    else
        EXT_STR="-x RCCL_LL128_FORCE_ENABLE=1"
    fi

    # Build the command
    local cli="${OMPI_INSTALL_DIR}/bin/mpirun -np ${NUM_PROCESS} -N 8 --allow-run-as-root --hostfile $group_hostfile  --bind-to numa -x NCCL_IB_GID_INDEX=1 -x NCCL_GDR_FLUSH_DISABLE=1  -x PATH=${PATH}  -x LD_LIBRARY_PATH=${LD_LIBRARY_PATH}  -x NCCL_IB_HCA=${NCCL_IB_HCA_LIST} --mca osc '^ucx' --mca btl ^vader,openib --mca pml ob1  -mca btl_tcp_if_include ${OOB_IF} --mca oob_tcp_if_include ${OOB_IF} -x NCCL_IB_QPS_PER_CONNECTION=1 -x RCCL_IB_QPS_PER_P2P=1  -x RCCL_P2P_BATCH_ENABLE=0 -x RCCL_DISABLE_REDUCE_COPY_PIPELINING=1 -x NCCL_IB_USE_INLINE=1 -x RCCL_AINIC_ROCE=1 -x RCCL_CTS_INLINE_DATA=0 -x RCCL_CTS_OFFLOAD_ENABLED=0 -x NCCL_P2P_NET_CHUNKSIZE=131072 -x NCCL_IB_TC=41 -x NCCL_IB_FIFO_TC=185  -x NCCL_IGNORE_CPU_AFFINITY=1  -x NCCL_DEBUG=VERSION  -x NCCL_MAX_P2P_NCHANNELS=16 -x NCCL_TOPO_DUMP_FILE=/tmp/system_run2_group${group_id}.txt -x NCCL_IB_USE_INLINE=1  -x NCCL_SOCKET_IFNAME=${OOB_IF} -x IONIC_LOCKFREE=all  -x NCCL_PXN_DISABLE=1   -x NCCL_DMABUF_ENABLE=0 -x LD_PRELOAD=\"${RCCL_HOME_DIR}/build/release/librccl.so.1.0\" ${RCCL_TESTS}/build/${COLLECTIVE}_perf -b 2K -e 16G -f 2 -g 1 -n ${NUM_ITER} -c 1 -w ${NUM_WARMUP}"

    echo "Executing command for Group $group_id..." >> $group_log
    echo "$cli" >> $group_log
    eval $cli >> $group_log 2>&1

    echo "=== Completed test for Group $group_id ===" | tee -a $group_log
}

# Global variables for paths
ROCM_PATH=/opt/rocm
RCCL_INSTALL_DIR=${ROCM_PATH}
OMPI_INSTALL_DIR=${DIR}/ompi/install/
RCCL_TESTS=${DIR}/rccl-tests
OOB_IF=enp193s0f0np0
RCCL_HOME_DIR=${DIR}/rccl
ANP_HOME_DIR=${DIR}/amd-anp
NCCL_IB_HCA_LIST="ionic_0,ionic_1,ionic_2,ionic_3,ionic_4,ionic_5,ionic_6,ionic_7"

export PATH=${OMPI_INSTALL_DIR}/bin:${ROCM_PATH}/bin:${PATH}
export LD_LIBRARY_PATH=${RCCL_HOME_DIR}/build/release:${OMPI_INSTALL_DIR}/lib:${LD_LIBRARY_PATH}
export NCCL_IB_ROCE_VERSION_NUM=2

# Launch all group tests in parallel
echo "=== Launching parallel tests for $NUM_GROUPS groups ==="
pids=()

for ((i=0; i<NUM_GROUPS; i++)); do
    start_idx=$((i * GROUP_SIZE))

    # For remainder group, use only remainder nodes
    if [ $i -eq $NUM_FULL_GROUPS ] && [ $REMAINDER -gt 0 ]; then
        current_group_size=$REMAINDER
        end_idx=$((start_idx + current_group_size - 1))
    else
        current_group_size=$GROUP_SIZE
        end_idx=$((start_idx + GROUP_SIZE - 1))
    fi

    # Extract nodes for this group
    group_nodes=("${all_nodes[@]:$start_idx:$current_group_size}")

    echo "Launching Group $((i+1)) (${#group_nodes[@]} nodes):"
    for node in "${group_nodes[@]}"; do
        echo "  - $node"
    done

    # Run in background and capture PID
    run_group_test $((i+1)) $((start_idx+1)) $((end_idx+1)) "${group_nodes[@]}" &
    pids+=($!)
done

# Wait for all tests to complete
echo "=== Waiting for all $NUM_GROUPS tests to complete ==="
for pid in "${pids[@]}"; do
    wait $pid
done

# Cleanup temporary hostfiles
echo "=== Cleaning up temporary files ==="
for ((i=0; i<NUM_GROUPS; i++)); do
    rm -f "${RESULTS_DIR}/rccl-group$((i+1)).txt"
done
echo "Temporary hostfiles removed"

echo ""
echo "=== ALL TESTS COMPLETED ==="
echo "Results saved in: $RESULTS_DIR"
echo ""
echo "=== RESULTS SUMMARY ==="
for ((i=0; i<NUM_GROUPS; i++)); do
    start_idx=$((i * GROUP_SIZE))

    # Determine group size for display
    if [ $i -eq $NUM_FULL_GROUPS ] && [ $REMAINDER -gt 0 ]; then
        current_group_size=$REMAINDER
    else
        current_group_size=$GROUP_SIZE
    fi

    # Extract nodes for display
    group_nodes=("${all_nodes[@]:$start_idx:$current_group_size}")

    echo "--- Group $((i+1)) ($current_group_size nodes) ---"
    for node in "${group_nodes[@]}"; do
        echo "  - $node"
    done
    echo ""
    echo "Results:"
    grep -E "^\s*17179869184\s+" "${RESULTS_DIR}/group$((i+1)).log" 2>/dev/null || echo "  Test Failed"
    echo ""
done

echo ""
echo "=== BANDWIDTH SUMMARY TABLE ==="
printf "%-10s %s\n" "Group" "${COLLECTIVE} Result (GB/s)"
printf "%-10s %s\n" "----------" "----------------------"
for ((i=0; i<NUM_GROUPS; i++)); do
    # Extract the second-to-last field from the 17179869184 line
    bandwidth=$(grep -E "^\s*17179869184\s+" "${RESULTS_DIR}/group$((i+1)).log" 2>/dev/null | awk '{print $(NF-1)}')
    if [ -z "$bandwidth" ]; then
        bandwidth="Test Failed"
    fi
    printf "%-10s %s\n" "Group $((i+1))" "$bandwidth"
done
echo ""
rm -rf ./rccl_results_${GROUP_SIZE}nodes_*/rccl-group*.txt 2>/dev/null