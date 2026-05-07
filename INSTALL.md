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
gcloud auth application-default login                      # for libraries / IAP tunneling
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
git clone <this-repo> gcp-openshift   # or however you got the files
cd gcp-openshift
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
| 4 | `./scripts/03-start-crc.sh` | Configures CRC resources and runs `crc start`. Prints credentials when done. | 10–20 min |

All four scripts are idempotent — re-running them after a successful run is a no-op.

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

To get your local Helm chart or scripts onto the VM:

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
  --command='~/.local/bin/crc console --credentials'
```

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

**`helm` not found inside `05-shell.sh`**
Bootstrap was interrupted before the helm install step. Re-run `./scripts/02-bootstrap.sh`; it'll skip already-installed components and finish the rest.

**`oc login` cert error from the laptop**
Either `/etc/hosts` isn't applied (try `nslookup api.crc.testing` — should return `127.0.0.1`) or `04-tunnel.sh` isn't running. Use `--insecure-skip-tls-verify=true` as a quick check; for proper TLS, the cert was issued for `api.crc.testing`, so the hostname must match.

**`gcloud compute ssh` hangs at "Updating project ssh metadata"**
First-time SSH on a new project is slow (~30 s). Subsequent connections are fast.

**Bill creep**
Run `gcloud compute instances list --project=$GCP_PROJECT` and `gcloud compute disks list --project=$GCP_PROJECT` to spot anything left running. `99-destroy.sh` is the one-shot cleanup.
