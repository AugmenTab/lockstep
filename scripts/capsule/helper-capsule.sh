# The runner channel's capsule mode (Phase 5; docs/architecture/dev-capsules.md §5, §6, §8; contracts
# C-P5.5, C-P5.6). Sourced by scripts/control-helper; nothing here runs on its own.
#
# Off unless the owner made DIR/capsule (0700) with DIR/capsule/config (0600):
#
#   lockstep-capsule 1
#   runtime-state ABSOLUTE-DIR          the Capsule Runtime's --state
#   capsule NAME                        the Engineer's capsule (provisioned, audited)
#   project NAME                        the project it belongs to
#   verify-capsule NAME                 (optional) a second capsule for verification, with snapshot "verify"
#
# When on, the Supervisor's run requests are unchanged; only where they run changes:
#   run-readonly, run-write   the argument vector runs in the Engineer's capsule (/work/tree); a
#                             writing run's tree comes back as regular files, protected files kept
#   run-verify                the verification capsule, restored from its trusted "verify" snapshot
#                             first, the Supervisor's tree pushed in; never the Engineer's VM. Refused
#                             (verification-environment-missing) when no verification capsule is set
#   run-live-*                the provider container as before, but with NO built-in tool and no tree:
#                             its only tool is the capsule bridge, served by the runtime in the
#                             Engineer's capsule. An argument vector that does not disable the built-in
#                             tools (--tools "") or that names its own MCP configuration is refused.
# The service learns only that capsule mode is on: DIR/runner/capsule ("lockstep-capsule 1 NAME").

capsule_mode=0
capsule_dir=$state/capsule
cap_rt=$root/scripts/capsule-runtime
cap_bridge=$root/scripts/runner/provider/capsule-bridge
cap_state=""
cap_name=""
cap_project=""
cap_verify=""
cap_lockstep_project=""
cap_limit=0

# The owner asked for capsule mode (DIR/capsule exists) but it cannot be used: every run is refused
# (capsule-mode-unavailable), never sent to the Phase 4 containers instead (P5.5 review finding 6).
capsule_off() { log "capsule mode UNAVAILABLE, every run is refused: $1"; capsule_mode=2; return 0; }

# The calling (sub)shell's process id. macOS's bash 3.2 has no BASHPID, and under set -u reading it
# ends the run's subshell before it can answer; the parent of a child shell is the caller.
self_pid() { sh -c 'echo "$PPID"'; }

