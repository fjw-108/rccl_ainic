# RCCL AINIC Test Suite

Scripts for building and running RCCL collective bandwidth tests on AMD AINIC (ionic) clusters.

---

## Files

| File | Purpose |
|------|---------|
| `build_rccl_ainic.sh` | Build OpenMPI, RCCL (ainic branch), and rccl-tests from source |
| `run_rccl_ainic.sh`   | Run RCCL collective tests across one or more node groups in parallel |

---

## Step 1: Build (`build_rccl_ainic.sh`)

### What it builds

| Component | Source | Notes |
|-----------|--------|-------|
| OpenMPI 4.1.6 | open-mpi.org | Built from source into `./ompi/install/` |
| RCCL | github.com/ROCm/rccl, branch `ainic-oob-fb67e5b` | Built into `./rccl/build/release/` |
| rccl-tests | github.com/ROCm/rccl-tests | Linked against system ROCm + built MPI |

### Prerequisites

- ROCm installed at `/opt/rocm` (change `ROCM_PATH` at top of script if different)
- `git`, `wget`, `make`, `cmake` available
- Enough disk space (~2 GB for all three builds)

### Usage

```bash
bash build_rccl_ainic.sh
```

Run once from the directory where you want the builds to live. The script is idempotent — it skips any component whose directory already exists (`ompi/`, `rccl/`, `rccl-tests/`).

### Optional overrides (edit top of script)

| Variable | Default | Description |
|----------|---------|-------------|
| `ROCM_PATH` | `/opt/rocm` | ROCm installation root |
| `build_mpi` | `1` | Set to `0` to skip OpenMPI build and use pre-installed MPI |
| `build_rccl` | `1` | Set to `0` to skip RCCL build and use pre-installed RCCL |

---

## Step 2: Configure (`run_rccl_ainic.sh`)

Before running tests, update these two lines to match your cluster:

### Line 212 — Out-of-band network interface

```bash
OOB_IF=enp193s0f0np0
```

This is the TCP interface used by MPI for coordination (not data). Set it to the management/OOB NIC name on your nodes.

```bash
# Example — find your interface name:
ip link show | grep -E "^[0-9]+:" | awk '{print $2}'
```

### Line 215 — RCCL IB/AINIC HCA list

```bash
NCCL_IB_HCA_LIST="ionic_0,ionic_1,ionic_2,ionic_3,ionic_4,ionic_5,ionic_6,ionic_7"
```

List all ionic devices to use for RCCL data traffic. Verify device names on your nodes:

```bash
ibv_devices | grep ionic
# or
show_gid | grep ionic
```

---

## Step 3: Run (`run_rccl_ainic.sh`)

### Syntax

```
bash run_rccl_ainic.sh <hostfile> <group_size> [collective] [--dry-run]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `hostfile` | yes | Text file with one hostname per line |
| `group_size` | yes | Number of nodes per test group |
| `collective` | no | rccl-tests collective to run (default: `all_reduce`) |
| `--dry-run` | no | Print group layout and commands without executing |

### Grouping rules

| Condition | Result |
|-----------|--------|
| `total_nodes % group_size == 0` | All groups are exactly `group_size` nodes |
| `total_nodes % group_size == 1` | Remainder absorbed into last group (size = `group_size + 1`) |
| `total_nodes % group_size > 1` | Extra partial group at the end |

All groups run in parallel. Results are saved under `./rccl_results_<group_size>nodes_<timestamp>/`.

### Examples

```bash
# all_reduce on 2-node groups (default collective)
bash run_rccl_ainic.sh hostfile 2

# alltoall on 40-node groups
bash run_rccl_ainic.sh hostfile 40 alltoall

# Preview group layout for allgather without running
bash run_rccl_ainic.sh hostfile 8 allgather --dry-run
```

### Supported collectives

| Value | Binary used |
|-------|-------------|
| `all_reduce` | `all_reduce_perf` |
| `alltoall` | `alltoall_perf` |
| `alltoallv` | `alltoallv_perf` |
| `allgather` | `allgather_perf` |
| `reduce_scatter` | `reduce_scatter_perf` |

---

## Output

```
rccl_results_<group_size>nodes_<timestamp>/
  group1.log      # full mpirun output for group 1
  group2.log      # full mpirun output for group 2
  ...
```

After all groups finish, the script prints a bandwidth summary table:

```
=== BANDWIDTH SUMMARY TABLE ===
Group      all_reduce Result (GB/s)
----------  ----------------------
Group 1    412.5
Group 2    398.1
```

The reported value is the **bus bandwidth** (`busbw`) extracted from the 16G (17179869184 bytes) message size result line.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Test Failed` in summary | mpirun did not start or RCCL crashed | Check `group<N>.log` for errors |
| Low bandwidth | Wrong `NCCL_IB_HCA_LIST` or GID not set | Verify `show_gid` returns 8 ionic entries with GID populated |
| MPI launch fails | Wrong `OOB_IF` | Confirm interface name with `ip link show` on the nodes |
| `librccl.so` not found | RCCL not built | Run `build_rccl_ainic.sh` first |
| SSH errors | Keys not exchanged | Ensure passwordless SSH between all nodes in the hostfile |
