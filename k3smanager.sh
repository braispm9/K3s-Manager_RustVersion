#!/usr/bin/env bash
set -uo pipefail

VERSION="Rust Release 1.0"
GITHUB_USER="braispm9"
REPO_NAME="K3s-Manager_RustVersion"
BRANCH="main"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$0")"

declare -a PODS=() POD_NS=() SELECTED=() SELECTED_NS=()

refresh_pods() {
    PODS=(); POD_NS=()
    while read -r ns name; do
        [[ -n "$name" && "$ns" != "kube-system" ]] && POD_NS+=("$ns") && PODS+=("$name")
    done < <(kubectl get pods --all-namespaces --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null | sort -k1,1 -k2,2V)
}

ids_to_pods() {
    local arg="$1"
    refresh_pods
    TARGET_PODS=(); TARGET_NS=()
    if [[ "$arg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local first="${BASH_REMATCH[1]}" last="${BASH_REMATCH[2]}"
        (( first >= 1 && last >= first && last <= ${#PODS[@]} )) || return 1
        for ((i=first;i<=last;i++)); do
            TARGET_PODS+=("${PODS[i-1]}"); TARGET_NS+=("${POD_NS[i-1]}")
        done
    else
        for id in ${arg//,/ }; do
            [[ "$id" =~ ^[0-9]+$ ]] || return 1
            (( id >= 1 && id <= ${#PODS[@]} )) || return 1
            TARGET_PODS+=("${PODS[id-1]}"); TARGET_NS+=("${POD_NS[id-1]}")
        done
    fi
}

list_pods() { refresh_pods; printf '\nID   NAMESPACE        POD\n-----------------------------\n'; local i; for i in "${!PODS[@]}"; do printf '%-4d %-17s %s\n' "$((i+1))" "${POD_NS[i]}" "${PODS[i]}"; done; }

select_pods() { ids_to_pods "$1" || { echo 'Invalid pod ID or range.'; return 1; }; for i in "${!TARGET_PODS[@]}"; do SELECTED+=("${TARGET_PODS[i]}"); SELECTED_NS+=("${TARGET_NS[i]}"); echo "Selected ${TARGET_PODS[i]} (${TARGET_NS[i]})"; done; }

remove_pods() { ids_to_pods "$1" || return 1; for i in "${!TARGET_PODS[@]}"; do local n=0 new_pods=() new_ns=(); for j in "${!SELECTED[@]}"; do if [[ "${SELECTED[j]}" != "${TARGET_PODS[i]}" || "${SELECTED_NS[j]}" != "${TARGET_NS[i]}" ]]; then new_pods+=("${SELECTED[j]}"); new_ns+=("${SELECTED_NS[j]}"); fi; done; SELECTED=("${new_pods[@]}"); SELECTED_NS=("${new_ns[@]}"); done; }

show_selected() { ((${#SELECTED[@]})) || { echo 'No pods selected.'; return; }; for i in "${!SELECTED[@]}"; do echo "${SELECTED[i]} (${SELECTED_NS[i]})"; done; }

pod_ip() { local target="$1" ns="${2:-}"; refresh_pods; if [[ "$target" =~ ^[0-9]+$ ]]; then (( target >= 1 && target <= ${#PODS[@]} )) || return 1; ns="${POD_NS[target-1]}"; target="${PODS[target-1]}"; elif [[ -z "$ns" ]]; then ns=$(kubectl get pods -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null | awk -v n="$target" '$2==n {print $1; exit}'); fi; [[ -n "$ns" ]] || { echo "Pod '$target' not found."; return 1; }; kubectl get pod "$target" -n "$ns" -o jsonpath='Pod IP: {.status.podIP}{"\n"}'; }

create_pods() {
    local target="$1" image="${3:-nginx:alpine}"; [[ "$2" == "-i" || "$2" == "--image" ]] && image="$3"
    if [[ "$target" =~ ^[0-9]+$ ]]; then for ((i=1;i<=target;i++)); do kubectl run "pod-app-$i" --image="$image" || true; done
    elif [[ "$target" =~ ^([0-9]+)-([0-9]+)$ ]]; then for ((i=${BASH_REMATCH[1]};i<=${BASH_REMATCH[2]};i++)); do kubectl run "pod-app-$i" --image="$image" || true; done
    else echo 'Usage: create <N|N-M> [-i image>'; return 1; fi
}

describe_pods() { if ((${#SELECTED[@]})); then for i in "${!SELECTED[@]}"; do kubectl describe pod "${SELECTED[i]}" -n "${SELECTED_NS[i]}"; done; else echo 'No pods selected.'; return 1; fi; }

logs_pod() { if ((${#SELECTED[@]} == 1)); then kubectl logs "${SELECTED[0]}" -n "${SELECTED_NS[0]}" --tail=50; else echo 'Select exactly one pod.'; return 1; fi; }

delete_pods() { ((${#SELECTED[@]})) || { echo 'No pods selected.'; return 1; }; for i in "${!SELECTED[@]}"; do kubectl delete pod "${SELECTED[i]}" -n "${SELECTED_NS[i]}"; done; SELECTED=(); SELECTED_NS=(); }

target_from_arg_or_selection() {
    local arg="${1:-}"; TARGET_PODS=(); TARGET_NS=()
    if [[ "$arg" =~ ^[0-9]+$ ]]; then ids_to_pods "$arg" || return 1
    elif [[ "$arg" =~ ^([0-9]+)-([0-9]+)$ ]]; then ids_to_pods "$arg" || return 1
    elif ((${#SELECTED[@]})); then TARGET_PODS=("${SELECTED[@]}"); TARGET_NS=("${SELECTED_NS[@]}")
    else echo 'Specify a pod ID/range or select pods first.'; return 1; fi
}

check_ports() { target_from_arg_or_selection "$1" || return 1; for i in "${!TARGET_PODS[@]}"; do local pod="${TARGET_PODS[i]}" ns="${TARGET_NS[i]}" ip status; ip=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.podIP}'); status=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.phase}'); echo "[$pod/$ns] $status ${ip:-no-IP}"; for port in 22 53 80 443 3306 5432 6379 8080 8443 27017; do if command -v nc >/dev/null && nc -z -w 1 "$ip" "$port" 2>/dev/null; then echo "  $port/TCP open"; fi; done; done; }

isolate_ports() { target_from_arg_or_selection "$1" || return 1; for i in "${!TARGET_PODS[@]}"; do local pod="${TARGET_PODS[i]}" ns="${TARGET_NS[i]}"; kubectl label pod "$pod" -n "$ns" k3smanager-isolated=true --overwrite >/dev/null; cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-ingress-$pod
  namespace: $ns
spec:
  podSelector:
    matchLabels:
      k3smanager-isolated: "true"
  policyTypes: [Ingress]
EOF
 echo "[OK] $pod isolated"; done; }

open_ports() { target_from_arg_or_selection "$1" || return 1; for i in "${!TARGET_PODS[@]}"; do local pod="${TARGET_PODS[i]}" ns="${TARGET_NS[i]}"; kubectl delete networkpolicy "block-ingress-$pod" -n "$ns" --ignore-not-found >/dev/null; kubectl label pod "$pod" -n "$ns" k3smanager-isolated- >/dev/null 2>&1 || true; echo "[OK] $pod restored"; done; }

monitor_connections() { command -v tcpdump >/dev/null || { echo "tcpdump is required: sudo apt install -y tcpdump"; return 1; }; sudo tcpdump -i any -n -l 'tcp[tcpflags] & tcp-syn != 0' 2>/dev/null; }

test_network() { local arg="${1:-1-5}" first=1 last=5; if [[ "$arg" =~ ^([0-9]+)-([0-9]+)$ ]]; then first=${BASH_REMATCH[1]}; last=${BASH_REMATCH[2]}; elif [[ "$arg" =~ ^[0-9]+$ ]]; then last="$arg"; fi; kubectl run probador-red --image=curlimages/curl --restart=Never -- sleep 3600 >/dev/null 2>&1 || true; kubectl wait --for=condition=Ready pod/probador-red --timeout=15s >/dev/null 2>&1; for ((i=first;i<=last;i++)); do local pod="pod-prueba-$i" ip; kubectl get pod "$pod" >/dev/null 2>&1 || kubectl run "$pod" --image=nginx:alpine --port=80 >/dev/null 2>&1; ip=$(kubectl get pod "$pod" -o jsonpath='{.status.podIP}'); if [[ -n "$ip" ]] && kubectl exec probador-red -- curl -sSf -m 3 "http://$ip" >/dev/null 2>&1; then echo "[OK] $pod ($ip)"; else echo "[X] $pod ($ip)"; fi; done; kubectl delete pod probador-red --grace-period=0 --force >/dev/null 2>&1; }

test_connections() { ids_to_pods "$1,$2" || { echo 'Invalid origin or destination ID.'; return 1; }; local ip ns origin="${TARGET_PODS[0]}" dest="${TARGET_PODS[1]}"; ns="${TARGET_NS[1]}"; ip=$(kubectl get pod "$dest" -n "$ns" -o jsonpath='{.status.podIP}'); ns="${TARGET_NS[0]}"; kubectl exec -n "$ns" "$origin" -- sh -c "curl -sSf -m 3 http://$ip || wget -qO- -T 3 http://$ip"; }

check_update() { echo "Checking $GITHUB_USER/$REPO_NAME..."; if curl -fsSL "https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/$BRANCH/k3smanager.sh" -o /tmp/k3smanager.remote; then if cmp -s "$SCRIPT_PATH" /tmp/k3smanager.remote; then echo '[OK] Latest version.'; else echo '[!] Update available. Run: k3smanager update'; fi; rm -f /tmp/k3smanager.remote; fi; }

update_manager() { curl -fsSL "https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/$BRANCH/k3smanager.sh" -o "$SCRIPT_PATH.tmp" && mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"; }

help_text() { cat <<'EOF'
Commands:
  list | select <ID,range> | remove <ID,range> | show | clear-sel
  ip <ID|name> [namespace] | describe | logs | delete
  create <N|N-M> [-i image]
  check-ports [ID|range] | close-port [ID|range] | open-port [ID|range]
  monitor-connect | test-network [N|N-M|-a] | test-connections <origin> <dest>
  version | update | clear | help | exit
EOF
}

if (($#)); then
    cmd="$1"; shift
    case "$cmd" in
      list|pods) list_pods;; select|add) select_pods "${2:-$1}";; remove) remove_pods "${2:-$1}";; show) show_selected;; clear-sel) SELECTED=(); SELECTED_NS=();;
      ip) pod_ip "${1:-}" "${2:-}";; describe) describe_pods;; logs) logs_pod;; delete) delete_pods;; delete-pod) kubectl delete pod "${1:-}" -n "${2:-default}";;
      create) create_pods "${1:-}" "${2:-}" "${3:-nginx:alpine}";; check-ports) check_ports "${1:-}";; close-port) isolate_ports "${1:-}";; open-port) open_ports "${1:-}";;
      monitor-connect) monitor_connections;; test-network) test_network "${1:-}";; test-connections) test_connections "${1:-}" "${2:-}";;
      version) echo "$VERSION";; update) update_manager;; help) help_text;; clear) clear;; *) echo "Unknown command: $cmd"; exit 1;;
    esac
    exit $? 
fi

help_text
while true; do read -e -r -p 'k3s> ' line || exit 0; [[ -n "$line" ]] || continue; read -r -a args <<< "$line"; cmd="${args[0]}"; set -- "${args[@]:1}"; case "$cmd" in exit|quit) break;; *) "$cmd" "$@" 2>/dev/null || echo 'Invalid command or arguments.'; case "$cmd" in select|add) select_pods "${1:-}";; remove) remove_pods "${1:-}";; show) show_selected;; clear-sel) SELECTED=(); SELECTED_NS=();; ip) pod_ip "${1:-}" "${2:-}";; describe) describe_pods;; logs) logs_pod;; delete) delete_pods;; create) create_pods "${1:-}" "${2:-}" "${3:-nginx:alpine}";; check-ports) check_ports "${1:-}";; close-port) isolate_ports "${1:-}";; open-port) open_ports "${1:-}";; monitor-connect) monitor_connections;; test-network) test_network "${1:-}";; test-connections) test_connections "${1:-}" "${2:-}";; version) echo "$VERSION"; check_update;; update) update_manager;; help) help_text;; clear) clear;; list|pods) list_pods;; *) echo "Unknown command: $cmd";; esac;; esac; done