init_capsule() {
  local f=$capsule_dir/config line n=0 out tmp
  rm -f "$runner/capsule"
  [ -e "$capsule_dir" ] || [ -L "$capsule_dir" ] || return 0
  private_dir "$capsule_dir" || { capsule_off "$capsule_dir must be a directory owned by this user with mode 0700"; return 0; }
  [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || { capsule_off "$f is missing"; return 0; }
  case $(mode_of "$f") in *00) ;; *) capsule_off "$f must have mode 0600"; return 0 ;; esac
  if grep -q '[^ -~]' "$f" || [ "$(wc -c < "$f" | tr -d ' ')" -gt 1024 ]; then capsule_off "$f is malformed"; return 0; fi
  while IFS= read -r line; do
    n=$((n + 1))
    case $n:$line in
      "1:lockstep-capsule 1") ;;
      2:runtime-state\ /*) cap_state=${line#runtime-state } ;;
      3:capsule\ *) cap_name=${line#capsule } ;;
      4:project\ *) cap_project=${line#project } ;;
      [56]:verify-capsule\ *) cap_verify=${line#verify-capsule } ;;
      [56]:lockstep-project\ *) cap_lockstep_project=${line#lockstep-project } ;;
      *) capsule_off "$f is malformed (line $n)"; return 0 ;;
    esac
  done < "$f"
  [ $n -ge 4 ] || { capsule_off "$f is incomplete"; return 0; }
  [[ $cap_state =~ ^/[A-Za-z0-9._/-]+$ ]] || { capsule_off "runtime-state must be a plain absolute path"; return 0; }
  [[ $cap_name =~ ^[a-z][a-z0-9-]{2,30}[a-z0-9]$ ]] || { capsule_off "invalid capsule name"; return 0; }
  [[ $cap_project =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || { capsule_off "invalid project name"; return 0; }
  # The Lockstep project (its id) whose page shows this capsule and may stop its run; optional.
  if [ -n "$cap_lockstep_project" ]; then
    [[ $cap_lockstep_project =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { capsule_off "invalid lockstep-project"; return 0; }
  fi
  if [ -n "$cap_verify" ]; then
    [[ $cap_verify =~ ^[a-z][a-z0-9-]{2,30}[a-z0-9]$ ]] && [ "$cap_verify" != "$cap_name" ] || { capsule_off "invalid verify-capsule"; return 0; }
  fi
  # The capsule must exist, belong to the project and pass the runtime's configuration audit.
  "$cap_rt" --state "$cap_state" start "$cap_name" "$cap_project" > /dev/null 2>&1
  out=$("$cap_rt" --state "$cap_state" inspect "$cap_name" "$cap_project" 2>&1)
  [[ $out =~ ^capsule-runtime\ 1\ inspect\ ok\ .*status=Running.*audit=ok ]] || { capsule_off "the capsule is not ready ($(printf '%s' "$out" | clean_detail))"; return 0; }
  # Made from today's template, or not used (P5.5 review 3, M1): reconfigure it, or reprovision it.
  [[ $out =~ template=current ]] || { capsule_off "the capsule was made from an older template; run capsule-runtime reconfigure (or reprovision for a new base image)"; return 0; }
  cap_limit=$(sed -n 's/^exec-limit //p' "$cap_state/capsules/records/$cap_name")
  [[ $cap_limit =~ ^[0-9]{1,6}$ ]] || { capsule_off "the capsule has no limit"; return 0; }
  if [ -n "$cap_verify" ]; then
    out=$("$cap_rt" --state "$cap_state" inspect "$cap_verify" "$cap_project" 2>&1)
    [[ $out =~ ^capsule-runtime\ 1\ inspect\ ok\ .*audit=ok.*template=current ]] || { capsule_off "the verification capsule is not ready or not current ($(printf '%s' "$out" | clean_detail))"; return 0; }
    [ -f "$cap_state/capsules/snapshots/$cap_verify/verify.disk" ] || { capsule_off "the verification capsule has no 'verify' snapshot"; return 0; }
  fi
  # A capsule run left behind by a helper that crashed (kill -9; P5.5 review 3, M4): its guest program is
  # cancelled (the runtime ends it and stops the VM) and its process killed, before anything else, so it
  # can neither bring a tree back nor answer; the journal recovery then answers it interrupted.
  local pidfile opid
  for pidfile in "$runner_work"/*/.capsule-pid; do
    [ -f "$pidfile" ] || continue
    opid=$(cat "$pidfile" 2>/dev/null)
    if [ -d "$(dirname "$pidfile")/.capsule-out" ]; then : > "$(dirname "$pidfile")/.capsule-out/.cancel"; fi
    # Only a process that still is a helper's (a reused process id is left alone).
    if [[ $opid =~ ^[0-9]+$ ]] && kill -0 "$opid" 2>/dev/null && ps -p "$opid" -o command= 2>/dev/null | grep -q control-helper; then
      kill -9 "$opid" 2>/dev/null
      log "capsule: ended the orphaned run $(basename "$(dirname "$pidfile")") (process $opid)"
    fi
    rm -f "$pidfile"
  done
  # An invocation still open from before this helper started cannot be live (the helper ran it): close
  # it, so it holds no writer slot (P5.5 review finding 11).
  local b
  for b in "$cap_state"/capsules/invocations/*/binding; do
    [ -f "$b" ] || continue
    grep -qx "project $cap_project" "$b" || continue
    [ -e "$(dirname "$b")/closed" ] && continue
    "$cap_rt" --state "$cap_state" close "$(basename "$(dirname "$b")")" > /dev/null 2>&1
    log "capsule: closed the stale invocation $(basename "$(dirname "$b")")"
  done
  tmp=$(mktemp "$runner/.capsule.XXXXXX") || { capsule_off "runner/capsule cannot be written"; return 0; }
  printf 'lockstep-capsule 1 %s\n' "$cap_name" > "$tmp"
  chmod 600 "$tmp"
  place "$tmp" "$runner/capsule" || { rm -f "$tmp"; capsule_off "runner/capsule cannot be written"; return 0; }
  capsule_mode=1
  capsule_status_write - - = =
  log "capsule mode on: capsule $cap_name, project $cap_project, verification ${cap_verify:-none}, command limit ${cap_limit}s"
}

# The status the service shows the operator (DIR/runner/capsule-status; Lockstep.Application.CapsuleStatus).
# Arguments: ACTIVE-RUN ACTIVE-OP LAST-RUN LAST-FAILURE; "-" for none, "=" to keep what the file says.
capsule_status_write() {
  local f=$runner/capsule-status tmp out vm audit template prev_last prev_fail last fail
  out=$("$cap_rt" --state "$cap_state" inspect "$cap_name" "$cap_project" 2>/dev/null)
  vm=$(printf '%s' "$out" | sed -n 's/.* status=\([A-Za-z]*\).*/\1/p')
  audit=$(printf '%s' "$out" | sed -n 's/.* audit=\([a-z0-9-]*\).*/\1/p')
  template=$(printf '%s' "$out" | sed -n 's/.* template=\([a-z]*\).*/\1/p')
  prev_last=$(sed -n 's/^last-run //p' "$f" 2>/dev/null)
  prev_fail=$(sed -n 's/^last-failure //p' "$f" 2>/dev/null)
  last=$3
  fail=$4
  [ "$last" = "=" ] && last=${prev_last:--}
  [ "$fail" = "=" ] && fail=${prev_fail:--}
  tmp=$(mktemp "$runner/.capsule-status.XXXXXX") || return 0
  {
    printf 'lockstep-capsule-status 1\n'
    printf 'capsule %s\n' "$cap_name"
    printf 'project %s\n' "${cap_lockstep_project:--}"
    printf 'verify %s\n' "${cap_verify:--}"
    printf 'vm %s\n' "${vm:-unknown}"
    printf 'audit %s\n' "${audit:-unknown}"
    printf 'template %s\n' "${template:-unknown}"
    printf 'active-run %s\n' "$1"
    printf 'active-op %s\n' "$2"
    printf 'last-run %s\n' "$(printf '%s' "$last" | clean_detail)"
    printf 'last-failure %s\n' "$(printf '%s' "$fail" | clean_detail)"
    printf 'updated %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  chmod 600 "$tmp"
  place "$tmp" "$f" || rm -f "$tmp"
}

