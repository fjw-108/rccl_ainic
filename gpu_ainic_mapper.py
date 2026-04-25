#!/usr/bin/env python3
#
# gpu_ainic_mapper.py — Maps GPU to AINIC (ionic) NIC topology on AMD MI300X nodes
#
# Usage:
#   ./gpu_ainic_mapper.py
#
# Example output:
#   GPU #  | Root Complex   | GPU BDF        | OAM ID | NIC BDF        | NIC #  | RDMA Dev     | Netdev     | Driver Ver       | Firmware Ver       | Status
#   ------ + -------------- + -------------- + ------ + -------------- + ------ + ------------ + ---------- + ---------------- + ------------------ + ----------
#   0      | pci0000:00     | 0000:05:00.0   | 6      | 0000:09:00.0   | 0      | ionic_0      | enp9s0     | 26.03.27.001     | 1.117.5-a-82       | MATCH
#   1      | pci0000:10     | 0000:15:00.0   | 7      | 0000:19:00.0   | 1      | ionic_1      | enp25s0    | 26.03.27.001     | 1.117.5-a-82       | MATCH
#   2      | pci0000:60     | 0000:65:00.0   | 5      | 0000:69:00.0   | 2      | ionic_2      | enp105s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
#   3      | pci0000:70     | 0000:75:00.0   | 4      | 0000:79:00.0   | 3      | ionic_3      | enp121s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
#   4      | pci0000:80     | 0000:85:00.0   | 2      | 0000:89:00.0   | 4      | ionic_4      | enp137s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
#   5      | pci0000:90     | 0000:95:00.0   | 3      | 0000:99:00.0   | 5      | ionic_5      | enp153s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
#   6      | pci0000:e0     | 0000:e5:00.0   | 1      | 0000:e9:00.0   | 6      | ionic_6      | enp233s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
#   7      | pci0000:f0     | 0000:f5:00.0   | 0      | 0000:f9:00.0   | 7      | ionic_7      | enp249s0   | 26.03.27.001     | 1.117.5-a-82       | MATCH
#
# Requirements: lspci, ethtool, rdma, amd-smi (must be run as root or with sufficient privileges)

import subprocess
import os
import re
import sys

# --- Discovery Logic ---

def get_pci_devices(grep_pattern):
    devices = []
    try:
        # Get full BDF with domain (0000:xx:xx.x)
        cmd = f"lspci -D -v | grep '{grep_pattern}'"
        result = subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode('utf-8')
        for line in result.strip().split('\n'):
            if not line: continue
            parts = line.split()
            if parts: devices.append(parts[0])
    except subprocess.CalledProcessError: pass
    devices.sort()
    return devices

def get_pci_root(pci_id):
    sys_path = f"/sys/bus/pci/devices/{pci_id}"
    if not os.path.exists(sys_path): return "Unknown"
    try:
        real_path = os.path.realpath(sys_path)
        # Extract full root ID (e.g., pci0000:98)
        match = re.search(r'(pci[0-9a-f]{4}:[0-9a-f]{2})', real_path)
        if match: return match.group(1)
    except Exception: return "Error"
    return "Unknown"

def get_netdev_info():
    """Parses rdma link and ethtool."""
    info_map = {}
    interface_pairs = []

    # 1. Parse 'rdma link'
    try:
        rdma_out = subprocess.check_output("rdma link", shell=True, stderr=subprocess.DEVNULL).decode('utf-8')
        for line in rdma_out.splitlines():
            parts = line.split()
            if len(parts) > 1 and parts[0] == "link":
                rdma_dev = parts[1].split('/')[0]
                if 'netdev' in parts:
                    idx = parts.index('netdev')
                    if idx + 1 < len(parts):
                        interface_pairs.append((rdma_dev, parts[idx+1]))
    except subprocess.CalledProcessError: pass

    # 2. Parse 'ethtool -i'
    for r_dev, n_dev in interface_pairs:
        try:
            ethtool_out = subprocess.check_output(f"ethtool -i {n_dev}", shell=True, stderr=subprocess.DEVNULL).decode('utf-8')
            curr_bus, curr_ver, curr_fw = None, "N/A", "N/A"
            for line in ethtool_out.splitlines():
                line = line.strip()
                if line.startswith("bus-info:"):
                    curr_bus = line.split(":", 1)[1].strip()
                    if len(curr_bus.split(':')) == 2: curr_bus = "0000:" + curr_bus
                elif line.startswith("version:"):
                    curr_ver = line.split(":", 1)[1].strip()
                elif line.startswith("firmware-version:"):
                    curr_fw = line.split(":", 1)[1].strip()
            if curr_bus:
                info_map[curr_bus] = {'name': n_dev, 'rdma': r_dev, 'ver': curr_ver, 'fw': curr_fw}
        except subprocess.CalledProcessError: continue
    return info_map

