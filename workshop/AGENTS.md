# Workshop Conventions

## Repository Purpose

Facilitator-led workshop that shows the OpenShift Custom Metrics Autoscaler (CMA, based on KEDA)
scaling a Minecraft server from zero to one replica and back, driven by a custom metric published
by an always-on proxy (`mc-waker`). The Antora courseware lives in `workshop/`; the code and
manifests it uses live in the rest of the repository.

## Structure

- `workshop/documentation/` contains all AsciiDoc courseware content (Antora component `cma-minecraft`)
- `workshop/documentation/modules/ROOT/pages/` contains the course pages in `.adoc` format
- **Deviation from the standard layout:** there are no per-step manifest directories. Pages
  reference the existing files from the repository root (`manifests/minecraft/`,
  `manifests/waker/`, `manifests/keda/`, `scripts/`, `build/mc-waker/`), because
  `scripts/bootstrap.sh` uses the same files and copies would drift. All commands assume the
  repository root as the working directory.
- Steps are progressive: 01 server, 02 waker, 03 scale to zero, 04 scale from zero (demo),
  05 optional Prometheus variant
- The playbooks (`site.yml`, `dev-site.yml`) live in `workshop/`; their content source is `./..`
  (the repository root) with `start_path: workshop/documentation`

## AsciiDoc Formatting

- Every numbered step must have a *What* and *Why* pair in bold
- Every step must have a collapsible verification block
- Use `[.console-input]` before source blocks for commands
- Use `[.console-output]` before source blocks showing expected output
- Reference YAML manifests by file path in apply commands
- Do not use em dashes. Use regular dashes (`-`) instead
- Use `'''` for horizontal rules between steps
- Cross-reference other pages with `xref:page.adoc[Label]`
- External links use `link:URL[Label]`
- Use `NOTE:`, `TIP:`, `IMPORTANT:`, `WARNING:` admonitions
- All doc links must point to `docs.redhat.com` or `docs.openshift.com`
- Use attributes from `_attributes.adoc` for version numbers
- Timings are estimates until measured on a live run; mark them "(estimate)"

## CLI Conventions

- Every `oc` command must include an explicit `--context` flag (single context: `cma`)
- Never use `oc login` inside step pages
- Manifests contain `${NAMESPACE}`: apply them with
  `envsubst '$NAMESPACE' < file.yaml | oc apply -n "$NAMESPACE" --context cma -f -`
  (restricting envsubst to `$NAMESPACE` leaves any other `${...}` untouched)
- All workshop variables are exported once in `00-setup.adoc`

## Content Rules

- Never include customer names, user names, or email addresses
- All content must be in English
- Prefer `registry.access.redhat.com` or `registry.redhat.io` images; the Minecraft server images
  (`itzg/*`) are Docker Hub only and have no Red Hat equivalent
- Use Red Hat / OpenShift-native components when they cover the use case
- Mention Red Hat products because they fit the solution, not to promote them

## YAML Conventions

- Every YAML file starts with a comment block: filename and purpose
- Use `app.kubernetes.io/part-of: mc-ragnarok` label consistently
- Include resource requests and limits on Deployments
- Include readiness and liveness probes where applicable
