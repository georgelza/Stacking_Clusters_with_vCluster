# ══════════════════════════════════════════════════════════════════════════════
#  LOCAL Stacked Tenant K8s clusters on Host vCLUSTER — a self-contained lab
# ══════════════════════════════════════════════════════════════════════════════

.DEFAULT_GOAL := help

include .env
export

VCLUSTER        ?= my-host
VCLUSTER_CONFIG ?= vhost.yml

.PHONY: help
help:
	@echo ""
	@echo "  LOCAL Stacked Tenant Clusters on vCLUSTER Host"
	@echo ""
	@echo "    t1 -> nginx    (default docker driver, 1 node, no workers)"
	@echo "    t2 -> redis    (helm driver, borrows my-host's nodes)"
	@echo "    t3 -> postgres (docker driver, 4 nodes, PV on ./data/tenant3)"
	@echo ""
	@echo "    make host         Bring the Host Cluster up"
	@echo "    make cr_t1        Bring up vc-t1 (tenant1)"
	@echo "    make cr_t2        Bring up vc-t2 (tenant2, helm driver)"
	@echo "    make cr_t3        Bring up vc-t3 (tenant3, docker driver)"
	@echo ""
	@echo "    make switch_host  Switch context to Host Cluster"
	@echo "    make switch_t1    Switch context to vc-t1"
	@echo "    make switch_t2    Switch context to vc-t2 (via the host)"
	@echo "    make switch_t3    Switch context to vc-t3"
	@echo ""
	@echo "  SERVICES (one per tenant — switch to that tenant first, or use 'make up')"
	@echo "    make dep_t1       Deploy nginx    -> ns nginx    on vc-t1"
	@echo "    make dep_t2       Deploy redis    -> ns redis    on vc-t2"
	@echo "    make dep_t3       Deploy postgres -> ns postgres on vc-t3"
	@echo "    make up           Deploy all three, switching context itself"
	@echo ""
	@echo "  TEARDOWN"
	@echo "    make del_t1       Delete Tenant 1 Cluster"
	@echo "    make del_t2       Delete Tenant 2 Cluster (helm driver)"
	@echo "    make del_t3       Delete Tenant 3 Cluster"
	@echo "    make down         Delete ALL tenants, then the host, then volumes"
	@echo ""

store:
	@echo "🚀 [1/2] Creating persistent store directory"
	@mkdir -p ./data/cluster

.PHONY: store

# ══════════════════════════════════════════════════════════════════════════════
#  HOST CLUSTER SETUP
# ══════════════════════════════════════════════════════════════════════════════
host: store
	@echo "🚀 [2/2] Creating host vcluster $(VCLUSTER)"
	@vcluster list 2>/dev/null | grep -q "$(VCLUSTER).*running" && echo "  ✓ host already running" || \
		{ test -f $(VCLUSTER_CONFIG) || { echo "ERROR: $(VCLUSTER_CONFIG) not found" >&2; exit 1; }; \
		  vcluster create $(VCLUSTER) -f $(VCLUSTER_CONFIG); }
	@echo "  ⏳ Settling host..."
	@sleep 5

	@echo "🚀 Creating tenant namespaces in host"
	@kubectl create namespace tenant1 --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create namespace tenant2 --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create namespace tenant3 --dry-run=client -o yaml | kubectl apply -f -

	@echo ""
	@echo "✅ Host Cluster Up"
	@echo "   Next: make cr_t1"
	@echo "   Next: make cr_t2"
	@echo "   Next: make cr_t3"

.PHONY: host

# ─────────────────────────────────────────────────────────────────────────────
#  TENANT CLUSTERS SETUP
#
#  Placement per tenant:
#    vc-t1  default docker driver   — no -f, one control-plane node, no workers
#    vc-t2  helm driver (-f t2.yml) — nests in my-host, runs on my-host's nodes
#    vc-t3  docker driver (-f t3.yml)— 4 own worker nodes, volumes in ./data/tenant3
#
#  cr_t2 installs into whatever cluster the active kube context points at, so it
#  must switch to the host first — otherwise it silently nests inside vc-t1.
# ─────────────────────────────────────────────────────────────────────────────
cr_t1:
	@echo "🚀 Provisioning tenant cluster vc-t1 in namespace tenant1 (Default Docker Driver)"
	@vcluster create vc-t1 -n tenant1
	@kubectl get pods -n tenant1

