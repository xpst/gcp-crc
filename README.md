# gcp-crc

Bash scripts that spin up a single-node OpenShift cluster (via [CRC](https://crc.dev/) — OpenShift Local) on a Google Cloud VM with nested virtualization, then drop you into a shell where `oc` and `helm` are ready to use.

Designed for short-lived evaluation work — testing `oc` CLI compatibility, deploying a Helm chart, running a few scripts, then tearing the whole thing down. Not for production.

## Why a VM instead of running CRC locally?

- 16 vCPU / 64 GB RAM beats most laptops; `helm install` and `oc new-app` are noticeably faster.
- No cluttered local state — everything lives in one VM that you delete when done.
- No Cloud DNS, no public OpenShift endpoints, no orphan load balancers. SSH in, work, leave.

## What you get

- One `n2-standard-16` VM running Rocky Linux 9 with KVM/libvirt.
- A nested CRC OpenShift cluster reachable as `api.crc.testing` from inside the VM.
- `oc` and `helm` pre-installed on the VM.
- A `05-shell.sh` entrypoint that SSHes in, logs `oc` in as `kubeadmin`, and hands you a bash prompt.

## Quick start

```sh
cp .env.example .env
$EDITOR .env                          # set GCP_PROJECT and PULL_SECRET_PATH
./scripts/00-preflight.sh
./scripts/01-provision-vm.sh
./scripts/02-bootstrap.sh
./scripts/03-start-crc.sh
./scripts/05-shell.sh                 # → kubeadmin shell on the VM
```

When you're done:

```sh
STOP_VM=1 ./scripts/10-stop-crc.sh    # pause for the day (cheap)
./scripts/99-destroy.sh               # delete entirely
```

Full step-by-step instructions, including how to install `gcloud`, where to get the Red Hat pull secret, and a troubleshooting section, are in **[INSTALL.md](./INSTALL.md)**.

## Repository layout

```
.
├── .env.example          # all configurable variables, with defaults
├── INSTALL.md            # detailed setup + troubleshooting
├── README.md             # this file
└── scripts/
    ├── lib/common.sh     # shared helpers (env loading, logging, ssh wrappers)
    ├── 00-preflight.sh   # validate gcloud auth, project, pull secret — read-only
    ├── 01-provision-vm.sh
    ├── 02-bootstrap.sh   # install KVM/libvirt, CRC, helm; copy pull secret
    ├── 03-start-crc.sh   # crc config + crc start; print credentials
    ├── 04-tunnel.sh      # OPTIONAL: SSH tunnel for laptop-side oc/helm
    ├── 05-shell.sh       # primary "use" entrypoint (kubeadmin shell on VM)
    ├── 10-stop-crc.sh    # crc stop, optionally also stop the VM
    └── 99-destroy.sh     # delete the VM
```

## Requirements

- A GCP project with billing enabled and quota for one `n2-standard-16` + 200 GB SSD.
- A Red Hat account and a `pull-secret.json` from <https://console.redhat.com/openshift/create/local>.
- `gcloud` SDK, `bash`, `ssh`, `curl` on whichever machine runs the scripts. macOS/Linux/WSL.

Cost: ≈ $0.78/hr while running, ≈ $0.04/hr stopped (boot disk only). One full day of running ≈ $19.

## Configuration

Everything is driven by `.env` at the repo root. Only `GCP_PROJECT` and `PULL_SECRET_PATH` are required; everything else (zone, VM name, CRC resource sizing, Helm version, …) has a sensible default. See `.env.example` for the full list.

## License

[GNU General Public License v3.0](./LICENSE).
