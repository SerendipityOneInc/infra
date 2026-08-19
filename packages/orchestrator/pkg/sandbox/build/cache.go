//go:build linux

package build

import (
	"context"
	"fmt"
	"math"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jellydator/ttlcache/v3"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.uber.org/zap"
	"golang.org/x/sync/singleflight"
	"golang.org/x/sys/unix"

	"github.com/e2b-dev/infra/packages/orchestrator/pkg/cfg"
	"github.com/e2b-dev/infra/packages/shared/pkg/featureflags"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/units"
	"github.com/e2b-dev/infra/packages/shared/pkg/utils"
)

var (
	fallbackDiffSize = units.MBToBytes(100)

	meter                   = otel.Meter("github.com/e2b-dev/infra/packages/orchestrator/pkg/sandbox/build")
	residenceDurationMetric = utils.Must(meter.Int64Histogram("orchestrator.build.cache.residence_duration",
		metric.WithDescription("How long a diff was kept in the local build cache before eviction"),
		metric.WithUnit("s")))
	cacheEvictionScheduledMetric = utils.Must(meter.Int64Counter("e2b.infra.build_cache.eviction.scheduled",
		metric.WithDescription("Build cache diffs scheduled for eviction"),
		metric.WithUnit("{diff}")))
)

type cacheEvictionReason string

const (
	cacheEvictionReasonDisk   cacheEvictionReason = "disk"
	cacheEvictionReasonMemory cacheEvictionReason = "memory"
)

type deleteDiff struct {
	size      int64
	cancel    chan struct{}
	closeOnce sync.Once
}

type DiffStore struct {
	cachePath string
	cache     *ttlcache.Cache[DiffStoreKey, Diff]
	initGroup singleflight.Group
	cancel    func()
	config    cfg.Config
	flags     *featureflags.Client

	// pdSizes is used to keep track of the diff sizes
	// that are scheduled for deletion, as this won't show up in the disk usage.
	pdSizes map[DiffStoreKey]*deleteDiff
	pdMu    sync.RWMutex
	pdDelay time.Duration

	insertionTimes sync.Map // map[DiffStoreKey]time.Time — tracks when each diff was cached

	cgroupMemory func() (cgroupMemoryStats, error)
	memoryStats  struct {
		current atomic.Int64
		max     atomic.Int64
		anon    atomic.Int64
		file    atomic.Int64
		shmem   atomic.Int64
	}
	metricsRegistration metric.Registration
}

func NewDiffStore(
	config cfg.Config,
	flags *featureflags.Client,
	cachePath string,
	ttl, delay time.Duration,
) (*DiffStore, error) {
	err := os.MkdirAll(cachePath, 0o755)
	if err != nil {
		return nil, fmt.Errorf("failed to create cache directory: %w", err)
	}

	cache := ttlcache.New(
		ttlcache.WithTTL[DiffStoreKey, Diff](ttl),
	)

	ds := &DiffStore{
		cachePath:    cachePath,
		cache:        cache,
		cancel:       func() {},
		config:       config,
		flags:        flags,
		pdSizes:      make(map[DiffStoreKey]*deleteDiff),
		pdDelay:      delay,
		cgroupMemory: readSelfCgroupMemory,
	}
	if config.BuildCacheMemoryHighWatermarkPercentage > 0 {
		if err := ds.registerMemoryMetrics(); err != nil {
			return nil, fmt.Errorf("register build cache memory metrics: %w", err)
		}
	}

	cache.OnEviction(func(ctx context.Context, _ ttlcache.EvictionReason, item *ttlcache.Item[DiffStoreKey, Diff]) {
		if insertedAt, ok := ds.insertionTimes.LoadAndDelete(item.Key()); ok {
			duration := time.Since(insertedAt.(time.Time))
			residenceDurationMetric.Record(ctx, int64(duration.Seconds()))
		}

		buildData := item.Value()

		// buildData will be deleted by calling buildData.Close()
		defer ds.resetDelete(item.Key())

		if closeErr := buildData.Close(); closeErr != nil {
			logger.L().Warn(ctx, "failed to cleanup build data cache for item", zap.Any("item_key", item.Key()), zap.Error(closeErr))
		}
	})

	return ds, nil
}

type DiffStoreKey string

func GetDiffStoreKey(buildID string, diffType DiffType) DiffStoreKey {
	return DiffStoreKey(fmt.Sprintf("%s/%s", buildID, diffType))
}

