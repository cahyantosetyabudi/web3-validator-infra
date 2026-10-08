# web3-validator-infra

Production-style Ethereum node operations on the **Sepolia testnet**: a Geth
(execution) + Lighthouse (consensus) pair, deployed with Docker Compose and
observed with Prometheus + Grafana. Built as hands-on proof of **Web3
DevOps/SRE** skills — running blockchain infrastructure, not writing smart
contracts.

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │                  jarvis (2 vCPU / 11 GB RAM) │
                    │                                             │
  P2P :30303        │   ┌──────────┐  Engine API   ┌────────────┐  │  P2P :9000
 ◄─────────────────┼───┤   geth   ├──────────────►│ lighthouse │──┼──────────────►
                    │   │ (exec)   │  :8551 + JWT  │  (beacon)  │  │
                    │   └────┬─────┘               └─────┬──────┘  │
                    │        │ :6060                     │ :5054   │
                    │        ▼                           ▼         │
                    │   ┌────────────────────────────────────┐     │
                    │   │             prometheus             │     │
                    │   └────────────────┬─────────────────┘     │
                    │                    ▼                       │
                    │   ┌────────────────────────────────────┐     │
                    │   │              grafana               │     │
                    │   └────────────────────────────────────┘     │
                    └─────────────────────────────────────────────┘
```

* **geth** — execution client. Handles transactions, EVM state, serves
  JSON-RPC. Started first; the consensus client drives it via the Engine API.
* **lighthouse** — consensus (beacon) client. Follows the beacon chain head
  and tells geth which payloads are canonical.
* **Engine API (`:8551`)** — the authenticated bridge between the two,
  secured by a shared **JWT secret** (`secrets/jwt.hex`, generated at deploy
  time, never committed). This is the post-Merge trust boundary: anyone with
  the JWT can make the execution client follow an arbitrary chain.
* **prometheus + grafana** — scrape `geth:6060` and `lighthouse:5054`;
  dashboard tracks head slot vs network slot, peer counts, and sync state.

Only P2P ports (30303, 9000) are exposed to the internet. RPC, Engine API,
metrics, Prometheus and Grafana all bind to `127.0.0.1`.

## Why Sepolia, why this pair

* **Sepolia** is the canonical public testnet: free to use (faucet-funded),
  small enough to sync on modest hardware, and operationally identical to
  mainnet (same Engine API, same validator mechanics).
* **Geth + Lighthouse** is the most common client combination in production
  staking infra — the exact stack a Web3 SRE is expected to operate.

## Real incident log

Things that actually went wrong while building this, and how they were fixed:

1. **Checkpoint sync vs the Gloas fork (2026-10-08).** Lighthouse `v8.2.3`
   (latest) failed to start with
   `InvalidSsz(OffsetOutOfBounds(...))` when loading the finalized
   checkpoint state — from *two independent* public endpoints. Inspecting the
   raw response showed `eth-consensus-version: gloas`: the chain had moved to
   a fork whose SSZ state layout this client build cannot parse. Workaround:
   backfill from genesis (`--allow-insecure-genesis-sync` +
   `--ignore-ws-check`), which is acceptable on a testnet learning node —
   weak subjectivity only matters when securing real stake. Documented in
   `docker-compose.yml`; checkpoint sync to be re-enabled once upstream
   handles Gloas states.
2. **Geth metrics port collision.** `--pprof` and `--metrics` both default to
   `:6060` — geth failed to bind the metrics server. Fixed by dropping
   `--pprof` (see commit history).
3. **Prometheus permission denied on config mount.** The Prometheus image
   runs as `nobody`; the bind-mounted `prometheus.yml` wasn't world-readable.
   Fixed with `chmod a+rX` on config dirs (same class of issue as Grafana's
   `uid 472`).

## Metrics that matter (what I watch)

| Signal | Source | Why |
|---|---|---|
| `beacon_head_slot` vs `beacon_clock_current_slot` | lighthouse | sync lag; alert if gap grows |
| `libp2p_peers` / `p2p_peers` | both | 0 peers = partitioned; check firewall/NAT |
| `chain_head_block` | geth | execution sync progress |
| `sync_eth2_synced` | lighthouse | 1 = fully synced |
| disk usage of `geth-data` volume | host | full disk = corrupt DB; plan pruning *before* it happens |

## Quickstart

```bash
./scripts/gen-jwt.sh        # one-time: shared Engine API secret
cp .env.example .env        # set a real Grafana password
docker compose up -d        # geth + lighthouse + prometheus + grafana
docker compose logs -f      # watch it sync
```

* Grafana: http://localhost:3000 (admin / `$GRAFANA_PASSWORD`)
* Prometheus: http://localhost:9090
* Geth RPC: http://localhost:8545

Geth snap-syncs Sepolia in a few hours; the beacon node backfills from
genesis in the background (slower — this is the documented trade-off above).

## Operations notes

* **Upgrades:** pin image tags before going near anything production-like;
  `:stable`/`:latest` are used here for a learning node only. Upgrade the
  consensus client *before* the execution client on fork boundaries.
* **Backups:** the only thing worth backing up is the JWT secret and configs —
  chain data re-syncs. Never back up a *validator* keystore this casually
  (not run here).
* **Disk:** Sepolia full node ≈ 60–100 GB and growing. Alert at 80% and prune
  (`geth snapshot prune-state`) before the disk fills.

## Roadmap

- [ ] Ansible playbook wrapping this compose stack (true IaC, multi-host)
- [ ] Alertmanager rules: sync stall, peer drop, disk pressure
- [ ] Sepolia validator on a second host (key management with eth2-val-tools)
- [ ] Go sidecar: minimal beacon-chain health exporter