vm_status_of() { # CAPSULE
  "$cap_rt" --state "$cap_state" inspect "$1" "$cap_project" 2>/dev/null | sed -n 's/.* status=\([A-Za-z]*\).*/\1/p'
}

# A run's tree returned from the guest replaces the run's tree, except: protected files (the Supervisor's
# own copies are kept, as a read-only mount kept them in Phase 4) and the host tree's .git.
capsule_take_tree() { # RUN-DIR -> prints the number of protected files the guest had changed
  local dir=$1 p changed=0
  [ -d "$dir/.pulled-tree" ] || { echo 0; return 1; }
  if [ -f "$dir/protected" ]; then
    while IFS= read -r p; do
      [[ $p =~ $re_protected ]] || continue
      if ! cmp -s "$dir/tree/$p" "$dir/.pulled-tree/$p" 2>/dev/null; then changed=$((changed + 1)); fi
      # A guest that put a file where a parent directory belongs makes the restore fail: the run fails,
      # the Supervisor's tree is left as it was.
      if ! { rm -rf "${dir:?}/.pulled-tree/$p" && mkdir -p "$(dirname "$dir/.pulled-tree/$p")" && cp -p "$dir/tree/$p" "$dir/.pulled-tree/$p"; } 2>/dev/null; then
        rm -rf "$dir/.pulled-tree"
        echo "$changed"
        return 1
      fi
    done < "$dir/protected"
  fi
  if [ -d "$dir/tree/.git" ] && [ ! -L "$dir/tree/.git" ]; then
    rm -rf "$dir/.pulled-tree/.git"
    mv "$dir/tree/.git" "$dir/.pulled-tree/.git"
  fi
  rm -rf "$dir/.tree-before"
  mv "$dir/tree" "$dir/.tree-before" && mv "$dir/.pulled-tree" "$dir/tree" && rm -rf "$dir/.tree-before"
  echo "$changed"
}

