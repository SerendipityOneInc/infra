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
        SLOTS_API_URL                 = "${api_url}"
        SLOTS_ADMIN_TOKEN             = "${admin_token}"
        SLOTS_VMSS_RESOURCE_ID        = "${vmss_resource_id}"
        SLOTS_REGION                  = "${region}"
        SLOTS_NODE_PREFIX             = "${node_prefix}"
        SLOTS_MAX_SANDBOXES_PER_NODE  = "${max_sandboxes_per_node}"
        SLOTS_INTERVAL_SECONDS        = "${interval_seconds}"
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

          METRIC_NAMESPACE = "e2b"
          IMDS_URL = (
              "http://169.254.169.254/metadata/identity/oauth2/token"
              "?api-version=2018-02-01"
              "&resource=https%3A%2F%2Fmonitoring.azure.com%2F"
          )
          INGEST_URL = "https://" + REGION + ".monitoring.azure.com" + VMSS_RESOURCE_ID + "/metrics"

          # Mirrors the reservation start-client.sh applies before sizing the
          # hugepage pool. Keep in sync with that script.
          MIN_RESERVED_BYTES = 4 * 1024 ** 3
          MAX_RESERVED_BYTES = 42 * 1024 ** 3
          RESERVED_PERCENT = 16

          _token = {"value": None, "expires_at": 0.0}


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


          def imds_token():
              now = time.time()
              if _token["value"] and _token["expires_at"] - 120 > now:
                  return _token["value"]
              request = urllib.request.Request(IMDS_URL, headers={"Metadata": "true"})
              with urllib.request.urlopen(request, timeout=20) as response:
                  payload = json.load(response)
              _token["value"] = payload["access_token"]
              _token["expires_at"] = now + int(payload.get("expires_in", 3600))
              return _token["value"]


          def fetch_nodes():
              request = urllib.request.Request(
                  API_URL + "/nodes", headers={"X-Admin-Token": ADMIN_TOKEN}
              )
              with urllib.request.urlopen(request, timeout=30) as response:
                  return json.load(response)


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
                      "Authorization": "Bearer " + imds_token(),
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
              for node in nodes:
                  node_id = node["id"]
                  pct = slot_utilisation_pct(node)
                  running = (node.get("sandboxCount") or 0) + (node.get("sandboxStartingCount") or 0)
                  slots.append(point(node_id, pct))
                  sandboxes.append(point(node_id, float(running)))
                  summary.append(node_id + "=" + format(pct, ".1f") + "%/" + str(running))

              publish("SlotsUsedPct", slots)
              publish("SandboxesRunning", sandboxes)
              log("published " + str(len(nodes)) + " node(s): " + ", ".join(summary))


          def main():
              log("publishing to " + INGEST_URL)
              log("node prefix " + NODE_PREFIX + ", cap " + str(MAX_SANDBOXES) + " sandboxes/node")
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
