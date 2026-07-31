//go:build linux

package main

import (
	"context"
	"log"
	"os"
	"strconv"

	"github.com/launchdarkly/go-sdk-common/v3/ldvalue"

	"github.com/e2b-dev/infra/packages/orchestrator/pkg/factories"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/tcpfirewall"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/version"
	"github.com/e2b-dev/infra/packages/shared/pkg/featureflags"
)

var commitSHA string

func main() {
	applyTestFlagOverrides()
	applySelfHostedFlagOverrides()

	factories.Run(factories.Options{
		Version:       version.Version,
		CommitSHA:     commitSHA,
		EgressFactory: defaultEgressFactory,
	})
}

func applyTestFlagOverrides() {
	if mode := os.Getenv("TESTS_MEMFILE_DIFF_DEDUP_MODE"); mode != "" {
		featureflags.OverrideJSONFlag(featureflags.MemfileDiffDedupFlag, ldvalue.FromJSONMarshal(map[string]any{
			"enabled":    true,
			"bestEffort": mode == "best_effort",
			"directIO":   mode == "direct_io",
		}))
	}
	if os.Getenv("TESTS_DISABLE_MEMFD") == "true" {
		featureflags.OverrideBoolFlag(featureflags.UseMemFdFlag, false)
	}
}

// applySelfHostedFlagOverrides lets terraform set flags that upstream only
// exposes through LaunchDarkly. Self-hosted deployments have no LD project, so
// the offline store's code default is otherwise the only reachable value.
//
// BUILD_CACHE_MAX_USAGE_PERCENTAGE matters because the DiffStore mmaps its
// cache files — the cache is resident in memory — while eviction triggers on
// *disk* usage. The local NVMe carrying /orchestrator ships with the VM SKU and
// is an order of magnitude larger than RAM, so the 85% default is unreachable
// and the cache grows until an mmap fails with ENOMEM. Lowering the percentage
// is what converts the disk watermark into a memory budget:
//
//	percentage = (non-cache baseline + cache budget) / disk size * 100
//
// It must stay above the non-cache baseline of that filesystem, or eviction can
// never satisfy the check and empties the cache on every pass.
func applySelfHostedFlagOverrides() {
	if v := os.Getenv("BUILD_CACHE_MAX_USAGE_PERCENTAGE"); v != "" {
		pct, err := strconv.Atoi(v)
		if err != nil || pct <= 0 || pct > 100 {
			// Refusing a bad value keeps the upstream default, which only ever
			// caches too much — silently applying 0 would disable caching.
			log.Printf("ignoring BUILD_CACHE_MAX_USAGE_PERCENTAGE=%q: want an integer in 1..100", v)
		} else {
			featureflags.OverrideIntFlag(featureflags.BuildCacheMaxUsagePercentage, pct)
			log.Printf("build-cache-max-usage-percentage overridden to %d%%", pct)
		}
	}
}

func defaultEgressFactory(_ context.Context, deps *factories.Deps) (*factories.EgressSetup, error) {
	fw := tcpfirewall.New(
		deps.Logger,
		deps.Config.NetworkConfig,
		deps.Sandboxes,
		deps.MeterProvider,
		deps.FeatureFlags,
	)

	return &factories.EgressSetup{
		Proxy: fw,
		Start: fw.Start,
		Close: fw.Close,
	}, nil
}
