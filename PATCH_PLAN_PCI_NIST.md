# VM Lab Patch Plan (PCI / NIST Aligned)

Generated: 2026-04-09 UTC

## 1) Current Asset Inventory (VM1 + VM2)

### ESXi Hosts
| Alias | Management IP | Hypervisor Version | Build |
|---|---|---|---|
| vm1 | 192.168.12.148 | VMware ESXi 7.0.3 | 21424296 |
| vm2 | 192.168.12.217 | VMware ESXi 8.0.2 | 23305546 |

### VMs
| Host | VM | Power | IP | Hostname | Guest OS | Guest OS Version |
|---|---|---|---|---|---|---|
| vm1 | CentOS | On | - | - | CentOS 7 (64-bit) | CentOS Linux 7 (Core) |
| vm1 | CentOS2 | On | 192.168.12.89 | RedApple2 | CentOS 7 (64-bit) | CentOS Linux 7 (Core) |
| vm1 | RazasUbuntu | On | 192.168.12.96 | redapple4 | Ubuntu Linux (64-bit) | Ubuntu 22.10 |
| vm1 | infra-dns-ntp-01 | On | 192.168.12.136 | infra-dns-ntp-01 | Ubuntu Linux (64-bit) | Ubuntu 24.04.4 LTS |
| vm1 | ubuntu | On | 192.168.12.147 | redapple3 | Ubuntu Linux (64-bit) | Ubuntu 22.10 |
| vm1 | ubuntu24-cloud-base | Off | - | - | Ubuntu Linux (64-bit) | - |
| vm1 | ubuntu24-zt-01 | On | 192.168.12.236 | ubuntu24-zt-01 | Ubuntu Linux (64-bit) | Ubuntu 24.04.4 LTS |
| vm1 | vcenter | On | - | - | Other (64-bit) | - |
| vm1 | vcsa70 | On | 192.168.12.137 | vcsa70.homelab.arpa | Other 3.x or later Linux (64-bit) | VMware Photon OS/Linux |
| vm1 | win11 | On | - | - | Microsoft Windows 10 (64-bit) | - |
| vm2 | RedAppleVcenter | On | - | - | VMware ESXi 8.0 or later | - |

## 2) Running Apps + Versions (Collected from reachable Linux VMs)

### CentOS2 (192.168.12.89)
- OS: CentOS Linux 7 (Core), kernel `3.10.0-1160.el7.x86_64`
- Key package versions:
  - `openssl-1.0.2k-19.el7`
- Running services include: `sshd`, `firewalld`, `postfix`, `rsyslog`, `NetworkManager`, `vmtoolsd`

### RazasUbuntu (192.168.12.96)
- OS: Ubuntu 22.10, kernel `5.19.0-46-generic`
- Key package versions:
  - `apache2 2.4.54-2ubuntu1.2`
  - `mysql-server 8.0.36-0ubuntu0.22.04.1`
  - `python3 3.10.6-1`
  - `openssl 3.0.5-2ubuntu2.3`
  - `dnsmasq 2.90`
- Running services include: `apache2`, `mysql`, `ssh`, `NetworkManager`, `unattended-upgrades`

### infra-dns-ntp-01 (192.168.12.136)
- OS: Ubuntu 24.04.4 LTS, kernel `6.8.0-106-generic`
- Key package versions:
  - `docker.io 29.1.3-0ubuntu3~24.04.1`
  - `containerd 2.2.1-0ubuntu1~24.04.2`
  - `dnsmasq 2.90-2ubuntu0.1`
  - `chrony 4.5-1ubuntu4.2`
  - `openssl 3.0.13-0ubuntu3.7`
- Running services include: `dnsmasq`, `chrony`, `docker`, `containerd`, `ssh`, `vm-portal-web`, `vm-portal-refresh`

### ubuntu (192.168.12.147)
- OS: Ubuntu 22.10, kernel `5.19.0-41-generic`
- Key package versions:
  - `python3 3.10.6-1`
  - `openssl 3.0.5-2ubuntu2.2`
- Running services include: `ssh`, `snap.microk8s.daemon-containerd`, `snap.microk8s.daemon-k8s-dqlite`

