#!/bin/bash                                                   set -Eeo pipefail

TASK_DIR="${HOME}/.kiro/deep-thinker-tasks"
TASK_FILE="${TASK_DIR}/current-tasks.json"
LOCK_DIR="${TASK_FILE}.lock"                                  
command -v jq >/dev/null || { echo "jq required" >&2; exit 127; }

mkdir -p "$TASK_DIR"

now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

new_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr -d '-' | cut -c1-13
  else                                                            python3 -c "import uuid; print(uuid.uuid4().hex[:13])"
  fi
}

acquire_lock() {                                                local i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    ((i++))
    [[ $i -gt 100 ]] && { echo "Lock timeout: $LOCK_DIR" >&2; exit 75; }
    sleep 0.05                                                  done                                                          trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT           }

if [[ ! -f "$TASK_FILE" ]]; then
  jq -n '{schema_version:1,project:"",description:"",created:null,updated:null,status:"pending",wip_limit:3,tasks:[]}' > "$TASK_FILE"
fi

cmd="$1"
shift || true

case "$cmd" in
  init)
    project_name="${1:-}"; description="${2:-}"
    [[ -n "$project_name" ]] || { echo "usage: init \"Project\" \"Description\"" >&2; exit 2; }
                                                                  acquire_lock
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    jq -n \
      --arg project "$project_name" \
      --arg description "$description" \                            --arg created "$(now)" \
      '{                                                              schema_version: 1,
        project: $project,
        description: $description,
        created: $created,                                            updated: $created,
        status: "in-progress",
        wip_limit: 3,
        tasks: []                                                   }' > "$tmp" && mv -f "$tmp" "$TASK_FILE"
                                                                  echo "Initialized: $project_name"
    ;;

  add)
    title="${1:-}"; details="${2:-}"; priority="${3:-medium}"
    [[ -n "$title" ]] || { echo "usage: add \"Title\" \"Details\" [priority]" >&2; exit 2; }                                    [[ "$priority" =~ ^(high|medium|low)$ ]] || { echo "priority must be high/medium/low" >&2; exit 2; }                    
    task_id="$(new_id)"
    acquire_lock
    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    jq --arg id "$task_id" \
       --arg title "$title" \                                        --arg details "$details" \
       --arg priority "$priority" \                                  --arg created "$(now)" \
       '.tasks += [{
         id: $id,
         title: $title,
         details: $details,
         priority: $priority,
         status: "pending",
         created: $created,
         subtasks: [],
         updates: [],
         blockers: [],
         files: [],
         definition_of_done: [],                                       acceptance_criteria: [],                                      next_action: null,                                            if_blocked_then: null
       }] | .updated = $created' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"

    echo "Added task [$task_id]: $title"
    ;;

  subtask)
    parent_id="${1:-}"; title="${2:-}"; details="${3:-}"
    [[ -n "$parent_id" && -n "$title" ]] || { echo "usage: subtask \"parent_id\" \"Title\" \"Details\"" >&2; exit 2; }
                                                                  acquire_lock
    jq -e --arg pid "$parent_id" 'any(.tasks[]; .id==$pid)' "$TASK_FILE" >/dev/null \
      || { echo "No such task: $parent_id" >&2; exit 4; }

    subtask_id="$(new_id)"
    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true       tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"                                                                          jq --arg pid "$parent_id" \
       --arg id "$subtask_id" \
       --arg title "$title" \
       --arg details "$details" \
       --arg time "$(now)" \
       '(.tasks[] | select(.id == $pid) | .subtasks) += [{
         id: $id,
         title: $title,
         details: $details,
         status: "pending",
         created: $time
       }] | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"

    echo "Added subtask [$subtask_id] to [$parent_id]"
    ;;

  note)
    task_id="${1:-}"; content="${2:-}"; note_type="${3:-note}"
    [[ -n "$task_id" && -n "$content" ]] || { echo "usage: note \"task_id\" \"Content\" [type]" >&2; exit 2; }

    acquire_lock
    jq -e --arg tid "$task_id" 'any(.tasks[]; .id==$tid)' "$TASK_FILE" >/dev/null \
      || { echo "No such task: $task_id" >&2; exit 4; }

    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    jq --arg tid "$task_id" \
       --arg content "$content" \
       --arg type "$note_type" \
       --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid) | .updates) += [{
         time: $time,
         type: $type,
         content: $content
       }] | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"

    echo "Added $note_type to [$task_id]"
    ;;

  block)
    task_id="${1:-}"; description="${2:-}"
    [[ -n "$task_id" && -n "$description" ]] || { echo "usage: block \"task_id\" \"Description\"" >&2; exit 2; }

    acquire_lock
    jq -e --arg tid "$task_id" 'any(.tasks[]; .id==$tid)' "$TASK_FILE" >/dev/null \
      || { echo "No such task: $task_id" >&2; exit 4; }

    blocker_id="$(new_id)"
    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    jq --arg tid "$task_id" \
       --arg bid "$blocker_id" \
       --arg desc "$description" \
       --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid) | .blockers) += [{
         id: $bid,
         created: $time,
         desc: $desc,
         status: "open"
       }] | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"

    echo "Added blocker [$blocker_id] to [$task_id]"
    ;;

  unblock)
    task_id="${1:-}"; blocker_id="${2:-}"
    [[ -n "$task_id" && -n "$blocker_id" ]] || { echo "usage: unblock \"task_id\" \"blocker_id\"" >&2; exit 2; }

    acquire_lock
    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    jq --arg tid "$task_id" \
       --arg bid "$blocker_id" \
       --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid) | .blockers[] | select(.id == $bid))                                                        |= (. + {status: "resolved", resolved: $time})
        | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"

    echo "Resolved blocker [$blocker_id]"
    ;;

  dod)
    task_id="${1:-}"; criterion="${2:-}"
    [[ -n "$task_id" && -n "$criterion" ]] || { echo "usage: dod \"task_id\" \"Criterion\"" >&2; exit 2; }                  
    acquire_lock                                                  cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"                                                                          jq --arg tid "$task_id" \                                        --arg crit "$criterion" \
       --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid) | .definition_of_done) += [$crit]
        | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"

    echo "Added DoD to [$task_id]"
    ;;

  next)
    task_id="${1:-}"; action="${2:-}"; if_blocked="${3:-}"
    [[ -n "$task_id" && -n "$action" ]] || { echo "usage: next \"task_id\" \"Action\" [if_blocked]" >&2; exit 2; }

    acquire_lock                                                  cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    jq --arg tid "$task_id" \
       --arg action "$action" \
       --arg blocked "$if_blocked" \                                 --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid))                              |= (. + {next_action: $action, if_blocked_then: (if $blocked == "" then null else $blocked end)})
        | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"                                              
    echo "Set next action for [$task_id]"
    ;;
                                                                start)
    task_id="${1:-}"
    [[ -n "$task_id" ]] || { echo "usage: start \"task_id\"" >&2; exit 2; }                                                                                                                   acquire_lock
    wip_count=$(jq '[.tasks[] | select(.status == "in-progress")] | length' "$TASK_FILE")
    wip_limit=$(jq -r '.wip_limit // 3' "$TASK_FILE")

    if [[ $wip_count -ge $wip_limit ]]; then
      echo "WIP limit ($wip_limit) reached. Complete a task first." >&2                                                           exit 3
    fi

    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    jq --arg tid "$task_id" \
       --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid))
        |= (. + {status: "in-progress", started: $time})              | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"                                              
    echo "Started [$task_id]"
    ;;

  file)
    task_id="${1:-}"; filepath="${2:-}"; action="${3:-modified}"                                                                [[ -n "$task_id" && -n "$filepath" ]] || { echo "usage: file \"task_id\" \"path\" [action]" >&2; exit 2; }              
    acquire_lock
    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    jq --arg tid "$task_id" \
       --arg path "$filepath" \
       --arg action "$action" \                                      --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid) | .files) += [{                path: $path,
         action: $action,
         time: $time
       }] | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"

    echo "Tracked file [$filepath]"                               ;;
                                                                complete)
    task_id="${1:-}"; subtask_id="${2:-}"
    [[ -n "$task_id" ]] || { echo "usage: complete \"task_id\" [subtask_id]" >&2; exit 2; }                                                                                                   acquire_lock                                                  cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    if [[ -n "$subtask_id" ]]; then
      jq --arg tid "$task_id" \
         --arg sid "$subtask_id" \
         --arg time "$(now)" \
         '(.tasks[] | select(.id == $tid) | .subtasks[] | select(.id == $sid))                                                        |= (. + {status: "done", completed: $time})                   | (.tasks[] | select(.id == $tid) | .updates) += [{
            time: $time,
            type: "subtask_complete",
            content: "Completed subtask: \((.tasks[] | select(.id == $tid) | .subtasks[] | select(.id == $sid) | .title))"            }]
          | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"
      echo "Completed subtask [$subtask_id]"
    else                                                            jq --arg tid "$task_id" \
         --arg time "$(now)" \
         '(.tasks[] | select(.id == $tid))                              |= (. + {status: "done", completed: $time})
          | (.tasks[] | select(.id == $tid) | .updates) += [{
            time: $time,                                                  type: "status_change",                                        content: "Task completed"                                   }]
          | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"
      echo "Completed task [$task_id]"
    fi
    ;;
                                                                cancel)
    task_id="${1:-}"; reason="${2:-User canceled}"                [[ -n "$task_id" ]] || { echo "usage: cancel \"task_id\" [reason]" >&2; exit 2; }                                       
    acquire_lock
    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"
                                                                  jq --arg tid "$task_id" \                                        --arg reason "$reason" \                                      --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid))
        |= (. + {status: "canceled", canceled: $time, cancel_reason: $reason})
        | (.tasks[] | select(.id == $tid) | .updates) += [{
          time: $time,
          type: "status_change",                                        content: "Canceled: \($reason)"                             }]                                                            | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"

    echo "Canceled task [$task_id]"                               ;;                                                                                                                        reopen)
    task_id="${1:-}"
    [[ -n "$task_id" ]] || { echo "usage: reopen \"task_id\"" >&2; exit 2; }

    acquire_lock
    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    jq --arg tid "$task_id" \
       --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid))
        |= (. + {status: "pending"} | del(.completed, .canceled, .cancel_reason))
        | (.tasks[] | select(.id == $tid) | .updates) += [{
          time: $time,
          type: "status_change",
          content: "Reopened"
        }]                                                            | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"

    echo "Reopened task [$task_id]"                               ;;                                                        
  priority)
    task_id="${1:-}"; new_priority="${2:-}"
    [[ -n "$task_id" && -n "$new_priority" ]] || { echo "usage: priority \"task_id\" high|medium|low" >&2; exit 2; }
    [[ "$new_priority" =~ ^(high|medium|low)$ ]] || { echo "priority must be high/medium/low" >&2; exit 2; }
                                                                  acquire_lock
    cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true
    tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"

    old_priority=$(jq -r --arg tid "$task_id" '.tasks[] | select(.id == $tid) | .priority' "$TASK_FILE")

    jq --arg tid "$task_id" \
       --arg priority "$new_priority" \
       --arg old "$old_priority" \                                   --arg time "$(now)" \
       '(.tasks[] | select(.id == $tid))                              |= (. + {priority: $priority})
        | (.tasks[] | select(.id == $tid) | .updates) += [{             time: $time,
          type: "priority_change",
          content: "Priority changed: \($old) → \($priority)"
        }]
        | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"                                                                                                                echo "Changed priority [$task_id]: $old_priority → $new_priority"
    ;;

  estimate)
    task_id="${1:-}"; estimate="${2:-}"                           [[ -n "$task_id" && -n "$estimate" ]] || { echo "usage: estimate \"task_id\" \"2 hours\"" >&2; exit 2; }

    acquire_lock                                                  cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true       tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"                                                                          jq --arg tid "$task_id" \                                        --arg est "$estimate" \                                       --arg time "$(now)" \                                         '(.tasks[] | select(.id == $tid))                              |= (. + {estimate: $est})                                     | (.tasks[] | select(.id == $tid) | .updates) += [{             time: $time,                                                  type: "estimate",                                             content: "Estimated: \($est)"                               }]                                                            | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"                                                                                                                echo "Set estimate [$task_id]: $estimate"                     ;;                                                                                                                        history)                                                        task_id="${1:-}"                                              [[ -n "$task_id" ]] || { echo "usage: history \"task_id\"" >&2; exit 2; }                                                                                                                 jq -r --arg tid "$task_id" '                                    .tasks[] | select(.id == $tid) |                              "Task: \(.title)\nID: \(.id)\n\nHistory:\n" +                 (.updates | sort_by(.time) | map(                               "[\(.time)] [\(.type | ascii_upcase)] \(.content // .note // "")" +                                                         if .pct then " (\(.pct)%)" else "" end                      ) | join("\n"))                                             ' "$TASK_FILE"                                                ;;                                                                                                                        archive)                                                        output="${1:-archived-tasks.json}"                                                                                          acquire_lock                                                                                                                # Extract completed/canceled tasks                            jq '{                                                           archived: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),             tasks: [.tasks[] | select(.status == "done" or .status == "canceled")]                                                    }' "$TASK_FILE" > "$output"                                                                                                 # Remove from active                                          cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true       tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"                                                                          jq '.tasks = [.tasks[] | select(.status != "done" and .status != "canceled")]                                                   | .updated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \       "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"                                                                       count=$(jq '.tasks | length' "$output")                       echo "Archived $count tasks to $output"                       ;;                                                                                                                        progress)                                                       task_id="${1:-}"; percentage="${2:-}"; status_note="${3:-}"                                                                 [[ -n "$task_id" && -n "$percentage" ]] || { echo "usage: progress \"task_id\" \"pct\" \"note\"" >&2; exit 2; }             [[ "$percentage" =~ ^[0-9]+$ && "$percentage" -ge 0 && "$percentage" -le 100 ]] || { echo "pct must be 0-100" >&2; exit 2; }                                                                                                                            acquire_lock                                                  cp -p "$TASK_FILE" "$TASK_FILE.bak" 2>/dev/null || true       tmp="$(mktemp -p "$TASK_DIR" ".tasks.tmp.XXXXXX")"                                                                          jq --arg tid "$task_id" \                                        --argjson pct "$percentage" \                                 --arg note "$status_note" \                                   --arg time "$(now)" \                                         '(.tasks[] | select(.id == $tid))                              |= (. + {progress: $pct})                                     | (.tasks[] | select(.id == $tid) | .updates) += [{             time: $time,                                                  type: "progress",                                             pct: $pct,                                                    note: $note                                                 }]                                                            | .updated = $time' "$TASK_FILE" > "$tmp" && mv -f "$tmp" "$TASK_FILE"                                                                                                                echo "Updated progress [$task_id]: ${percentage}%"            ;;                                                                                                                        llm-context)                                                    query="${1:-}"                                                k="${2:-8}"                                                   mode="${3:-execute}"                                                                                                        python3 "$(dirname "$0")/task-llm-context.py" \                 --task-file "$TASK_FILE" \                                    --index-db "$TASK_DIR/index.sqlite" \                         --query "$query" \                                            --k "$k" \                                                    --mode "$mode"                                              ;;                                                                                                                        context)                                                        n="${1:-5}"                                                   query="${2:-}"                                                mode="${3:-execute}"                                                                                                        # Smart ranking: actionability + recency + priority           # Modes: execute (default), plan, unblock, recent, wip        jq --argjson n "$n" --arg query "$query" --arg mode "$mode" '                                                                 def days_ago: if . then ((now - (. | fromdateiso8601)) / 86400) else 9999 end;                                              def recency_boost: (1 / (1 + (days_ago / 7)));                def priority_score: {"high": 3, "medium": 2, "low": 1}[.] // 1;                                                             def matches_query: if $query == "" then true else ((.title + " " + .details) | ascii_downcase | contains($query | ascii_downcase)) end;                                                                                                                 {                                                               project, description, status, updated, wip_limit, mode: $mode, query: $query,                                               tasks: (                                                        .tasks                                                        | map(select(.status != "done" and .status != "canceled"))                                                                  | map(select(matches_query))                                                                                                # Mode filters                                                | if $mode == "unblock" then map(select([.blockers[]? | select(.status == "open")] | length > 0))                             elif $mode == "wip" then map(select(.status == "in-progress"))                                                              elif $mode == "recent" then .                                 else . end                                                                                                                # Compute composite score                                     | map(. + {                                                       _actionability: (                                               (if .status == "in-progress" then 2 else 0 end) +                                                                           (if .next_action then 1.5 else 0 end) +                       (if ([.blockers[]? | select(.status == "open")] | length) > 0 then -2 else 0 end) +                                         (.priority | priority_score)                                ),                                                            _recency: (                                                     ([.created, .started, .updates[-1]?.time] | map(select(. != null and . != "")) | if length > 0 then max else null end) as $latest                                                         | if $latest then ($latest | recency_boost) else 0.1 end                                                                  )                                                           })                                                          | map(. + {_score: (._actionability * 0.6 + ._recency * 0.4)})                                                                                                                            # Sort by mode                                                | if $mode == "recent" then sort_by(-._recency)                 else sort_by(-._score) end                                                                                                | .[0:$n]                                                     | map({                                                           id, title, priority, status, progress,                        next_action, if_blocked_then,                                 score: (._score | . * 100 | round / 100),                     subtasks: [.subtasks[]? | select(.status != "done") | {id, title}],                                                         blockers: [.blockers[]? | select(.status == "open") | {id, desc}],                                                          recent_updates: [.updates[-3:][]? | {time, type, content: (.content // .note)}]                                           })                                                        )                                                           }                                                           ' "$TASK_FILE"                                                ;;                                                                                                                        show)                                                           task_id="${1:-all}"                                                                                                         if [[ "$task_id" == "all" ]]; then                              jq -r '                                                         "Project: \(.project)\nDescription: \(.description // "N/A")\nStatus: \(.status)\nWIP Limit: \(.wip_limit)\n\nTasks:\n" +                                                                 (.tasks | to_entries | map(                                     "[\(.value.id)] [\(.value.status | ascii_upcase)] \(.value.title)\n" +                                                      "    Priority: \(.value.priority) | Progress: \(.value.progress // 0)%\n" +                                                 if .value.next_action then "    Next: \(.value.next_action)\n" else "" end +                                                "    Subtasks: \(.value.subtasks | length) | Blockers: \([.value.blockers[] | select(.status=="open")] | length)\n"                                                                     ) | join("\n"))                                             ' "$TASK_FILE"                                              else                                                            jq -r --arg tid "$task_id" '                                    .tasks[] | select(.id == $tid) |                              "Task: \(.title)\nID: \(.id)\nStatus: \(.status)\nPriority: \(.priority)\nProgress: \(.progress // 0)%\n" +                 if .next_action then "Next Action: \(.next_action)\n" else "" end +                                                         if .if_blocked_then then "If Blocked: \(.if_blocked_then)\n" else "" end +                                                  "\nDetails:\n\(.details)\n" +                                 "\nDefinition of Done:\n" + (.definition_of_done | map("  - \(.)") | join("\n")) +                                          "\n\nSubtasks:\n" + (.subtasks | map("  [\(.status)] \(.title)") | join("\n")) +                                            "\n\nUpdates:\n" + (.updates | sort_by(.time) | reverse | map("  [\(.time)] [\(.type)] \(.content // .note // "")") | join("\n")) +                                                       "\n\nBlockers:\n" + (.blockers | map("  [\(.status)] \(.desc)") | join("\n")) +                                             "\n\nFiles:\n" + (.files | map("  [\(.action)] \(.path)") | join("\n"))                                                   ' "$TASK_FILE"                                              fi                                                            ;;                                                                                                                        export)                                                         output="${1:-tasks.md}"                                                                                                     jq -r '                                                         "# \(.project)\n\n" +                                         if .description then "> \(.description)\n\n" else "" end +                                                                  "**Status:** \(.status)  \n**Updated:** \(.updated)\n\n---\n\n## Tasks\n\n" +                                               (.tasks | map(                                                  "### \(.title)\n\n" +                                         "- **ID:** `\(.id)`\n" +                                      "- **Status:** \(.status)\n" +                                "- **Priority:** \(.priority)\n" +                            "- **Progress:** \(.progress // 0)%\n" +                      if .next_action then "- **Next:** \(.next_action)\n" else "" end +                                                          "\n**Details:**\n\(.details)\n\n" +                           if (.definition_of_done | length) > 0 then                      "**Definition of Done:**\n" + (.definition_of_done | map("- \(.)") | join("\n")) + "\n\n"                                 else "" end +                                                 if (.subtasks | length) > 0 then                                "**Subtasks:**\n" + (.subtasks | map("- [\(if .status == "done" then "x" else " " end)] \(.title)") | join("\n")) + "\n\n"                                                              else "" end +                                                 if (.updates | length) > 0 then                                 "**Updates:**\n" + (.updates | sort_by(.time) | reverse | .[0:5] | map("> [\(.type)] \(.content // .note // "")") | join("\n")) + "\n\n"                                                else "" end +                                                 if ([.blockers[] | select(.status=="open")] | length) > 0 then                                                                "**Blockers:**\n" + ([.blockers[] | select(.status=="open")] | map("- ⚠️ \(.desc)") | join("\n")) + "\n\n"                 else "" end +                                                 "---\n\n"                                                   ) | join(""))                                               ' "$TASK_FILE" > "$output"                                                                                                  echo "Exported to $output"                                    ;;                                                                                                                        clear)                                                          acquire_lock                                                  jq -n '{schema_version:1,project:"",description:"",created:null,updated:null,status:"pending",wip_limit:3,tasks:[]}' > "$TASK_FILE"                                                       echo "Cleared all tasks"                                      ;;                                                                                                                        json)                                                           cat "$TASK_FILE"                                              ;;                                                                                                                        schema)                                                         cat << 'SCHEMA'                                           {                                                               "schema_version": 1,                                          "project": "string",                                          "description": "string",                                      "created": "ISO8601",                                         "updated": "ISO8601",                                         "status": "pending|in-progress|done",                         "wip_limit": "number (default 3)",                            "tasks": [{                                                     "id": "string (13 chars)",                                    "title": "string",                                            "details": "string",                                          "priority": "high|medium|low",                                "status": "pending|in-progress|blocked|done|canceled",        "created": "ISO8601",                                         "started": "ISO8601?",                                        "completed": "ISO8601?",                                      "progress": "number 0-100",                                   "next_action": "string?",                                     "if_blocked_then": "string?",                                 "definition_of_done": ["string"],                             "acceptance_criteria": ["string"],                            "subtasks": [{                                                  "id": "string",                                               "title": "string",                                            "details": "string",                                          "status": "pending|done",                                     "created": "ISO8601",                                         "completed": "ISO8601?"                                     }],                                                           "updates": [{                                                   "time": "ISO8601",                                            "type": "note|decision|progress",                             "content": "string",                                          "pct": "number?"                                            }],                                                           "blockers": [{                                                  "id": "string",                                               "created": "ISO8601",                                         "desc": "string",                                             "status": "open|resolved",                                    "resolved": "ISO8601?"                                      }],                                                           "files": [{                                                     "path": "string",                                             "action": "created|modified|deleted",                         "time": "ISO8601"                                           }]                                                          }]                                                          }                                                             SCHEMA                                                            ;;                                                                                                                        *)                                                              cat << 'HELP'                                             Deep Thinker Task Manager v2                                                                                                Commands:                                                       init "Project" "Description"         - Initialize project     add "Title" "Details" [priority]     - Add task (high/medium/low)                                                           subtask "task_id" "Title" "Details"  - Add subtask            note "task_id" "Content" [type]      - Add note (type: note/decision/progress)                                              block "task_id" "Description"        - Add blocker            unblock "task_id" "blocker_id"       - Resolve blocker        dod "task_id" "Criterion"            - Add definition of done                                                               next "task_id" "Action" [if_blocked] - Set next action        start "task_id"                      - Start task (checks WIP limit)                                                        file "task_id" "path" [action]       - Track file             complete "task_id" [subtask_id]      - Mark complete
  cancel "task_id" [reason]            - Cancel task            reopen "task_id"                     - Reopen task            priority "task_id" high|medium|low   - Change priority        estimate "task_id" "2 hours"         - Set time estimate
  progress "task_id" "%" "note"        - Update progress
  history "task_id"                    - Show full history
  archive [filepath]                   - Archive completed tasks
  llm-context [query] [k] [mode]        - Smart retrieval (BM25 + MMR, Python)
  context [N] [query] [mode]          - Smart context (modes: execute/plan/unblock/recent/wip)
  show [task_id|all]                   - Show tasks
  export [filepath]                    - Export markdown
  clear                                - Clear all
  json                                 - Raw JSON
  schema                               - Show schema

Examples:
  task-manager init "Add Auth" "User authentication"
  task-manager add "Schema" "Design user table" high
  task-manager dod TASK_ID "All tests pass"
  task-manager next TASK_ID "Run migrations" "Ask for DB creds"                                                               task-manager start TASK_ID
  task-manager note TASK_ID "Using bcrypt cost=12" decision
  task-manager progress TASK_ID 50 "Schema done"
  task-manager history TASK_ID                                  task-manager archive archived-2024.json                       task-manager context 3
HELP
    ;;
esac