cr_t2: switch_host
	@echo "🚀 Provisioning tenant cluster vc-t2 in namespace tenant2 (Helm Driver — inherits my-host nodes)"
	@vcluster create vc-t2 -n tenant2 --driver helm -f t2.yml
	@kubectl get pods -n tenant2

cr_t3:
	@echo "🚀 Provisioning tenant cluster vc-t3 in namespace tenant3 (Docker Driver — 4 own worker nodes)"
	@vcluster create vc-t3 -n tenant3 -f t3.yml
	@kubectl get pods -n tenant3

# ─────────────────────────────────────────────────────────────────────────────
#  CONTEXT SWITCHING
#
#  vc-t2 is a HELM-driver cluster, which changes two things:
#
#   1. `vcluster list` (docker-driver view) does NOT show vc-t2 at all, so you
#      cannot look it up by name to connect.
#   2. `vcluster connect` must be issued while pointed at the HOST cluster —
#      the helm driver resolves vc-t2 by querying the current kube context.
#      Connecting from vc-t1's context fails with "couldn't find vcluster
#      vc-t2", and — worse — leaves the previous context active, so the next
#      `make dep_*` silently applies to the wrong tenant.
#
#  Hence the switch_host prerequisite. Do not drop it.
# ─────────────────────────────────────────────────────────────────────────────
switch_t1:
	@vcluster connect vc-t1 -n tenant1

switch_t2: switch_host
	@vcluster connect vc-t2 -n tenant2 --driver helm

switch_t3:
	@vcluster connect vc-t3 -n tenant3

switch_host:
	@vcluster connect $(VCLUSTER)
	@kubectl get namespaces

inspect: 
	@kubectl get namespaces

# ─────────────────────────────────────────────────────────────────────────────
#  SERVICE DEPLOYMENT
#
#  Each manifest carries its own Namespace object, so `kubectl apply` is
#  idempotent — re-running converges instead of failing on AlreadyExists.
#
#  ⚠ assert_context is not decoration. `kubectl apply` targets whatever context
#  is active, and a failed `make switch_tN` leaves the PREVIOUS context in
#  place. That is exactly how redis ended up deployed into vc-t1 while the log
#  said "Deploying redis ... on tenant cluster vc-t2". Each dep_* target now
#  verifies the active context mentions the tenant it is about to write to, and
#  refuses to run if it does not.
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: dep_t1 dep_t2 dep_t3 wait

NS ?= nginx

wait: ## wait — block until deploy/$(NS) reports Available (call with NS=<namespace>)
	@echo "  ⏳ waiting for deploy/$(NS)"
	@kubectl -n $(NS) wait --for=condition=Available deploy/$(NS) --timeout=180s

# Fail loudly rather than write to the wrong tenant cluster.
# arg1=expected context substring
define assert_context
	@ctx="$$(kubectl config current-context 2>/dev/null || echo none)"; \
	case "$$ctx" in \
		*$(1)*) echo "  ✓ context $$ctx" ;; \
		*) echo "✗ refusing to deploy: active context is '$$ctx', expected one containing '$(1)'." >&2; \
		   echo "  Run 'make switch_$(2)' first." >&2; exit 1 ;; \
	esac
endef

dep_t1: ## nginx -> vc-t1
	$(call assert_context,vc-t1,t1)
	@echo "🚀 Deploying nginx -> ns nginx on tenant cluster vc-t1"
	@kubectl apply -f nginx.yml
	@$(MAKE) --no-print-directory wait NS=nginx
	@echo "  ✅ nginx: kubectl -n nginx port-forward svc/nginx 8080:80"

dep_t2: ## redis -> vc-t2
	$(call assert_context,vc-t2,t2)
	@echo "🚀 Deploying redis -> ns redis on tenant cluster vc-t2"
	@kubectl apply -f redis.yml
	@$(MAKE) --no-print-directory wait NS=redis
	@echo "  ✅ redis: redis.redis.svc.cluster.local:6379 (inside vc-t2 only)"

dep_t3: ## postgres 16 -> vc-t3
	$(call assert_context,vc-t3,t3)
	@echo "🚀 Deploying postgres 16 -> ns postgres on tenant cluster vc-t3"
	@kubectl apply -f pg.yml
	@$(MAKE) --no-print-directory wait NS=postgres
	@echo "  ✅ postgres: postgres.postgres.svc.cluster.local:5432 (stacked/stacked_local_dev)"
	@echo "  ✅ PV on host: ./data/tenant3/n<N>/local-path-provisioner/"