def get_amd_smi_info():
    """
    Parses 'amd-smi' output to map BDF -> OAM-ID.
    """
    oam_map = {}
    try:
        smi_out = subprocess.check_output("amd-smi", shell=True, stderr=subprocess.DEVNULL).decode('utf-8')
        lines = smi_out.splitlines()
        last_bdf = None

        for line in lines:
            line = line.strip()
            # Check for BDF line (e.g., 0000:05:00.0)
            bdf_match = re.search(r'([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9])', line)
            if bdf_match:
                last_bdf = bdf_match.group(1)
                continue

            # Check for Data line (GPU HIP OAM)
            if last_bdf:
                clean_line = line.replace('|', ' ').strip()
                parts = clean_line.split()
                if len(parts) >= 3 and parts[0].isdigit() and parts[2].isdigit():
                    oam_id = parts[2]
                    oam_map[last_bdf] = oam_id
                    last_bdf = None
    except Exception: pass
    return oam_map

def main():
    # Patterns
    gpu_pattern = "Processing.*AMD/ATI"
    nic_pattern = "Ethernet.*DSC"

    # Gather Data
    gpus = get_pci_devices(gpu_pattern)
    nics = get_pci_devices(nic_pattern)
    gpu_indices = {bdf: i for i, bdf in enumerate(gpus)}
    nic_indices = {bdf: i for i, bdf in enumerate(nics)}
    netdev_info = get_netdev_info()
    oam_info = get_amd_smi_info()

    # Grouping
    topology_map = {}
    for gpu in gpus:
        r = get_pci_root(gpu)
        if r not in topology_map: topology_map[r] = {'gpus': [], 'nics': []}
        topology_map[r]['gpus'].append(gpu)
    for nic in nics:
        r = get_pci_root(nic)
        if r not in topology_map: topology_map[r] = {'gpus': [], 'nics': []}
        topology_map[r]['nics'].append(nic)

    # --- Output Formatting ---
    # Define Column Widths
    w_gnum = 6
    w_root = 14
    w_bdf  = 14
    w_oam  = 6
    w_nnum = 6
    w_rdma = 12
    w_net  = 10
    w_ver  = 16
    w_fw   = 18
    w_stat = 10

    header_fmt = f"{{:<{w_gnum}}} | {{:<{w_root}}} | {{:<{w_bdf}}} | {{:<{w_oam}}} | {{:<{w_bdf}}} | {{:<{w_nnum}}} | {{:<{w_rdma}}} | {{:<{w_net}}} | {{:<{w_ver}}} | {{:<{w_fw}}} | {{:<{w_stat}}}"
    sep_fmt    = f"{{:-<{w_gnum}}} + {{:-<{w_root}}} + {{:-<{w_bdf}}} + {{:-<{w_oam}}} + {{:-<{w_bdf}}} + {{:-<{w_nnum}}} + {{:-<{w_rdma}}} + {{:-<{w_net}}} + {{:-<{w_ver}}} + {{:-<{w_fw}}} + {{:-<{w_stat}}}"

    # Print Headers
    print(header_fmt.format("GPU #", "Root Complex", "GPU BDF", "OAM ID", "NIC BDF", "NIC #", "RDMA Dev", "Netdev", "Driver Ver", "Firmware Ver", "Status"))
    print(sep_fmt.format("", "", "", "", "", "", "", "", "", "", ""))

    for root in sorted(topology_map.keys()):
        data = topology_map[root]
        rows = max(len(data['gpus']), len(data['nics']))

        for i in range(rows):
            # GPU Data
            g_id, g_num, oam = "---", "--", "-"
            if i < len(data['gpus']):
                g_id = data['gpus'][i]
                g_num = str(gpu_indices.get(g_id, "?"))
                oam = oam_info.get(g_id, "-")

            # NIC Data
            n_id, n_num, nd, rd, ver, fw = "---", "--", "--", "--", "--", "--"
            if i < len(data['nics']):
                n_id = data['nics'][i]
                n_num = str(nic_indices.get(n_id, "?"))
                det = netdev_info.get(n_id)
                if det:
                    nd = det.get('name', '-')
                    rd = det.get('rdma', '-')
                    ver = det.get('ver', '-')
                    fw = det.get('fw', '-')

            # Status
            stat = "MATCH" if (g_id != "---" and n_id != "---") else "UNPAIRED"

            # Print Line
            print(header_fmt.format(
                g_num, root, g_id, oam, n_id, n_num, rd, nd, ver, fw, stat
            ))

if __name__ == "__main__":
    req_cmds = ["lspci", "ethtool", "rdma", "amd-smi"]
    for cmd in req_cmds:
        if subprocess.call(f"which {cmd}", shell=True, stdout=subprocess.DEVNULL) != 0:
            print(f"Warning: '{cmd}' not found. Missing data likely.")
    main()