### ubuntu24-zt-01 (192.168.12.236)
- OS: Ubuntu 24.04.4 LTS, kernel `6.8.0-106-generic`
- Key package versions:
  - `docker.io 29.1.3-0ubuntu3~24.04.1`
  - `containerd 2.2.1-0ubuntu1~24.04.2`
  - `python3 3.12.3-0ubuntu2.1`
  - `openssl 3.0.13-0ubuntu3.7`
- Running services include: `docker`, `containerd`, `ssh`, `unattended-upgrades`

## 3) High-Risk Findings

1. **CentOS 7 systems in production scope** (`CentOS`, `CentOS2`) are EOL and not compliant for modern PCI/NIST patch posture.
2. **Ubuntu 22.10 systems** (`RazasUbuntu`, `ubuntu`) are non-LTS and out of standard support windows.
3. **vCenter/Windows VMs with unknown in-guest patch level** (`vcenter`, `win11`, `RedAppleVcenter`) need credentialed patch state collection.
4. **ESXi 7.0.3 on vm1** should be planned for supported target level (or uplift path) to reduce management-plane risk.

## 4) PCI / NIST Aligned Patch Policy Targets

- PCI DSS 4.0 alignment target:
  - Identify and rank vulnerabilities by risk.
  - Apply critical security patches within **30 days**.
  - Maintain evidence (scan results, patch tickets, change records).
- NIST alignment target (e.g., SI-2 / RA-5 / CM-6 control families):
  - Continuous vulnerability identification.
  - Risk-based remediation SLA.
  - Configuration baseline + exception tracking.

## 5) Server-by-Server Patch Plan

### Phase 0 (0-7 days) – Containment and Baseline
1. Enable authenticated vulnerability scanning for all reachable Linux VMs.
2. Snapshot/backup before patch waves (VM snapshot + config export).
3. Patch immediately on Ubuntu 24.04 hosts:
   - `infra-dns-ntp-01`, `ubuntu24-zt-01`: `apt update && apt full-upgrade -y`.
4. Harden and patch internet-exposed app stack on `RazasUbuntu` (Apache/MySQL host).

### Phase 1 (<=30 days) – Compliance Patch Window
1. **Migrate/upgrade EOL OSes**:
   - `CentOS` and `CentOS2` to Rocky/Alma 9 (or Ubuntu 24.04 LTS).
2. **Upgrade non-LTS Ubuntu**:
   - `RazasUbuntu` and `ubuntu` from 22.10 to 24.04 LTS (fresh deploy + data/app migration preferred).
3. Patch VMware management plane:
   - `vm2` ESXi 8.0.2 -> latest 8.0 U3 patch baseline.
   - `vm1` ESXi 7.0.3 -> supported target (preferred: 8.x compatible path).
   - `vcsa70` / vCenter appliances -> latest supported security patch level.

### Phase 2 (31-90 days) – Standardization
1. Standard OS baseline:
   - Linux: Ubuntu 24.04 LTS (or approved enterprise distro).
   - VMware: aligned ESXi + vCenter supported matrix.
2. Standard patch cadence:
   - Weekly check cycle.
   - Monthly maintenance window.
   - Emergency patch out-of-band for critical CVEs.
3. Define and enforce CIS/STIG-aligned hardening profile per server role.

## 6) Evidence Required for Audit

1. Asset inventory snapshots (portal `inventory.json` + app inventory).
2. Vulnerability scan reports before/after remediation.
3. Patch/change tickets with approval and completion timestamps.
4. Exception register for deferred patches with risk acceptance and expiry.
5. Validation records (service health checks, rollback tests, backup restore tests).

## 7) Immediate Next Execution Batch

1. Patch both Ubuntu 24.04 hosts now (`infra-dns-ntp-01`, `ubuntu24-zt-01`).
2. Build migration runbook from CentOS 7 -> supported OS for `CentOS` and `CentOS2`.
3. Build migration runbook from Ubuntu 22.10 -> 24.04 for `RazasUbuntu` and `ubuntu`.
4. Schedule ESXi/vCenter maintenance windows and compatibility checks.