func (s *DiffStore) Start(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	s.cancel = cancel

	go s.cache.Start()
	go s.startCacheEviction(ctx, s.config, s.flags)
}

func (s *DiffStore) Close() {
	s.cancel()
	s.cache.Stop()
	if s.metricsRegistration != nil {
		_ = s.metricsRegistration.Unregister()
	}
}

// Get returns the cached Diff for key, refreshing TTL and cancelling any
// pending eviction. Returns (nil, false) if the key isn't present.
func (s *DiffStore) Get(key DiffStoreKey) (Diff, bool) {
	s.resetDelete(key)
	item := s.cache.Get(key)
	if item == nil {
		return nil, false
	}

	return item.Value(), true
}

// GetOrCreate returns the cached Diff for key, or calls create inside a
// singleflight to construct + cache a new one. The create closure is invoked
// at most once per key across concurrent callers; on success the returned Diff
// is cached and its insertion time recorded.
func (s *DiffStore) GetOrCreate(ctx context.Context, key DiffStoreKey, create func(context.Context) (Diff, error)) (Diff, error) {
	s.resetDelete(key)

	if item := s.cache.Get(key); item != nil {
		return item.Value(), nil
	}

	v, err, _ := s.initGroup.Do(string(key), func() (any, error) {
		// Double-check: another goroutine may have cached it while we waited.
		if item := s.cache.Get(key); item != nil {
			return item.Value(), nil
		}

		insertTime := time.Now()

		diff, err := create(ctx)
		if err != nil {
			return nil, err
		}

		s.cache.Set(key, diff, ttlcache.DefaultTTL)
		s.insertionTimes.Store(diff.CacheKey(), insertTime)

		return diff, nil
	})
	if err != nil {
		return nil, fmt.Errorf("failed to create diff: %w", err)
	}

	return v.(Diff), nil
}

func (s *DiffStore) Add(d Diff) {
	s.resetDelete(d.CacheKey())
	s.cache.Set(d.CacheKey(), d, ttlcache.DefaultTTL)
	s.insertionTimes.LoadOrStore(d.CacheKey(), time.Now())
}

func (s *DiffStore) Has(d Diff) bool {
	return s.cache.Has(d.CacheKey())
}

// Lookup returns the cached Diff for the given key without initialising a new one.
// Returns (nil, false) if the key is not present in the cache.
func (s *DiffStore) Lookup(key DiffStoreKey) (Diff, bool) {
	item := s.cache.Get(key)
	if item == nil {
		return nil, false
	}

	return item.Value(), true
}

func (s *DiffStore) startCacheEviction(
	ctx context.Context,
	config cfg.Config,
	flags *featureflags.Client,
) {
	services := cfg.GetServices(config)
	memoryThreshold := config.BuildCacheMemoryHighWatermarkPercentage
	memoryReadErrorLogged := false
	memoryNoCandidateLogged := false

	getDelay := func(fast bool) time.Duration {
		if fast {
			return time.Microsecond
		}

		return time.Second
	}

	timer := time.NewTimer(getDelay(false))
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			if memoryThreshold > 0 {
				stats, err := s.cgroupMemory()
				if err != nil {
					if !memoryReadErrorLogged {
						logger.L().Error(ctx, "failed to read build cache cgroup memory", zap.Error(err))
						memoryReadErrorLogged = true
					}
				} else {
					memoryReadErrorLogged = false
					s.recordMemoryStats(stats)

					if memoryPressureExceeded(stats, s.getPendingDeletesSize(), memoryThreshold) {
						succ, deleteErr := s.deleteOldestFromCacheForReason(ctx, cacheEvictionReasonMemory)
						if deleteErr != nil {
							logger.L().Error(ctx, "failed to delete oldest item from cache under memory pressure", zap.Error(deleteErr))
							timer.Reset(getDelay(false))

							continue
						}
						if !succ && !memoryNoCandidateLogged {
							logger.L().Warn(ctx, "build cache cgroup memory is above the high watermark but no cache diff is available for eviction",
								zap.Int64("memory_current_bytes", stats.Current),
								zap.Int64("memory_max_bytes", stats.Max),
								zap.Int("high_watermark_percentage", memoryThreshold))
							memoryNoCandidateLogged = true
						}
						if succ {
							memoryNoCandidateLogged = false
						}

						timer.Reset(getDelay(succ))

						continue
					}
					memoryNoCandidateLogged = false
				}
			}

			dUsed, dTotal, err := diskUsage(s.cachePath)
			if err != nil {
				logger.L().Error(ctx, "failed to get disk usage", zap.Error(err))
				timer.Reset(getDelay(false))

				continue
			}

			pUsed := s.getPendingDeletesSize()
			used := int64(dUsed) - pUsed
			percentage := float64(used) / float64(dTotal) * 100

			threshold := evictionThreshold(ctx, flags, services)

			if percentage <= float64(threshold) {
				timer.Reset(getDelay(false))

				continue
			}

			succ, err := s.deleteOldestFromCacheForReason(ctx, cacheEvictionReasonDisk)
			if err != nil {
				logger.L().Error(ctx, "failed to delete oldest item from cache", zap.Error(err))
				timer.Reset(getDelay(false))

				continue
			}

			// Item evicted, reset timer to fast check
			timer.Reset(getDelay(succ))
		}
	}
}

