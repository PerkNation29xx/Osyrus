# Vulnerability Upgrade Path Plan

Generated: 2026-04-09T07:19:08.261170Z

This plan is based on the latest Nmap + vulners scan in this portal directory.

## vm1 (192.168.12.148)

- Aggregated CVEs: **187**
- Critical/High: **17 / 56**
- Remediation complete: **0.0%**

### Upgrade Actions

- [P1] **VMware ESXi**
  - Current: VMware ESXi 7.0.3 build-21424296
  - Target: Latest vendor-patched build for this ESXi branch.
  - Path: Apply the latest ESXi offline bundle through Lifecycle Manager and reboot host in maintenance mode.
- [P1] **OpenSSH**
  - Current: 8.8
  - Target: Distro vendor package with current security fixes.
  - Path: Update openssh packages from official security repo, restart sshd, and remove weak ciphers/MACs.
- [P1] **Apache HTTP Server**
  - Current: 2.4.54
  - Target: Current distro security release with all CVE backports.
  - Path: Update apache2/httpd package, reload config, retest TLS and web app routes.
- [P2] **MySQL**
  - Current: 8.0.36-0ubuntu0.22.04.1
  - Target: Current supported MySQL minor with vendor security patches.
  - Path: Patch mysql server package, run schema compatibility checks, and validate backup + restore.
- [P1] **dnsmasq**
  - Current: 2.90
  - Target: Current distro security release of dnsmasq.
  - Path: Patch dnsmasq package, restart service, and confirm DNSSEC and cache poisoning mitigations remain enabled.
- [P1] **vCenter Server Appliance**
  - Current: VMware Photon OS/Linux
  - Target: Latest security-updated vCenter 7.x/8.x supported build.
  - Path: Take file-based backup snapshot, patch VCSA from VAMI, validate SSO/LDAP and extension services after reboot.

### Top CVEs

| CVE | CVSS | Severity | Affected Ports |
| --- | ---: | --- | --- |
| CVE-2017-14491 | 9.8 | critical | 53/tcp |
| CVE-2017-14492 | 9.8 | critical | 53/tcp |
| CVE-2017-14493 | 9.8 | critical | 53/tcp |
| CVE-2023-25690 | 9.8 | critical | 443/tcp, 80/tcp |
| CVE-2023-28531 | 9.8 | critical | 22/tcp |
| CVE-2023-38408 | 9.8 | critical | 22/tcp |
| CVE-2024-38474 | 9.8 | critical | 443/tcp, 80/tcp |
| CVE-2024-38476 | 9.8 | critical | 443/tcp, 80/tcp |
| CVE-2024-38475 | 9.1 | critical | 443/tcp, 80/tcp |
| CVE-2024-40898 | 9.1 | critical | 443/tcp, 80/tcp |

## vm2 (192.168.12.217)

- Aggregated CVEs: **15**
- Critical/High: **2 / 2**
- Remediation complete: **0.0%**

### Upgrade Actions

- [P1] **VMware ESXi**
  - Current: VMware ESXi 8.0.2 build-23305546
  - Target: Latest vendor-patched build for this ESXi branch.
  - Path: Apply the latest ESXi offline bundle through Lifecycle Manager and reboot host in maintenance mode.
- [P1] **OpenSSH**
  - Current: 9.0
  - Target: Distro vendor package with current security fixes.
  - Path: Update openssh packages from official security repo, restart sshd, and remove weak ciphers/MACs.

### Top CVEs

| CVE | CVSS | Severity | Affected Ports |
| --- | ---: | --- | --- |
| CVE-2023-28531 | 9.8 | critical | 22/tcp |
| CVE-2023-38408 | 9.8 | critical | 22/tcp |
| CVE-2024-6387 | 8.1 | high | 22/tcp |
| CVE-2026-35385 | 7.5 | high | 22/tcp |
| CVE-2025-26465 | 6.8 | medium | 22/tcp |
| CVE-2023-51385 | 6.5 | medium | 22/tcp |
| CVE-2023-48795 | 5.9 | medium | 22/tcp |
| CVE-2023-51384 | 5.5 | medium | 22/tcp |
| CVE-2026-35414 | 5.4 | medium | 22/tcp |
| CVE-2025-32728 | 4.3 | medium | 22/tcp |
