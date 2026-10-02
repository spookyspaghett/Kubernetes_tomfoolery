# Kubernetes tomfoolery

Scripts that build a small kubeadm cluster (1 master, up to 3 workers) on
Ubuntu/Debian VMs, using containerd as the runtime and Flannel as the CNI.

## Network layout

The VLAN is `10.0.0.0/24` (VirtualBox host-only adapter at `10.0.0.1`, DHCP server
`10.0.0.2` handing out `.20`–`.254`). DHCP leases aren't stable enough for Kubernetes,
so the scripts give every node a static address on `enp0s8`:

| Node    | Address                                                    |
|---------|------------------------------------------------------------|
| master  | always `10.0.0.3`                                          |
| workers | first free address in `10.0.0.4`–`10.0.0.19`, found with ARP |

Workers probe with `arping`, which also sees hosts that ignore ping. Worker names
follow the address: `.4` → `worker1`, `.5` → `worker2`, and so on.

The address is pinned in `/etc/netplan/60-k8s-static.yaml` (DHCP off on that NIC;
default route and DNS are kept if DHCP had put them there), and re-runs keep it.

> **Run the scripts from the VM console or inside `tmux`.** Switching address drops
> an SSH session on the old DHCP address; the scripts refuse to start in that case.

The VirtualBox DHCP server's pool must start above `.19` so it never hands out a
node's address. Any old static address for the cluster NIC in another
`/etc/netplan/*.yaml` file must be removed; the scripts refuse to run until it is.

## Usage

On every node, clone the repo:

```bash
git clone https://github.com/spookyspaghett/Kubernetes_tomfoolery.git
cd Kubernetes_tomfoolery
```

Then:

1. On the master (do this first):
   ```bash
   sudo ./scripts/master_startup.sh
   ```
2. On each worker, one at a time (needs SSH key access to the master, see below):
   ```bash
   sudo ./scripts/worker_startup.sh
   ```

To pick up script changes later, run `git pull` in the repo before re-running.

Both scripts **wipe any existing Kubernetes state** on the node before setting it up,
so they can be re-run to rebuild a node from scratch. Nodes set up by the older
Docker + cri-dockerd version of these scripts are migrated automatically (cri-dockerd
is removed and Docker is stopped and disabled).

### SSH requirement for workers

Workers fetch a fresh join command from the master over SSH. The user that runs
`sudo` on the worker needs key-based access to `osboxes@10.0.0.3`, and that user
needs passwordless sudo on the master:

```bash
ssh-copy-id osboxes@10.0.0.3
```

## Configuration

Defaults can be overridden with environment variables, e.g.
`sudo IFACE=enp0s3 ./scripts/master_startup.sh`.

| Variable             | Default            | Used by        |
|----------------------|--------------------|----------------|
| `MASTER_IP`          | `<subnet>.3`       | both           |
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