func memoryPressureExceeded(stats cgroupMemoryStats, pendingDeleteBytes int64, threshold int) bool {
	if stats.Max <= 0 || threshold <= 0 {
		return false
	}

	projectedCurrent := max(stats.Current-pendingDeleteBytes, 0)

	return float64(projectedCurrent)/float64(stats.Max)*100 > float64(threshold)
}

func (s *DiffStore) recordMemoryStats(stats cgroupMemoryStats) {
	s.memoryStats.current.Store(stats.Current)
	s.memoryStats.max.Store(stats.Max)
	s.memoryStats.anon.Store(stats.Anon)
	s.memoryStats.file.Store(stats.File)
	s.memoryStats.shmem.Store(stats.Shmem)
}

func (s *DiffStore) registerMemoryMetrics() error {
	currentGauge, err := meter.Int64ObservableGauge("e2b.infra.build_cache.cgroup.memory.current",
		metric.WithDescription("Current memory charged to the build cache process cgroup"),
		metric.WithUnit("By"))
	if err != nil {
		return err
	}
	maxGauge, err := meter.Int64ObservableGauge("e2b.infra.build_cache.cgroup.memory.max",
		metric.WithDescription("Maximum memory allowed for the build cache process cgroup"),
		metric.WithUnit("By"))
	if err != nil {
		return err
	}
	anonGauge, err := meter.Int64ObservableGauge("e2b.infra.build_cache.cgroup.memory.anon",
		metric.WithDescription("Anonymous memory charged to the build cache process cgroup"),
		metric.WithUnit("By"))
	if err != nil {
		return err
	}
	fileGauge, err := meter.Int64ObservableGauge("e2b.infra.build_cache.cgroup.memory.file",
		metric.WithDescription("File-backed memory charged to the build cache process cgroup"),
		metric.WithUnit("By"))
	if err != nil {
		return err
	}
	shmemGauge, err := meter.Int64ObservableGauge("e2b.infra.build_cache.cgroup.memory.shmem",
		metric.WithDescription("Shared memory charged to the build cache process cgroup"),
		metric.WithUnit("By"))
	if err != nil {
		return err
	}
	pendingGauge, err := meter.Int64ObservableGauge("e2b.infra.build_cache.eviction.pending.bytes",
		metric.WithDescription("Build cache bytes scheduled for delayed eviction"),
		metric.WithUnit("By"))
	if err != nil {
		return err
	}

	registration, err := meter.RegisterCallback(func(_ context.Context, observer metric.Observer) error {
		observer.ObserveInt64(currentGauge, s.memoryStats.current.Load())
		observer.ObserveInt64(maxGauge, s.memoryStats.max.Load())
		observer.ObserveInt64(anonGauge, s.memoryStats.anon.Load())
		observer.ObserveInt64(fileGauge, s.memoryStats.file.Load())
		observer.ObserveInt64(shmemGauge, s.memoryStats.shmem.Load())
		observer.ObserveInt64(pendingGauge, s.getPendingDeletesSize())

		return nil
	}, currentGauge, maxGauge, anonGauge, fileGauge, shmemGauge, pendingGauge)

	if err != nil {
		return err
	}
	s.metricsRegistration = registration

	return nil
}

