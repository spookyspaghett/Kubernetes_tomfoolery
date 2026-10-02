# Kubernetes tomfoolery

Scripts that build a small kubeadm cluster (1 master, up to 3 workers) on
Ubuntu/Debian VMs, using containerd as the runtime and Flannel as the CNI.

## Network layout

The VLAN is `10.0.0.0/24`: gateway `10.0.0.1`, DHCP server `10.0.0.2` handing out
`.3`–`.254`. DHCP leases aren't stable enough for Kubernetes, so each node claims
a static address itself:

1. It probes `10.0.0.3`–`10.0.0.19` with ARP (`arping`, which also sees hosts that
   ignore ping) and takes the first free address.
2. It pins that address in `/etc/netplan/60-k8s-static.yaml` (DHCP off on that NIC;
   default route and DNS are kept if DHCP had put them there).
3. Re-runs keep the pinned address.

Workers find the master by scanning the same range for a Kubernetes API on port
6443, so **set up the master first**. Worker names follow the address: `.4` →
`worker1`, `.5` → `worker2`, and so on.

> **Run the scripts from the VM console or inside `tmux`.** Switching address drops
> an SSH session on the old DHCP address; the scripts refuse to start in that case.

**Caveat:** `.3`–`.19` are still inside the DHCP pool. Most DHCP servers check that
an address is unused before offering it, but if you can, exclude `.3`–`.19` from the
pool (or add reservations) so nothing else is ever handed one of these addresses.

## Usage

Copy the whole `scripts/` directory (including `lib/`) to every node.

1. On the master:
   ```bash
   sudo ./scripts/master_startup.sh
   ```
2. On each worker (needs SSH key access to the master, see below):
   ```bash
   sudo ./scripts/worker_startup.sh
   ```

Both scripts **wipe any existing Kubernetes state** on the node before setting it up,
so they can be re-run to rebuild a node from scratch. Nodes set up by the older
Docker + cri-dockerd version of these scripts are migrated automatically (cri-dockerd
is removed and Docker is stopped and disabled).

### SSH requirement for workers

Workers fetch a fresh join command from the master over SSH. The user that runs
`sudo` on the worker needs key-based access to `osboxes@<master-ip>`, and that user
needs passwordless sudo on the master:

```bash
ssh-copy-id osboxes@<master-ip>
```

## Configuration

Defaults can be overridden with environment variables, e.g.
`sudo IFACE=enp0s3 ./scripts/master_startup.sh`.

| Variable             | Default            | Used by        |
|----------------------|--------------------|----------------|
| `MASTER_IP`          | auto-discovered    | worker         |
| `WORKER_NAME`        | from IP            | worker         |
| `MASTER_USER`        | `osboxes`          | worker         |
| `MASTER_HOSTNAME`    | `master`           | master         |
| `IFACE`              | `enp0s8`           | both           |
| `CLUSTER_SUBNET`     | `10.0.0.`          | both           |
| `STATIC_FIRST`       | `3`                | both           |
| `STATIC_LAST`        | `19`               | both           |
| `GATEWAY`            | `<subnet>.1`       | both           |
| `PREFIX_LEN`         | `24`               | both           |
| `POD_CIDR`           | `10.244.0.0/16`    | master         |
| `K8S_VERSION`        | `v1.29`            | both           |
| `FLANNEL_MANIFEST`   | latest release URL | master         |
| `PAUSE_IMAGE`        | `registry.k8s.io/pause:3.9` | both    |
