Workload profile
# X-70R-6kSys — 8×307,328 KV; target 70%-80% total usage
# SHAPE
# - system_prompt_len = 6,000
# - question_len      = 1,200      # ≤ 1,500; cached per user
# - num_prompts_per_group = 5      # users per group
# - output_len        = 1,000      # observed live ≈ 200–230 tokens/running request


# Workload for CPU offloading plugin
###  KV/pod: 307,328 tokens
### - CPU/pod : 12800 blocks , block size 64 in tokens →  819,200 tokens
## Cluster:
### - 8 pods
### - GPU/memory : 2,458,624 tokens 
### - CPU/memory : 6,553,600 tokens
### - Effective CPU/memory :  4,094,976 tokens
### - Total effective memory : 6,553,600 tokens
### - ratio CPU/GPU memory : 2.67
### - Groups = 400 
### - Total Resident = 1,800,000 * 2.67 = 4,800,000 token (~73%)
### - Total Requests = 400 * 5 = 2000 (groups * prompts per group)