// evictionThreshold returns the maximum allowed disk usage percentage for the
// build cache. When multiple services (template manager, orchestrator) are
// defined, the lowest of their configured thresholds wins to ensure none of
// the set limits is exceeded. Flag evaluation already falls back per service
// inside IntFlag, so the flag fallback is only used directly when no services
// are configured; a flag value above the fallback is honored.
func evictionThreshold(ctx context.Context, flags *featureflags.Client, services cfg.Services) int {
	if len(services) == 0 {
		return featureflags.BuildCacheMaxUsagePercentage.Fallback()
	}

	threshold := math.MaxInt
	for _, svc := range services {
		st := flags.IntFlag(ctx, featureflags.BuildCacheMaxUsagePercentage, featureflags.ServiceContext(string(svc)))
		if st < threshold {
			threshold = st
		}
	}

	return threshold
}

func (s *DiffStore) getPendingDeletesSize() int64 {
	s.pdMu.RLock()
	defer s.pdMu.RUnlock()

	var pendingSize int64
	for _, value := range s.pdSizes {
		pendingSize += value.size
	}

	return pendingSize
}

// deleteOldestFromCache deletes the oldest item (smallest TTL) from the cache.
// ttlcache has items in order by TTL
func (s *DiffStore) deleteOldestFromCache(ctx context.Context) (suc bool, e error) {
	return s.deleteOldestFromCacheForReason(ctx, cacheEvictionReasonDisk)
}

func (s *DiffStore) deleteOldestFromCacheForReason(ctx context.Context, reason cacheEvictionReason) (suc bool, e error) {
	defer func() {
		// Because of bug in ttlcache RangeBackwards method, we need to handle potential panic until it gets fixed
		if r := recover(); r != nil {
			e = fmt.Errorf("recovered from panic in deleteOldestFromCache: %v", r)
			suc = false

			logger.L().Error(ctx, "recovered from panic in deleteOldestFromCache", zap.Error(e))
		}
	}()

	success := false
	s.cache.RangeBackwards(func(item *ttlcache.Item[DiffStoreKey, Diff]) bool {
		isDeleted := s.isBeingDeleted(item.Key())
		if isDeleted {
			return true
		}

		sfSize, err := item.Value().FileSize(ctx)
		if err != nil {
			logger.L().Warn(ctx, "failed to get size of deleted item from cache", zap.Error(err))
			sfSize = fallbackDiffSize
		}

		s.scheduleDeleteForReason(ctx, item.Key(), sfSize, reason)

		success = true

		return false
	})

	return success, e
}

func (s *DiffStore) resetDelete(key DiffStoreKey) {
	s.pdMu.Lock()
	defer s.pdMu.Unlock()

	dDiff, f := s.pdSizes[key]
	if !f {
		return
	}

	dDiff.closeOnce.Do(func() {
		close(dDiff.cancel)
	})
	delete(s.pdSizes, key)
}

func (s *DiffStore) isBeingDeleted(key DiffStoreKey) bool {
	s.pdMu.RLock()
	defer s.pdMu.RUnlock()

	_, f := s.pdSizes[key]

	return f
}

func (s *DiffStore) scheduleDelete(ctx context.Context, key DiffStoreKey, dSize int64) {
	s.scheduleDeleteForReason(ctx, key, dSize, cacheEvictionReasonDisk)
}

func (s *DiffStore) scheduleDeleteForReason(ctx context.Context, key DiffStoreKey, dSize int64, reason cacheEvictionReason) {
	s.pdMu.Lock()
	defer s.pdMu.Unlock()

	cancelCh := make(chan struct{})
	s.pdSizes[key] = &deleteDiff{
		size:   dSize,
		cancel: cancelCh,
	}
	cacheEvictionScheduledMetric.Add(ctx, 1, metric.WithAttributes(attribute.String("reason", string(reason))))

	// Delay cache (file close/removal) deletion,
	// this is to prevent race conditions with exposed slices,
	// pending data fetching, or data upload
	go (func() {
		select {
		case <-ctx.Done():
		case <-cancelCh:
		case <-time.After(s.pdDelay):
			s.cache.Delete(key)
		}
	})()
}

func diskUsage(path string) (uint64, uint64, error) {
	var stat unix.Statfs_t
	err := unix.Statfs(path, &stat)
	if err != nil {
		return 0, 0, fmt.Errorf("failed to get disk stats for path %s: %w", path, err)
	}

	// Available blocks * size per block = available space in bytes
	free := stat.Bavail * uint64(stat.Bsize)
	total := stat.Blocks * uint64(stat.Bsize)
	used := total - free

	return used, total, nil
}

func (s *DiffStore) RemoveCache() {
	s.cache.DeleteAll()
}