# All three, each against its own tenant. `up` switches context itself, because
# the three services live in three separate clusters and a single kubectl
# context cannot address more than one of them at a time.
up:
	@$(MAKE) --no-print-directory switch_t1 >/dev/null && $(MAKE) --no-print-directory dep_t1
	@$(MAKE) --no-print-directory switch_t2 >/dev/null && $(MAKE) --no-print-directory dep_t2
	@$(MAKE) --no-print-directory switch_t3 >/dev/null && $(MAKE) --no-print-directory dep_t3
	@echo ""
	@echo "✅ All three tenant services up"
	@echo "   vc-t1 / ns nginx     http://nginx.nginx.svc.cluster.local:80"
	@echo "   vc-t2 / ns redis     redis.redis.svc.cluster.local:6379"
	@echo "   vc-t3 / ns postgres  postgres.postgres.svc.cluster.local:5432  (stacked/stacked_local_dev)"
	@echo ""
	@echo "   Each name resolves ONLY inside its own cluster — they do not talk to each other."
	@echo "   Active context is now vc-t3; use 'make switch_tN' to change."

# ══════════════════════════════════════════════════════════════════════════════
#  CLEANUP & TEARDOWN
#
#  Order matters. The tenant clusters live inside the host's namespaces, and the
#  host owns ./data/cluster. Tearing the host down first leaves the tenant
#  containers and their node volumes behind — that is how a stale vc-t2 outlived
#  `make down` once. So: tenants (newest first) -> host -> host volumes.
# ══════════════════════════════════════════════════════════════════════════════

# Docker-driver tenant: arg1=cluster  arg2=namespace
define delete_docker_vcluster
	@if vcluster list 2>/dev/null | grep -q "$(1).*running\|$(1).*stopped"; then \
		echo "🛑 Deleting tenant cluster $(1) (ns $(2), docker driver)"; \
		vcluster delete "$(1)" -n "$(2)" >/dev/null 2>&1 \
			&& echo "  ✓ $(1) deleted" \
			|| { echo "  ✗ $(1) delete FAILED" >&2; exit 1; }; \
	else \
		echo "  – $(1) absent (skipped)"; \
	fi
endef

# Helm-driver tenant (vc-t2): must be resolved and deleted via the HOST context.
define delete_helm_vcluster
	@vcluster connect $(VCLUSTER) >/dev/null 2>&1 || true; \
	if kubectl -n $(2) get secret "sh.helm.release.v1.$(1).v1" >/dev/null 2>&1; then \
		echo "🛑 Deleting tenant cluster $(1) (ns $(2), helm driver)"; \
		vcluster delete "$(1)" -n "$(2)" --driver helm >/dev/null 2>&1 \
			&& echo "  ✓ $(1) deleted" \
			|| { echo "  ✗ $(1) delete FAILED" >&2; exit 1; }; \
	else \
		echo "  – $(1) absent (skipped)"; \
	fi
endef

del_t1:
	$(call delete_docker_vcluster,vc-t1,tenant1)

del_t2:
	$(call delete_helm_vcluster,vc-t2,tenant2)

del_t3:
	$(call delete_docker_vcluster,vc-t3,tenant3)

# Full teardown: tenants first, then the host, then the bind-mounted node volumes.
down: del_t3 del_t2 del_t1
	@echo "🛑 Deleting host vcluster $(VCLUSTER)"
	@if vcluster list 2>/dev/null | grep -q "$(VCLUSTER)"; then \
		vcluster delete "$(VCLUSTER)" >/dev/null 2>&1 \
			&& echo "  ✓ $(VCLUSTER) deleted" \
			|| { echo "  ✗ $(VCLUSTER) delete FAILED" >&2; exit 1; }; \
	else \
		echo "  – $(VCLUSTER) absent (skipped)"; \
	fi
	@echo "🛑 Removing node volumes"
	@rm -rf ./data/cluster    # host nodes   (vhost.yml)
	@rm -rf ./data/tenant3    # vc-t3 nodes  (t3.yml, docker driver)
	@echo "  ✓ ./data removed"
	@echo "✅ Cluster torn down"

.PHONY: down del_t1 del_t2 del_t3