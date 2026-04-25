# RCCL AINIC Test Suite

Scripts for building and running RCCL collective bandwidth tests on AMD AINIC (ionic) clusters.

---

## Files

| File | Purpose |
|------|---------|
| `build_rccl_ainic.sh` | Build OpenMPI, RCCL (ainic branch), and rccl-tests from source |
| `run_rccl_ainic.sh`   | Run RCCL collective tests across one or more node groups in parallel |
| `gpu_ainic_mapper.py` | Map GPU to AINIC (ionic) NIC topology — verify pairing and firmware |

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
Group 1    380.5
Group 2    382.1
```

The reported value is the **bus bandwidth** (`busbw`) extracted from the 16G (17179869184 bytes) message size result line.

---

## GPU to AINIC Mapper (`gpu_ainic_mapper.py`)

Verifies that each GPU is paired with a co-located ionic NIC on the same PCIe root complex, and reports driver/firmware versions.

### Requirements

- `lspci`, `ethtool`, `rdma`, `amd-smi` must be installed and in `PATH`
- Run as root or with sufficient privileges

### Usage

```bash
./gpu_ainic_mapper.py
```

### Example output

```
GPU #  | Root Complex   | GPU BDF        | OAM ID | NIC BDF        | NIC #  | RDMA Dev     | Netdev     | Driver Ver       | Firmware Ver       | Status
------ + -------------- + -------------- + ------ + -------------- + ------ + ------------ + ---------- + ---------------- + ------------------ + ----------
0      | pci0000:00     | 0000:05:00.0   | 6      | 0000:09:00.0   | 0      | ionic_0      | enp9s0     | 26.03.27.001     | 1.117.5-a-82       | MATCH
1      | pci0000:10     | 0000:15:00.0   | 7      | 0000:19:00.0   | 1      | ionic_1      | enp25s0    | 26.03.27.001     | 1.117.5-a-82       | MATCH
2      | pci0000:60     | 0000:65:00.0   | 5      | 0000:69:00.0   | 2      | ionic_2      | enp105s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
3      | pci0000:70     | 0000:75:00.0   | 4      | 0000:79:00.0   | 3      | ionic_3      | enp121s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
4      | pci0000:80     | 0000:85:00.0   | 2      | 0000:89:00.0   | 4      | ionic_4      | enp137s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
5      | pci0000:90     | 0000:95:00.0   | 3      | 0000:99:00.0   | 5      | ionic_5      | enp153s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
6      | pci0000:e0     | 0000:e5:00.0   | 1      | 0000:e9:00.0   | 6      | ionic_6      | enp233s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
7      | pci0000:f0     | 0000:f5:00.0   | 0      | 0000:f9:00.0   | 7      | ionic_7      | enp249s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
```

All 8 GPUs show `MATCH` — each is paired with an ionic NIC on the same root complex. `UNPAIRED` means a GPU or NIC has no co-located peer, which indicates a hardware or driver issue.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Test Failed` in summary | mpirun did not start or RCCL crashed | Check `group<N>.log` for errors |
| Low bandwidth | Wrong `NCCL_IB_HCA_LIST` or GID not set | Verify `show_gid` returns 8 ionic entries with GID populated |
| MPI launch fails | Wrong `OOB_IF` | Confirm interface name with `ip link show` on the nodes |
| `librccl.so` not found | RCCL not built | Run `build_rccl_ainic.sh` first |
| SSH errors | Keys not exchanged | Ensure passwordless SSH between all nodes in the hostfile |
