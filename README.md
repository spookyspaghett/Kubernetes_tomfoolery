# Kubernetes tomfoolery

Scripts that build a small kubeadm cluster (1 master, up to 3 workers) on
Ubuntu/Debian VMs, using containerd as the runtime and Flannel as the CNI.

## Network layout

| Node    | IP (on `enp0s8`) |
|---------|------------------|
| master  | 10.0.0.3     |
| worker1 | 10.0.0.4     |
| worker2 | 10.0.0.5     |
| worker3 | 10.0.0.6     |

The VLAN is `10.0.0.0/24` with its gateway at `10.0.0.1`. Pod (`10.244.0.0/16`) and
service (`10.96.0.0/12`) ranges don't overlap it.

Give each node a static address, e.g. `/etc/netplan/60-cluster.yaml` on worker1:

```yaml
network:
  version: 2
  ethernets:
    enp0s8:
      addresses: [10.0.0.4/24]
      # Only if this NIC is the node's route to the internet (no separate NAT adapter):
      # routes: [{to: default, via: 10.0.0.1}]
      # nameservers: {addresses: [10.0.0.1]}
```

Then `sudo chmod 600 /etc/netplan/60-cluster.yaml && sudo netplan apply`.

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
`sudo` on the worker needs key-based access to `osboxes@10.0.0.3`, and that user
needs passwordless sudo on the master:

```bash
ssh-copy-id osboxes@10.0.0.3
```

## Configuration

Defaults can be overridden with environment variables, e.g.
`sudo MASTER_IP=10.0.0.10 IFACE=eth1 ./scripts/master_startup.sh`.

| Variable             | Default            | Used by        |
|----------------------|--------------------|----------------|
| `MASTER_IP`          | `<subnet>.3`       | both           |
| `MASTER_USER`        | `osboxes`          | worker         |
| `MASTER_HOSTNAME`    | `master`           | master         |
| `IFACE`              | `enp0s8`           | both           |
| `CLUSTER_SUBNET`     | `10.0.0.`      | both           |
| `POD_CIDR`           | `10.244.0.0/16`    | master         |
| `K8S_VERSION`        | `v1.29`            | both           |
| `FLANNEL_MANIFEST`   | latest release URL | master         |
| `PAUSE_IMAGE`        | `registry.k8s.io/pause:3.9` | both    |
