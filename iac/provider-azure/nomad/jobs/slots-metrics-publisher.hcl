job "slots-metrics-publisher" {
  type      = "service"
  node_pool = "${node_pool}"

  group "publisher" {
    count = 1

    task "publisher" {
      driver = "raw_exec"

      config {
        command = "/usr/bin/python3"
        args    = ["local/publish_slots.py"]
      }

      env {
        SLOTS_API_URL                = "${api_url}"
        SLOTS_ADMIN_TOKEN            = "${admin_token}"
        SLOTS_VMSS_RESOURCE_ID       = "${vmss_resource_id}"
        SLOTS_REGION                 = "${region}"
        SLOTS_NODE_PREFIX            = "${node_prefix}"
        SLOTS_MAX_SANDBOXES_PER_NODE = "${max_sandboxes_per_node}"
        SLOTS_INTERVAL_SECONDS       = "${interval_seconds}"
        SLOTS_RECLAIM_ENABLED        = "${reclaim_enabled}"
        SLOTS_RECLAIM_BELOW_PCT      = "${reclaim_below_pct}"
        SLOTS_RECLAIM_MIN_NODES      = "${reclaim_min_nodes}"
        SLOTS_SCALE_OUT_PCT          = "${scale_out_pct}"
      }

      # Consul-template delimiters are moved off {{ }} so the Python below is
      # passed through untouched.
      template {
        left_delimiter  = "[[["
        right_delimiter = "]]]"
        destination     = "local/publish_slots.py"
        perms           = "0755"
        data            = <<-PYEOF
          #!/usr/bin/env python3
          """Publish per-node sandbox slot utilisation as an Azure Monitor custom metric.

          Autoscale on the client pool cannot be driven by any platform metric.
          The two limits that actually bind are invisible to them:

            * the per-node sandbox count cap (a count -- no host metric reflects it)
            * the hugepage pool sandbox memory is carved from. It is preallocated
              at boot, so handing pages to sandboxes never moves MemAvailable:
              the pool can be full while the host reports ~half its RAM free.

          So we compute utilisation ourselves from what the orchestrator already
          reports through the API's /nodes endpoint, and publish it as a single
          0-100 gauge that an autoscale rule can act on.

          The same loop also decides which node, if any, autoscale is allowed to
          take. See reconcile_reclaim() for why that cannot be left to Azure.
          """
          import json
          import os
          import sys
          import time
          import urllib.error
          import urllib.request

          API_URL = os.environ["SLOTS_API_URL"].rstrip("/")
          ADMIN_TOKEN = os.environ["SLOTS_ADMIN_TOKEN"]
          VMSS_RESOURCE_ID = os.environ["SLOTS_VMSS_RESOURCE_ID"]
          REGION = os.environ["SLOTS_REGION"]
          NODE_PREFIX = os.environ["SLOTS_NODE_PREFIX"]
          MAX_SANDBOXES = int(os.environ.get("SLOTS_MAX_SANDBOXES_PER_NODE", "200"))
          INTERVAL = int(os.environ.get("SLOTS_INTERVAL_SECONDS", "60"))

          RECLAIM_ENABLED = os.environ.get("SLOTS_RECLAIM_ENABLED", "false").lower() == "true"
          RECLAIM_BELOW_PCT = float(os.environ.get("SLOTS_RECLAIM_BELOW_PCT", "30"))
          RECLAIM_MIN_NODES = int(os.environ.get("SLOTS_RECLAIM_MIN_NODES", "1"))
          SCALE_OUT_PCT = float(os.environ.get("SLOTS_SCALE_OUT_PCT", "70"))

          METRIC_NAMESPACE = "e2b"
          IMDS_URL = (
              "http://169.254.169.254/metadata/identity/oauth2/token"
              "?api-version=2018-02-01"
              "&resource="
          )
          MONITORING_AUDIENCE = "https%3A%2F%2Fmonitoring.azure.com%2F"
          MANAGEMENT_AUDIENCE = "https%3A%2F%2Fmanagement.azure.com%2F"
          INGEST_URL = "https://" + REGION + ".monitoring.azure.com" + VMSS_RESOURCE_ID + "/metrics"
          ARM_BASE = "https://management.azure.com" + VMSS_RESOURCE_ID
          ARM_API_VERSION = "2025-04-01"

          # Mirrors the reservation start-client.sh applies before sizing the
          # hugepage pool. Keep in sync with that script.
          MIN_RESERVED_BYTES = 4 * 1024 ** 3
          MAX_RESERVED_BYTES = 42 * 1024 ** 3
          RESERVED_PERCENT = 16

          _tokens = {}


          def log(message):
              sys.stdout.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + message + "\n")
              sys.stdout.flush()


          def hugepage_capacity_bytes(memory_total_bytes):
              """Bytes that can end up as hugepages: base pool plus overcommit.

              start-client.sh reserves a slice for normal pages and turns all the
              rest into hugepages, so this is the real ceiling on sandbox memory.
              Using HugePages_Total instead would be wrong -- it grows as surplus
              pages get allocated, so used/total never approaches 1.
              """
              reserved = memory_total_bytes * RESERVED_PERCENT // 100
              reserved = max(reserved, MIN_RESERVED_BYTES)
              reserved = min(reserved, MAX_RESERVED_BYTES)
              return max(memory_total_bytes - reserved, 1)


          def slot_utilisation_pct(node):
              """Whichever of the two walls this node is closest to."""
              metrics = node.get("metrics") or {}
              running = (node.get("sandboxCount") or 0) + (node.get("sandboxStartingCount") or 0)
              by_count = running / MAX_SANDBOXES if MAX_SANDBOXES > 0 else 0.0

              memory_total = metrics.get("memoryTotalBytes") or 0
              allocated = metrics.get("allocatedMemoryBytes") or 0
              by_memory = allocated / hugepage_capacity_bytes(memory_total) if memory_total else 0.0

              # Deliberately uncapped: a value above 100 means the node is
              # oversubscribed, and flattening that would hide the pressure.
              return max(by_count, by_memory) * 100.0


          def imds_token(audience):
              now = time.time()
              cached = _tokens.get(audience)
              if cached and cached["expires_at"] - 120 > now:
                  return cached["value"]
              request = urllib.request.Request(IMDS_URL + audience, headers={"Metadata": "true"})
              with urllib.request.urlopen(request, timeout=20) as response:
                  payload = json.load(response)
              _tokens[audience] = {
                  "value": payload["access_token"],
                  "expires_at": now + int(payload.get("expires_in", 3600)),
              }
              return _tokens[audience]["value"]


          def fetch_nodes():
              request = urllib.request.Request(
                  API_URL + "/nodes", headers={"X-Admin-Token": ADMIN_TOKEN}
              )
              with urllib.request.urlopen(request, timeout=30) as response:
                  return json.load(response)


          def set_node_status(node_id, status):
              """Draining takes a node out of placement; ready puts it back.

              placement_best_of_K skips anything that is not ready, so this is what
              stops new sandboxes landing on a node we intend to retire. It reaches
              the orchestrator over gRPC and shows up in /nodes a few seconds later.
              """
              body = json.dumps({"status": status}).encode()
              request = urllib.request.Request(
                  API_URL + "/nodes/" + node_id,
                  data=body,
                  method="POST",
                  headers={"X-Admin-Token": ADMIN_TOKEN, "Content-Type": "application/json"},
              )
              with urllib.request.urlopen(request, timeout=30) as response:
                  return response.status


          def arm_request(path, method="GET", body=None):
              url = ARM_BASE + path
              url += ("&" if "?" in path else "?") + "api-version=" + ARM_API_VERSION
              data = json.dumps(body).encode() if body is not None else None
              headers = {"Authorization": "Bearer " + imds_token(MANAGEMENT_AUDIENCE)}
              if data is not None:
                  headers["Content-Type"] = "application/json"
              request = urllib.request.Request(url, data=data, method=method, headers=headers)
              with urllib.request.urlopen(request, timeout=30) as response:
                  raw = response.read()
                  return json.loads(raw) if raw else None


          def list_instances():
              """instanceId -> current protectFromScaleIn flag."""
              payload = arm_request("/virtualMachines") or {}
              instances = {}
              for item in payload.get("value", []):
                  policy = (item.get("properties") or {}).get("protectionPolicy") or {}
                  instances[str(item.get("instanceId"))] = bool(policy.get("protectFromScaleIn"))
              return instances


          def set_protection(instance_id, protect):
              """Set one instance's scale-in protection flag.

              Two things this has to work around:

                * The scale set VM resource rejects PATCH with 405, so it has to
                  be a PUT.
                * PUTting back the model you just GET-ed fails with
                  LinkedAuthorizationFailed. That model names resources outside
                  this resource group -- the subnet in particular -- and ARM then
                  demands rights on each of them, which a metrics publisher has no
                  business holding.

              A PUT carrying only location and protectionPolicy is accepted and
              leaves the rest of the instance untouched. Verified by diffing
              storageProfile, networkProfileConfiguration, hardwareProfile and
              osProfile across the call: only protectionPolicy changed.
              """
              arm_request(
                  "/virtualMachines/" + instance_id,
                  method="PUT",
                  body={
                      "location": REGION,
                      "properties": {"protectionPolicy": {"protectFromScaleIn": protect}},
                  },
              )


          def instance_id_of(node_id):
              """Nomad node IDs are '<vmss name>_<instance id>'."""
              _, _, suffix = node_id.rpartition("_")
              return suffix if suffix.isdigit() else None


          def reconcile_reclaim(nodes, utilisations):
              """Decide which node, if any, autoscale may remove.

              Azure picks its own victim and knows nothing about sandboxes, so the
              flag is what we steer it with. Every node stays protected by default
              and only a node we have already drained loses that protection.

              The obvious alternative -- protect while sandboxCount > 0, unprotect
              when it hits 0 -- races: a node that just went empty is unprotected
              for a moment, and placement can put a sandbox on it while Azure is
              deleting it. Keeping everything protected removes the race entirely,
              because an unprotected node is one placement has already been told to
              stay away from.

              Reclaim runs only when losing a node still leaves the pool below the
              scale-out threshold. Without that check the pool would shed a node,
              cross the threshold, scale straight back out, and flap.
              """
              instances = list_instances()
              by_instance = {}
              for node in nodes:
                  instance_id = instance_id_of(node["id"])
                  if instance_id is not None:
                      by_instance[instance_id] = node

              live = len(nodes)
              average = sum(utilisations.values()) / live if live else 0.0
              # What utilisation would become if this pool lost one node.
              projected = average * live / (live - 1) if live > 1 else float("inf")

              target = None
              if (
                  RECLAIM_ENABLED
                  and live > RECLAIM_MIN_NODES
                  and average < RECLAIM_BELOW_PCT
                  and projected < SCALE_OUT_PCT
              ):
                  # Emptiest node first: it is the one likeliest to finish draining.
                  target = min(
                      nodes,
                      key=lambda n: ((n.get("sandboxCount") or 0) + (n.get("sandboxStartingCount") or 0)),
                  )

              target_id = target["id"] if target else None
              for instance_id, node in sorted(by_instance.items()):
                  node_id = node["id"]
                  running = (node.get("sandboxCount") or 0) + (node.get("sandboxStartingCount") or 0)
                  draining = node.get("status") == "draining"
                  currently_protected = instances.get(instance_id, False)

                  if node_id == target_id:
                      if not draining:
                          set_node_status(node_id, "draining")
                          log("draining " + node_id + " (pool avg " + format(average, ".1f")
                              + "%, projected " + format(projected, ".1f") + "%)")
                          continue
                      # Only hand it to autoscale once it is genuinely empty.
                      if running == 0 and currently_protected:
                          set_protection(instance_id, False)
                          log("released " + node_id + " for scale-in (drained)")
                      elif running > 0 and not currently_protected:
                          # Should not happen, but never leave a populated node exposed.
                          set_protection(instance_id, True)
                          log("re-protected " + node_id + " (still has " + str(running) + " sandboxes)")
                      continue

                  # Everything else: protected, and in service.
                  if not currently_protected:
                      set_protection(instance_id, True)
                      log("protected " + node_id)
                  if draining:
                      set_node_status(node_id, "ready")
                      log("returned " + node_id + " to service")


          def publish(metric_name, series):
              body = json.dumps(
                  {
                      "time": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
                      "data": {
                          "baseData": {
                              "metric": metric_name,
                              "namespace": METRIC_NAMESPACE,
                              "dimNames": ["NodeName"],
                              "series": series,
                          }
                      },
                  }
              ).encode()
              request = urllib.request.Request(
                  INGEST_URL,
                  data=body,
                  method="POST",
                  headers={
                      "Authorization": "Bearer " + imds_token(MONITORING_AUDIENCE),
                      "Content-Type": "application/json",
                  },
              )
              with urllib.request.urlopen(request, timeout=30) as response:
                  return response.status


          def point(node_id, value):
              return {
                  "dimValues": [node_id],
                  "min": value,
                  "max": value,
                  "sum": value,
                  "count": 1,
              }


          def tick():
              nodes = [
                  node
                  for node in fetch_nodes()
                  if str(node.get("id", "")).startswith(NODE_PREFIX)
              ]
              if not nodes:
                  # Publishing nothing is the safe failure mode: autoscale treats
                  # absent data as "no signal" and leaves the pool alone, whereas
                  # publishing 0 would look like an idle pool and trigger scale-in.
                  log("no nodes matched prefix " + NODE_PREFIX + "; skipping")
                  return

              slots = []
              sandboxes = []
              summary = []
              utilisations = {}
              for node in nodes:
                  node_id = node["id"]
                  pct = slot_utilisation_pct(node)
                  running = (node.get("sandboxCount") or 0) + (node.get("sandboxStartingCount") or 0)
                  utilisations[node_id] = pct
                  slots.append(point(node_id, pct))
                  sandboxes.append(point(node_id, float(running)))
                  summary.append(node_id + "=" + format(pct, ".1f") + "%/" + str(running))

              publish("SlotsUsedPct", slots)
              publish("SandboxesRunning", sandboxes)
              log("published " + str(len(nodes)) + " node(s): " + ", ".join(summary))

              # Deliberately after publishing: a failure here must not cost us the
              # metric that scale-out depends on.
              try:
                  reconcile_reclaim(nodes, utilisations)
              except urllib.error.HTTPError as exc:
                  detail = exc.read()[:300].decode("utf-8", "replace")
                  log("reclaim HTTP " + str(exc.code) + " " + exc.reason + ": " + detail)
              except Exception as exc:
                  log("reclaim error: " + repr(exc))


          def main():
              log("publishing to " + INGEST_URL)
              log("node prefix " + NODE_PREFIX + ", cap " + str(MAX_SANDBOXES) + " sandboxes/node")
              if RECLAIM_ENABLED:
                  log("reclaim on: shed a node below " + format(RECLAIM_BELOW_PCT, ".0f")
                      + "% while projected stays under " + format(SCALE_OUT_PCT, ".0f")
                      + "%, floor " + str(RECLAIM_MIN_NODES) + " node(s)")
              else:
                  log("reclaim off: every instance stays protected from scale-in")
              while True:
                  try:
                      tick()
                  except urllib.error.HTTPError as exc:
                      detail = exc.read()[:300].decode("utf-8", "replace")
                      log("HTTP " + str(exc.code) + " " + exc.reason + ": " + detail)
                  except Exception as exc:  # keep the loop alive across transients
                      log("error: " + repr(exc))
                  time.sleep(INTERVAL)


          if __name__ == "__main__":
              main()
        PYEOF
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
