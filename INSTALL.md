# Installing CRC (OpenShift Local) on a GCP VM

A set of bash scripts that provision a GCP VM with nested virtualization, install [CRC](https://crc.dev/) inside it, and drop you into a shell where `oc` and `helm` are ready to go. Designed for short-lived (a few hours, days) evaluation work — not production.

---

## 1. What you'll end up with

```
  your laptop ──ssh──► GCP VM (Rocky 9, n2-standard-16) ──nested KVM──► CRC libvirt VM
                                                                          │
                                                              api.crc.testing:6443
                                                              *.apps-crc.testing
                                                              ├── oc, helm pre-installed on host VM
                                                              └── kubeadmin login automated
```

You SSH into the host VM and run `helm install …` and your own scripts there. The cluster's hostnames already resolve correctly inside the VM, so there's no `/etc/hosts` editing or local port forwarding to deal with.

---

## 2. Prerequisites

- A **GCP project** with billing enabled and a quota that allows one `n2-standard-16` instance with a 200 GB SSD (about $0.78/hr running, $0.04/hr stopped).
- A **Red Hat account** and a downloaded `pull-secret.json` from <https://console.redhat.com/openshift/create/local>.
- **bash** + **ssh** + **curl** on the machine running these scripts. macOS and Linux are fine; Windows users should use WSL.
- **gcloud SDK** (next section).

---

## 3. Install and authenticate gcloud

### macOS

```sh
brew install --cask google-cloud-sdk
```

### Linux

```sh
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
```

(or use your distro's package — `dnf install google-cloud-cli` on Fedora/RHEL, `apt install google-cloud-cli` on Debian/Ubuntu after adding the Google Cloud apt repo.)

### Windows

Download the installer from <https://cloud.google.com/sdk/docs/install> and run it. Or use WSL and follow the Linux instructions above.

### Authenticate

```sh
gcloud init                                                # interactive: pick account + project
gcloud services enable compute.googleapis.com --project=YOUR_PROJECT_ID
gcloud services enable iap.googleapis.com --project=YOUR_PROJECT_ID
```

Sanity check (should return successfully, even if empty):

```sh
gcloud compute instances list --project=YOUR_PROJECT_ID
```

---

## 4. One-time repo setup

```sh
git clone <this-repo> gcp-crc   # or however you got the files
cd gcp-crc
cp .env.example .env
$EDITOR .env
```

At minimum, set:

- `GCP_PROJECT` — your project ID
- `PULL_SECRET_PATH` — absolute path to the `pull-secret.json` you downloaded

Everything else has a default. See `.env.example` for what each variable does.

---

## 5. Run the scripts in order

| Step | Script | What it does | Approx. time |
|---|---|---|---|
| 1 | `./scripts/00-preflight.sh` | Validates env, gcloud auth, API enablement, pull secret, zone capability. Read-only. | <30 s |
| 2 | `./scripts/01-provision-vm.sh` | Creates the VM with nested virt and waits for SSH. | 1–2 min |
| 3 | `./scripts/02-bootstrap.sh` | SSHs in, installs KVM/libvirt, downloads CRC + helm, copies the pull secret, runs `crc setup`. | 5–10 min |
| 4 | `./scripts/03-start-crc.sh` | Configures CRC resources and runs `crc start`. Prints credentials when done. | 10–20 min first run, ~3 min afterwards |

The first `03-start-crc.sh` run downloads a ~5 GB OpenShift release bundle silently (the SSH session has no TTY, so CRC suppresses its progress bar). It's not stuck — see the troubleshooting section below.

All four scripts are idempotent — re-running them after a successful run is a no-op (or a quick status check).

---

## 6. Use the cluster (primary path: on the VM)

```sh
./scripts/05-shell.sh
```

This SSHes into the VM, logs `oc` in as `kubeadmin`, and drops you into an interactive bash shell. Inside it:

```sh
oc whoami            # → kubeadmin
oc get nodes         # → one Ready node
helm version         # → v3.x
```

To get your local Helm chart or scripts onto the VM (the `~/work/` directory is created on the VM during bootstrap):

```sh
gcloud compute scp --recurse ./your-stuff $VM_NAME:~/work/ \
  --zone=$GCP_ZONE --project=$GCP_PROJECT --tunnel-through-iap
```

(replace `$VM_NAME`, `$GCP_ZONE`, `$GCP_PROJECT` with literal values, or run from a shell that has `.env` exported).

Then back inside the `05-shell.sh` session:

```sh
helm install my-release ./work/your-stuff/chart -n demo --create-namespace
./work/your-stuff/your-script.sh
```

The OpenShift web console URL is printed at the end of `03-start-crc.sh`. You can also tunnel to it (next section).

---

## 7. Optional: laptop-side access

Use this only if you want `oc` / `helm` running on your laptop instead of the VM.

**On your laptop**, add this single line to `/etc/hosts`:

```
127.0.0.1 api.crc.testing console-openshift-console.apps-crc.testing oauth-openshift.apps-crc.testing default-route-openshift-image-registry.apps-crc.testing
```

In one terminal, open the tunnel (Ctrl-C to close):

```sh
./scripts/04-tunnel.sh
```

In another terminal:

```sh
oc login -u kubeadmin -p <password> https://api.crc.testing:6443
oc get nodes
```

The kubeadmin password was printed by `03-start-crc.sh`. Re-fetch it any time with:

```sh
gcloud compute ssh $VM_NAME --zone=$GCP_ZONE --project=$GCP_PROJECT --tunnel-through-iap \
  --command='crc console --credentials'
```

(`crc` is on PATH because `02-bootstrap.sh` added `~/.local/bin` to `~/.bashrc`.)

**Note**: ports 80 and 443 require sudo on most laptops. Override `LOCAL_HTTP_PORT=8080` and `LOCAL_HTTPS_PORT=8443` in `.env` to avoid sudo, but routes that hard-code `:443` won't work without further proxying.

---

## 8. Daily use

When you're done for the day:

```sh
./scripts/10-stop-crc.sh             # crc stop, leave VM running
STOP_VM=1 ./scripts/10-stop-crc.sh   # crc stop AND stop the VM (saves $$)
```

Stopped VM disk costs ≈ $0.04/hr ($1/day) vs ≈ $0.78/hr running.

Next morning:

```sh
gcloud compute instances start $VM_NAME --zone=$GCP_ZONE --project=$GCP_PROJECT  # if STOP_VM=1
./scripts/03-start-crc.sh                                                         # idempotent
./scripts/05-shell.sh
```

---

## 9. Teardown

When you're done with the cluster entirely:

```sh
./scripts/99-destroy.sh
```

You'll be asked to type the VM name to confirm. The script does a best-effort `crc stop`, then `gcloud compute instances delete --quiet`. Verify in the GCP console that no instances or persistent disks remain attributed to this experiment.

---

## 10. Troubleshooting

**`crc start` fails with "host CPU does not support virtualization"**
The VM was created without nested virt or on a CPU platform that doesn't support it. Verify `MIN_CPU_PLATFORM=Intel Cascade Lake` (or newer) in `.env` and re-run `01-provision-vm.sh` after destroying. Some zones don't have Cascade Lake; try `us-central1-a`, `us-east1-b`, or `europe-west4-a`.

**`crc start` rejects the pull secret**
The file at `PULL_SECRET_PATH` is empty, malformed, or expired. Re-download from <https://console.redhat.com/openshift/create/local> and re-run `02-bootstrap.sh`.

**`03-start-crc.sh` looks stuck after `Downloading bundle: …`**
It's not — `crc start` is downloading a ~4.5–5 GB OpenShift bundle from `mirror.openshift.com`. Since the SSH session is non-interactive (no TTY), CRC's progress bar is suppressed, so you only see the start and end messages. Watch progress in another terminal:

```sh
gcloud compute ssh $VM_NAME --zone=$GCP_ZONE --project=$GCP_PROJECT --tunnel-through-iap \
  --command='watch -n 2 "ls -lh ~/.crc/cache/*.crcbundle* 2>/dev/null"'
```

Realistic time on `n2-standard-16`: 5–15 min for the download, then another 5–10 min to extract and start.

**`oc: command not found` after SSHing in directly**
`oc` is shipped by CRC at `~/.crc/bin/oc` and exposed via `crc oc-env`. `02-bootstrap.sh` adds `eval "$(crc oc-env 2>/dev/null)"` to `~/.bashrc`, so any *new* shell after CRC is running picks it up automatically. If your existing shell predates that change (or you ran the bootstrap before this fix), either open a new SSH session or run `eval "$(crc oc-env)"` once. (`crc oc-env` only emits exports when `crc status` shows `OpenShift: Running`.)

**`helm` not found inside `05-shell.sh`**
Bootstrap was interrupted before the helm install step. Re-run `./scripts/02-bootstrap.sh`; it'll skip already-installed components and finish the rest.

**`oc login` cert error from the laptop**
Either `/etc/hosts` isn't applied (try `nslookup api.crc.testing` — should return `127.0.0.1`) or `04-tunnel.sh` isn't running. Use `--insecure-skip-tls-verify=true` as a quick check; for proper TLS, the cert was issued for `api.crc.testing`, so the hostname must match.

**`gcloud compute ssh` hangs at "Updating project ssh metadata"**
First-time SSH on a new project is slow (~30 s). Subsequent connections are fast.

**Bill creep**
Run `gcloud compute instances list --project=$GCP_PROJECT` and `gcloud compute disks list --project=$GCP_PROJECT` to spot anything left running. `99-destroy.sh` is the one-shot cleanup.

**`gcloud` prints "consider installing NumPy" during SSH/SCP**
Informational only. The IAP TCP forwarder runs in pure Python; NumPy makes the per-packet copy noticeably faster, which matters for `scp --recurse`. The reliable way to install it into the exact Python gcloud is using:

```sh
PYBIN="$(gcloud info --format='value(basic.python_location)')"
"$PYBIN" -m pip install --user numpy

# If that errors with "No module named pip":
"$PYBIN" -m ensurepip --user
"$PYBIN" -m pip install --user numpy

# Verify:
"$PYBIN" -c "import numpy; print(numpy.__version__)"
```

If gcloud uses your system Python (Homebrew or distro-packaged installs), you may also need to tell gcloud to look at user site-packages:

```sh
export CLOUDSDK_PYTHON_SITEPACKAGES=1   # add to ~/.bashrc / ~/.zshrc to persist
```
