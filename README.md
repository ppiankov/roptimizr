# 🧠 roptimizr.sh — Kubernetes Resource Optimizer

roptimizr scans all Kubernetes pods (excluding system namespaces) and identifies containers that are:
	•	CPU-hot
	•	Memory-heavy
	•	Restarting
	•	CrashLooping
	•	OOMKilled

It then prints human-readable recommendations for updated CPU/memory requests & limits, plus a summary of cluster resource usage.

# Why roptimizr?

If you're dealing with Kubernetes performance issues, CPU throttling,
CrashLoopBackOff, or oversized resource limits, roptimizr can help by
automatically analyzing cluster metrics and generating safe, optimized
recommendations based on real usage.

Works with kubectl, metrics-server, and supports restart detection,
CPU-hot logic, limit/request inspection, and cluster capacity summary.

## 📌 Usage

```bash
chmod +x roptimizr.sh
./roptimizr.sh
export KUBECONFIG=/path/to/config
```

Helps DevOps engineers identify pods with incorrectly configured
resource limits/requests, reducing cluster waste and improving stability.

# ⚡ OOMKill Detection & Behavior

LLM workloads, JVM services, Python apps with sudden heap bursts, and anything with malloc-spikes often get OOMKilled before metrics-server ever sees the peak usage.

That means:

Observed usage is always lower than the real peak.

To avoid deceptive metrics, roptimizr.sh follows this rule:

## 🔥 If a container was OOMKilled:
	•	Ignore observed memory usage (it’s fake)
	•	Double the existing memory limit
	•	Ensure at least +256Mi bump
	•	Set memory request to 70% of the new limit

Example:
| Situation | Old Mem Limit | New Mem Limit |
|-------|-----|-----------|
| Light web app | 256Mi | 512Mi|
| JVM app | 512Mi | 1024Mi |
| LLM inferencer | 2Gi | 4G |


# 🚀 Aggressive Mode (for LLM workloads)

LLM-serving pods (vLLM, Text-Generation-Inference, Ollama, Triton, etc.) tend to use short bursts of RAM 2–4× higher than stable operation.

Enable aggressive mode:
```bash
./roptimizr.sh --aggressive
```

This changes OOMKilled behavior to:
	•	Triple memory limit (instead of doubling)
	•	Guarantee at least +1Gi bump
	•	Requests set to 80% of the limit**

This mode is ideal for:
	•	LLM text generation
	•	Embeddings batched inference
	•	Vector DB internal memory maps
	•	FastAPI + model in RAM workloads


# 🧪 OOMKill Scenarios Detected

## Scenario 1: Silent LLM RAM spike

Symptoms:
	•	Observed usage: 500Mi
	•	Limit: 1024Mi
	•	Actual spike: 2200Mi (never captured by metrics)
	•	Pod OOMKilled instantly

Your output:
```bash
Reason:
  • Container suffered OOMKills → usage metrics unreliable
  • Applied safety rule: doubled memory limit, increased request
```

## Scenario 2: JVM service warming up
	•	Stable usage: 200Mi
	•	Limit: 256Mi
	•	OOMKill during GC or heap expansion

New recommended limit: 512Mi

## Scenario 3: Bursty Python API
	•	Uses Pydantic, llama.cpp bindings, transformers, or large model loads
	•	Occasional burst allocations kill the pod

# 📦 Summary Output

At the end of a run you get cluster planning metrics:
	•	current total CPU/memory
	•	projected totals after fixes
	•	cluster allocatable capacity
	•	pods with no limits set

Example:
```bash
Current total requested CPU:  2200m
After suggested changes, req: 2600m

Cluster allocatable CPU:      8000m
```

# 🛰️ Node Affinity Hotspot Detection

Besides CPU/memory optimization, roptimizr.sh now analyzes how pods are distributed across nodes and identifies situations where workloads are unintentionally “over-pinned” through nodeAffinity.

## Why this matters

Hard-pinning many pods to the same node can cause:
	•	uneven node load
	•	scheduling failures
	•	long pending queues
	•	resource hotspots
	•	unpredictable autoscaling behavior

In other words: you accidentally built a tiny dictatorship where all pods must live on the same node. This helps you notice when that’s happening.

## How it works

During a scan, the script:
	1.	Tracks how many pods run on each node
	2.	Counts how many of them have explicit nodeAffinity rules
	3.	Flags nodes where:
	•	≥ 5 pods are using nodeAffinity and
	•	≥ 70% of all pods on that node are affinity-pinned

This produces an output like:

```bash
============= NODE AFFINITY CHECK =============
⚠️  Node: worker-llm-01
    • Pods on node:      14
    • With nodeAffinity: 12 (85%)
    • Hint: A large share of workloads here are hard-pinned via nodeAffinity.
      Consider relaxing affinity / adding anti-affinity or spreading across more nodes.
===============================================
```

If nothing suspicious is detected:

```bash
No obvious nodeAffinity hotspots detected.
```

This helps DevOps engineers detect subtle cluster imbalance and affinity misconfigurations before they cause outages or weird scheduling behavior.

## ✨ Keywords

kubernetes resource optimization
kubectl top limits requests
automatic resource rightsizing
pod resource analyzer
bash kubernetes script
autoscaling troubleshooting
crashloopbackoff analysis


---

