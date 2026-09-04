//go:build linux

package nfsproxy

import (
	"context"
	"fmt"
	"net"
	"strings"
	"sync"

	"github.com/willscott/go-nfs"

	"github.com/e2b-dev/infra/packages/orchestrator/pkg/chrooted"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/nfsproxy/cfg"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/nfsproxy/chroot"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/nfsproxy/handlecache"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/nfsproxy/logged"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/nfsproxy/metrics"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/nfsproxy/recovery"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/nfsproxy/tracing"
	"github.com/e2b-dev/infra/packages/orchestrator/pkg/sandbox"
)

// handleCacheLimit sizes the node-global file-handle LRU shared by every
// sandbox's NFS mount. Guests cache handles indefinitely (the protocol
// treats them as persistent), so an evicted handle means ESTALE for whoever
// still holds it — a single large directory walk used to churn the previous
// 1024-entry cache several times over and stale out other sandboxes' mounts.
// 256k entries (~tens of MB) covers a full node's realistic working set.
const handleCacheLimit = 256 * 1024

// verifierCacheLimit stays small: each READDIR cookie-verifier entry holds a
// whole directory listing, so this must not scale with handleCacheLimit.
const verifierCacheLimit = 1024

var setLogLevelOnce sync.Once

type Proxy struct {
	config cfg.Config
	server *nfs.Server
}

func NewProxy(ctx context.Context, builder *chrooted.Builder, sandboxes *sandbox.Map, config cfg.Config) (*Proxy, error) {
	setLogLevelOnce.Do(func() {
		nfs.Log.SetLevel(config.NFSLogLevel)
	})

	// actual nfs handler
	var (
		handler nfs.Handler
		err     error
	)
	handler, err = chroot.NewNFSHandler(builder, sandboxes)
	if err != nil {
		return nil, fmt.Errorf("failed to create chroot NFS handler: %w", err)
	}

	// wrap the handler in middleware
	handler = handlecache.New(handler, handleCacheLimit, verifierCacheLimit)

	if config.Tracing {
		handler = tracing.WrapWithTracing(handler, config)
	}

	if config.Metrics {
		handler = metrics.WrapWithMetrics(handler, config)
	}

	if config.Logging {
		handler = logged.WrapWithLogging(ctx, handler, config)
	}

	handler = recovery.WrapWithRecovery(ctx, handler)

	s := &nfs.Server{
		Handler:      handler,
		Context:      ctx,
		OnConnect:    onConnect,
		OnDisconnect: onDisconnect,
	}

	return &Proxy{
		config: config,
		server: s,
	}, nil
}

func (p *Proxy) Serve(lis net.Listener) error {
	if err := p.server.Serve(lis); err != nil {
		if strings.Contains(err.Error(), "use of closed network connection") {
			return nil
		}

		return err
	}

	return nil
}