capsule_take_output() { # RUN-DIR
  local dir=$1 f
  [ -d "$dir/.pulled-output" ] || return 1
  for f in "$dir/.pulled-output"/* "$dir/.pulled-output"/.[!.]*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ "$(wc -c < "$f" | tr -d ' ')" -le 8388608 ] || continue
    cp "$f" "$dir/output/${f##*/}"
  done
  rm -rf "$dir/.pulled-output"
}

# One deterministic or scripted run in a capsule (run-readonly, run-write, run-verify).
execute_capsule_run() { # ID OP RUN
  local id=$1 op=$2 run=$3 dir=$runner_work/$3 wall outlim errlim lim target=$cap_name
  local ipad=$ripad opad=$ropad results=$runner_results journal_file=$helper/runner-journal
  local started finished rc=125 outcome reply changed=0 out_bytes err_bytes p timed
  read -r wall outlim errlim <<< "$(runner_limits "$op")"
  # A capsule run's wall clock is the capsule's command limit (a real build is not a 600 s check).
  wall=$cap_limit
  started=$(date +%s)
  journal "start $id $op"
  # This run's process, so a helper that starts after a crash can end it (P5.5 review 3, M4).
  self_pid > "$dir/.capsule-pid"
  if [ "$op" = run-verify ] && [ -z "$cap_verify" ]; then
    finished=$(date +%s)
    write_result "$id" "$op" refused verification-environment-missing "$started" "$finished" "" "capsule $cap_name" || true
    journal "end $id refused"
    rm -f "$dir/.capsule-pid"
    return
  fi
  # Cancellable from here on, the restore included (M3): the cancel file and the status come first.
  rm -rf "$dir/.capsule-out"
  mkdir -m 700 "$dir/.capsule-out"
  capsule_status_write "$run" "$op" = =
  outcome=launch-failed
  local mode=keep-ignored go=yes
  if [ "$op" = run-verify ]; then
    target=$cap_verify
    # The trusted verification environment, fresh: nothing an earlier run left there survives.
    # (restore keeps a stopped VM stopped; the run needs it started.)
    if ! { "$cap_rt" --state "$cap_state" restore "$cap_verify" "$cap_project" verify &&
      "$cap_rt" --state "$cap_state" start "$cap_verify" "$cap_project"; } > "$dir/.capsule.log" 2>&1; then
      go=no
    fi
    lim=$(sed -n 's/^exec-limit //p' "$cap_state/capsules/records/$cap_verify")
    [[ $lim =~ ^[0-9]{1,6}$ ]] && wall=$lim
    # Verification gets exactly the Supervisor's tree; the Engineer's runs keep its ignored build output.
    mode=exact
  elif [ "$(vm_status_of "$target")" != Running ]; then
    # A capsule a cancelled or crashed run left stopped is started (the runtime audits before it starts).
    "$cap_rt" --state "$cap_state" start "$target" "$cap_project" >> "$dir/.capsule.log" 2>&1 || go=no
  fi
  [ -e "$dir/.cancelled" ] || [ -e "$dir/.capsule-out/.cancel" ] && { outcome=cancelled; go=no; }
  if [ "$go" = yes ] && "$cap_rt" --state "$cap_state" push "$target" "$cap_project" "$dir" "$mode" >> "$dir/.capsule.log" 2>&1 &&
    { [ ! -e "$dir/.cancelled" ] || { outcome=cancelled; false; }; }; then
    reply=$("$cap_rt" --state "$cap_state" exec-argv "$target" "$cap_project" "$dir/argv" "$wall" "$dir/.capsule-out" 2>>"$dir/.capsule.log")
    if [[ $reply =~ exec-argv\ exited\ .*exit=([0-9]+)\ timed-out=(yes|no) ]]; then
      rc=${BASH_REMATCH[1]}
      timed=${BASH_REMATCH[2]}
      outcome=exited
      [ "$timed" = yes ] && outcome=timed-out
      if [ -e "$dir/.cancelled" ] || [[ $reply =~ cancelled=yes ]]; then outcome=cancelled; fi
      # Only a run that ended by itself is collected: a cancelled or timed-out run's tree never comes back.
      if [ "$outcome" = exited ]; then
        "$cap_rt" --state "$cap_state" pull "$target" "$cap_project" "$dir" output >> "$dir/.capsule.log" 2>&1 && capsule_take_output "$dir"
        if [ "$op" = run-write ]; then
          if "$cap_rt" --state "$cap_state" pull "$target" "$cap_project" "$dir" tree >> "$dir/.capsule.log" 2>&1 &&
            changed=$(capsule_take_tree "$dir"); then
            :
          else
            outcome=launch-failed
          fi
        fi
      fi
    fi
    # Anything else (the VM went away under the program) stays launch-failed: what it did is unknown.
  fi
  # A VM the runtime stopped (deadline, cancel) is started again for the next run.
  [ "$(vm_status_of "$target")" = Running ] || "$cap_rt" --state "$cap_state" start "$target" "$cap_project" >> "$dir/.capsule.log" 2>&1
  head -c $((outlim + 1)) "$dir/.capsule-out/stdout" > "$dir/stdout" 2>/dev/null || : > "$dir/stdout"
  head -c $((errlim + 1)) "$dir/.capsule-out/stderr" > "$dir/stderr" 2>/dev/null || : > "$dir/stderr"
  rm -rf "$dir/.capsule-out" "$dir/.cancelled" "$dir/.capsule-pid"
  out_bytes=$(wc -c < "$dir/stdout" | tr -d ' ')
  err_bytes=$(wc -c < "$dir/stderr" | tr -d ' ')
  if [ "$outcome" = exited ] && { [ "$out_bytes" -gt "$outlim" ] || [ "$err_bytes" -gt "$errlim" ]; }; then outcome=output-limit; fi
  for p in stdout stderr; do
    lim=$outlim
    [ $p = stderr ] && lim=$errlim
    if [ "$(wc -c < "$dir/$p" | tr -d ' ')" -gt "$lim" ]; then
      head -c "$lim" "$dir/$p" > "$dir/.$p.cut" && place "$dir/.$p.cut" "$dir/$p"
    fi
  done
  # The operator's status first: once the result exists the run is over, and the next request may come.
  capsule_status_write - - "$op $outcome exit $rc" "$([ "$outcome" = exited ] && echo = || echo "$op: $outcome")"
  finished=$(date +%s)
  write_result "$id" "$op" "$outcome" - "$started" "$finished" "" \
    "exit $rc" "run $run" "image capsule:$target" \
    "stdout-bytes $out_bytes" "stderr-bytes $err_bytes" \
    "stdout-sha256 $(sha256 < "$dir/stdout")" "stderr-sha256 $(sha256 < "$dir/stderr")" \
    "limits $wall $outlim $errlim" "capsule $target" "protected-changed $changed" || true
  journal "end $id $outcome"
  log "$op $id: $outcome (exit $rc, capsule $target)"
}

