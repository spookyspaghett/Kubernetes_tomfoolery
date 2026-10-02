# Kubernetes tomfoolery

Scripts that build a small kubeadm cluster (1 master, up to 3 workers) on
Ubuntu/Debian VMs, using containerd as the runtime and Flannel as the CNI.

## Network layout

| Node    | IP (on `enp0s8`) |
|---------|------------------|
| master  | 192.168.10.3     |
| worker1 | 192.168.10.4     |
| worker2 | 192.168.10.5     |
| worker3 | 192.168.10.6     |

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
`sudo` on the worker needs key-based access to `osboxes@192.168.10.3`, and that user
needs passwordless sudo on the master:

```bash
ssh-copy-id osboxes@192.168.10.3
```

## Configuration

Defaults can be overridden with environment variables, e.g.
`sudo MASTER_IP=192.168.10.10 IFACE=eth1 ./scripts/master_startup.sh`.

| Variable             | Default            | Used by        |
|----------------------|--------------------|----------------|
| `MASTER_IP`          | `192.168.10.3`     | both           |
| `MASTER_USER`        | `osboxes`          | worker         |
| `MASTER_HOSTNAME`    | `master`           | master         |
| `IFACE`              | `enp0s8`           | both           |
| `CLUSTER_SUBNET`     | `192.168.10.`      | both           |
| `POD_CIDR`           | `10.244.0.0/16`    | master         |
| `K8S_VERSION`        | `v1.29`            | both           |
| `FLANNEL_MANIFEST`   | latest release URL | master         |
| `PAUSE_IMAGE`        | `registry.k8s.io/pause:3.9` | both    |