# The argument vector of a live run in capsule mode: the built-in tools must be off (--tools "") and no
# MCP configuration of its own; the helper adds the bridge. Prints the refusal code, or nothing.
capsule_live_refusal() { # ARGV...
  local tools=0 tools_off=no prev="" a
  for a in "$@"; do
    case $a in
      --mcp-config | --mcp-config=* | --tools=* | --setting-sources* | --settings | --settings=* | --add-dir* | \
        --plugin-dir* | --plugin-url* | --agents | --agents=* | --agent | --agent=* | --allowedTools* | --allowed-tools* | \
        --bare | --ide | --chrome)
        echo argv-not-allowed-in-capsule-mode; return ;;
      --tools) tools=$((tools + 1)) ;;
    esac
    if [ "$prev" = --tools ]; then
      [ -z "$a" ] && tools_off=yes || { echo built-in-tools-not-disabled; return; }
    fi
    prev=$a
  done
  # Exactly one --tools, and its value empty.
  [ "$tools" = 1 ] && [ "$tools_off" = yes ] || echo built-in-tools-not-disabled
}

# One native live role run whose tools execute in the Engineer's capsule.
execute_capsule_live_run() { # ID OP RUN
  local id=$1 op=$2 run=$3 dir=$runner_work/$3 name=$runner_name_prefix$3 wall outlim errlim
  local results=$runner_results journal_file=$helper/runner-journal
  local net=$live_net_prefix$3 filter=$egress_prefix$3 role=reviewer bind_role summary=$provider_dir/ledger/runs/$3
  local started finished rc=125 outcome marker=$runner_work/$3/.timed-out failed=$runner_work/$3/.egress-failed
  local watchdog p out_bytes err_bytes n status tokens inv tx chan serve_pid="" refusal changed=0 mcp
  local -a argv=() args=() filter_args=()
  [ "$op" = run-live-write ] && role=implementer
  read -r wall outlim errlim <<< "$(runner_limits "$op")"
  while IFS= read -r -d '' p; do argv+=("$p"); done < "$dir/argv"
  refusal=$(capsule_live_refusal "${argv[@]}")
  [ -z "$refusal" ] || { refuse "$id" "$op" "$refusal"; return; }
  [ "$live_native" = 1 ] || { refuse "$id" "$op" capsule-mode-needs-native-auth; return; }
  case "$(id -u) $(id -g)" in
    "0 "* | "$provider_cli_uid "* | *" $provider_cli_uid") refuse "$id" "$op" isolation-unavailable; return ;;
  esac
  status=$(docker run --rm --user "$provider_cli_uid:$provider_cli_uid" --read-only --tmpfs /tmp --network none \
    --cap-drop ALL --security-opt no-new-privileges --log-driver none \
    --env HOME=/tmp --env CLAUDE_CONFIG_DIR=/auth --mount "type=volume,source=$auth_volume,target=/auth" \
    "$provider_image" claude auth status --json 2>/dev/null < /dev/null || true)
  case $status in *'"loggedIn": true'*) ;; *) refuse "$id" "$op" not-authenticated; return ;; esac
  started=$(date +%s)
  journal "start $id $op"
  self_pid > "$dir/.capsule-pid"
  # Where the role works. The Implementer: its own capsule, its ignored build output kept. A read-only
  # role (Planner, Challenger, Reviewer): the verification capsule, restored from its trusted snapshot,
  # with exactly the Supervisor's tree, so nothing an Implementer left running can show it other code
  # or change what it reads (P5.5 review finding 1). No verification capsule: refused.
  local target=$cap_name mode=keep-ignored tlimit=$cap_limit
  if [ "$role" != implementer ]; then
    if [ -z "$cap_verify" ]; then
      finished=$(date +%s)
      write_result "$id" "$op" refused verification-environment-missing "$started" "$finished" "a read-only role needs the verification capsule" "capsule $cap_name" || true
      journal "end $id refused"
      return
    fi
    target=$cap_verify
    mode=exact
    tlimit=$(sed -n 's/^exec-limit //p' "$cap_state/capsules/records/$cap_verify")
    if ! { "$cap_rt" --state "$cap_state" restore "$cap_verify" "$cap_project" verify &&
      "$cap_rt" --state "$cap_state" start "$cap_verify" "$cap_project"; } > "$dir/.capsule.log" 2>&1; then
      finished=$(date +%s)
      write_result "$id" "$op" launch-failed - "$started" "$finished" "verification capsule restore failed" "capsule $cap_verify" || true
      journal "end $id launch-failed"
      return
    fi
  fi
  outcome=launch-failed
  if ! "$cap_rt" --state "$cap_state" push "$target" "$cap_project" "$dir" "$mode" >> "$dir/.capsule.log" 2>&1; then
    finished=$(date +%s)
    write_result "$id" "$op" launch-failed - "$started" "$finished" "capsule push failed" "capsule $target" || true
    journal "end $id launch-failed"
    return
  fi
  inv=$run
  tx=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  if ! "$cap_rt" --state "$cap_state" bind "$inv" "$target" "$cap_project" "$tx" "$role" "$tlimit" >> "$dir/.capsule.log" 2>&1; then
    finished=$(date +%s)
    write_result "$id" "$op" refused capsule-bind-refused "$started" "$finished" "$(tail -n 1 "$dir/.capsule.log" | clean_detail)" "capsule $cap_name" || true
    journal "end $id refused"
    return
  fi
  chan=$cap_state/capsules/invocations/$inv/channel
  capsule_status_write "$run" "$op" = =
  "$cap_rt" --state "$cap_state" serve "$inv" >> "$dir/.capsule.log" 2>&1 &
  serve_pid=$!
  mcp="{\"mcpServers\":{\"capsule\":{\"type\":\"stdio\",\"command\":\"/usr/bin/python3\",\"args\":[\"/opt/lockstep/capsule-bridge\",\"--channel\",\"/bridge\",\"--role\",\"$([ "$role" = implementer ] && echo write || echo readonly)\",\"--wait-limit\",\"$((cap_limit + 60))\",\"--input-dir\",\"/input\",\"--answer-dir\",\"/output\"]}}}"
  rm -f "$marker" "$failed" "$summary" "$summary.ready"
  mkdir -p "$provider_dir/ledger/runs" 2>/dev/null || true
  filter_args=(--run "$run" --ledger /ledger --allow "$egress_hosts")
  [ -n "$test_upstream" ] && filter_args+=(--map "api.anthropic.com=$test_upstream")
  rc=125
  if docker network create --internal "$net" >/dev/null 2>&1 &&
    docker run -d --name "$filter" --network "$net" --network-alias lockstep-egress --read-only \
      --tmpfs /tmp:rw,nosuid,nodev,size=16777216 --cap-drop ALL --security-opt no-new-privileges \
      --pids-limit 64 --memory 256m --memory-swap 256m --cpus 1 --user "$(id -u):$(id -g)" --log-driver none \
      --env HOME=/tmp --env PATH=/usr/local/bin:/usr/bin:/bin --env LANG=C.UTF-8 --env TZ=UTC \
      --mount "type=bind,source=$provider_dir/ledger,target=/ledger" \
      "$provider_image" python3 /opt/lockstep/egress-proxy passthrough "${filter_args[@]}" < /dev/null >/dev/null 2>&1; then
    n=0
    while [ ! -f "$summary.ready" ] && [ $n -lt 150 ]; do sleep 0.1; n=$((n + 1)); done
    if [ -f "$summary.ready" ] && docker network connect "$egress_network" "$filter" >/dev/null 2>&1; then
      # As execute_native_run, except: no tree, input or output mount (the role works in the capsule);
      # the channel's requests/ read-write and results/ read-only; the bridge; the CLI's MCP config.
      args=(run --rm --name "$name" --network "$net" --read-only
        --tmpfs /tmp:rw,nosuid,nodev,size=268435456
        --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE --cap-add KILL
        --security-opt no-new-privileges
        --pids-limit 256 --memory 4g --memory-swap 4g --cpus 2
        --user 0:0
        --env HOME=/tmp --env PATH=/usr/local/bin:/usr/bin:/bin --env LANG=C.UTF-8 --env LC_ALL=C.UTF-8 --env TZ=UTC
        --env HTTPS_PROXY=http://lockstep-egress:8080 --env HTTP_PROXY=http://lockstep-egress:8080
        --env NO_PROXY= --env no_proxy=
        --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 --env DISABLE_AUTOUPDATER=1
        --env DISABLE_TELEMETRY=1 --env DISABLE_ERROR_REPORTING=1
        --env "CLAUDE_CODE_MAX_OUTPUT_TOKENS=$live_max_tokens"
        --env "MCP_TOOL_TIMEOUT=$(((cap_limit + 120) * 1000))"
        --env CLAUDE_CONFIG_DIR=/auth
        --mount "type=volume,source=$auth_volume,target=/auth"
        --mount "type=bind,source=$cap_bridge,target=/opt/lockstep/capsule-bridge,readonly"
        --mount "type=bind,source=$chan/requests,target=/bridge/requests"
        --mount "type=bind,source=$chan/results,target=/bridge/results,readonly"
        --mount "type=bind,source=$dir/input,target=/input,readonly"
        --mount "type=bind,source=$dir/output,target=/output"
        --log-driver none --workdir /tmp)
      [ -n "$test_ca" ] && args+=(--env NODE_EXTRA_CA_CERTS=/etc/lockstep/ca.pem
        --mount "type=bind,source=$test_ca,target=/etc/lockstep/ca.pem,readonly")
      args+=("$provider_image" /opt/lockstep/agent-entry "$(id -u)" "$(id -g)" "${argv[0]}" --mcp-config "$mcp" "${argv[@]:1}")
      # A capsule role may build for a long time: its wall clock is the role limit or the command limit.
      [ "$cap_limit" -gt "$wall" ] && wall=$((cap_limit + 300))
      (
        deadline=$(($(date +%s) + wall))
        while [ "$(date +%s)" -lt "$deadline" ]; do
          sleep 1
          if [ "$(docker container inspect --format '{{.State.Running}}' "$filter" 2>/dev/null)" != true ]; then
            : > "$failed"; docker kill "$name" >/dev/null 2>&1; exit 0
          fi
        done
        : > "$marker"; docker kill "$name" >/dev/null 2>&1
      ) &
      watchdog=$!
      # A cancel that came during the setup: the CLI is never started.
      if [ -e "$runner_work/$run/.cancelled" ]; then : > "$dir/stdout"; : > "$dir/stderr"
      else docker "${args[@]}" < /dev/null 2> >(head -c $((errlim + 1)) > "$dir/stderr") | head -c $((outlim + 1)) > "$dir/stdout"
      fi
      rc=${PIPESTATUS[0]}
      kill "$watchdog" 2>/dev/null
      pkill -P "$watchdog" 2>/dev/null
      wait "$watchdog" 2>/dev/null
      [ "$(docker container inspect --format '{{.State.Running}}' "$filter" 2>/dev/null)" = true ] || : > "$failed"
    else
      : > "$failed"
    fi
  else
    : > "$failed"
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker stop --time 3 "$filter" >/dev/null 2>&1 || true
  docker rm -f "$filter" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  # The invocation ends: its channel is closed and served no more.
  "$cap_rt" --state "$cap_state" close "$inv" >/dev/null 2>&1
  [ -n "$serve_pid" ] && { kill "$serve_pid" 2>/dev/null; wait "$serve_pid" 2>/dev/null; }
  # The role's answer is already in the run's own output (the bridge wrote it there, on the host side).
  # The Implementer's tree comes back from its capsule, only after a run that ended by itself.
  local collect=ok
  if [ "$role" = implementer ] && [ ! -e "$runner_work/$run/.cancelled" ] && [ ! -e "$marker" ] && [ ! -e "$failed" ]; then
    if "$cap_rt" --state "$cap_state" pull "$cap_name" "$cap_project" "$dir" tree >> "$dir/.capsule.log" 2>&1 &&
      changed=$(capsule_take_tree "$dir"); then
      :
    else
      collect=failed
    fi
  fi
  sleep 0.2
  finished=$(date +%s)
  touch "$dir/stdout" "$dir/stderr"
  out_bytes=$(wc -c < "$dir/stdout" | tr -d ' ')
  err_bytes=$(wc -c < "$dir/stderr" | tr -d ' ')
  tokens=$(native_tokens "$dir/stdout")
  if [ -e "$runner_work/$run/.cancelled" ]; then outcome=cancelled
  elif [ -e "$marker" ]; then outcome=timed-out
  elif [ -e "$failed" ]; then outcome=provider-stopped
  elif [ "$out_bytes" -gt "$outlim" ] || [ "$err_bytes" -gt "$errlim" ]; then outcome=output-limit
  elif [ "$rc" = 125 ]; then outcome=launch-failed
  elif [ "$collect" = failed ]; then outcome=launch-failed
  else outcome=exited
  fi
  rm -f "$marker" "$runner_work/$run/.cancelled"
  # The operator's status first: once the result exists the run is over, and the next request may come.
  capsule_status_write - - "$op $outcome exit $rc" "$([ "$outcome" = exited ] && echo = || echo "$op: $outcome")"
  if [ "$outcome" = provider-stopped ]; then
    write_result "$id" "$op" provider-stopped - "$started" "$finished" "" \
      "exit $rc" "run $run" "image $provider_image" "provider-stop egress-failed" \
      "egress.micro 0" "egress.tokens $tokens" "capsule $target" || true
  elif [ "$collect" = failed ]; then
    write_result "$id" "$op" launch-failed - "$started" "$finished" "the capsule's tree could not be collected safely" \
      "exit $rc" "run $run" "image $provider_image" "egress.micro 0" "egress.tokens $tokens" "capsule $target" || true
  else
    write_result "$id" "$op" "$outcome" - "$started" "$finished" "" \
      "exit $rc" "run $run" "image $provider_image" \
      "stdout-bytes $out_bytes" "stderr-bytes $err_bytes" \
      "stdout-sha256 $(sha256 < "$dir/stdout")" "stderr-sha256 $(sha256 < "$dir/stderr")" \
      "limits $wall $outlim $errlim" "egress.micro 0" "egress.tokens $tokens" \
      "capsule $target" "invocation $inv" "protected-changed $changed" || true
  fi
  rm -f "$failed" "$dir/.capsule-pid"
  journal "end $id $outcome"
  log "$op $id: $outcome (exit $rc, $tokens tokens, capsule $target)"
}
