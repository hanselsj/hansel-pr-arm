#!/bin/bash
#
# <xbar.title>PR Auto-Merge</xbar.title>
# <xbar.version>1.1</xbar.version>
# <xbar.author>hanselsj (built with Claude Code)</xbar.author>
# <xbar.desc>Lists your open authored PRs with review+CI status. Click a row to arm/disarm auto-merge. Armed PRs are merged (merge commit + delete branch) once approved and all checks pass. Renders instantly from cache; fetches in the background.</xbar.desc>
# <swiftbar.refreshOnOpen>false</swiftbar.refreshOnOpen>
#
# Architecture: the menu RENDERS from a cached snapshot (instant, no network) and
# kicks off a detached background FETCH that refreshes GitHub data + runs the merge
# engine, then asks SwiftBar to redraw. Opening the menu never blocks on the network.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SELF="/Users/hanselmatthew/Files/Swiftbar/prmerge.1m.sh"
PLUGIN_NAME="prmerge.1m.sh"          # used for the SwiftBar refresh URL
STATE="$HOME/.pr-merge-queue/armed.txt"
LOG="$HOME/.pr-merge-queue/merge.log"
CACHE="$HOME/.pr-merge-queue/last.json"
LOCK="$HOME/.pr-merge-queue/fetch.lock"
mkdir -p "$HOME/.pr-merge-queue"
touch "$STATE"

# ---- blacklist: these repos are never listed, never armed, never merged ----
# Add/remove "owner/repo" entries here (space-separated).
BLACKLIST="swipejobs/fe-customer-desktop-configs-prod swipejobs/fe-service-desktop-configs-prod"

SEARCH_Q="author:@me is:pr is:open"
for r in $BLACKLIST; do SEARCH_Q="$SEARCH_Q -repo:$r"; done

# ---- helpers ---------------------------------------------------------------
is_blacklisted() { local repo="${1%#*}"; case " $BLACKLIST " in *" $repo "*) return 0 ;; *) return 1 ;; esac; }
is_armed() { grep -qxF "$1" "$STATE"; }
arm()      { is_armed "$1" || echo "$1" >> "$STATE"; }
disarm()   { grep -vxF "$1" "$STATE" > "$STATE.tmp" 2>/dev/null; mv "$STATE.tmp" "$STATE"; }
log()      { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

do_merge() {  # args: owner/repo#number, actor(user|engine)
  local key="$1" actor="${2:-engine}" repo num
  if is_blacklisted "$key"; then log "[$actor] BLOCKED merge (blacklist) $key"; return 1; fi
  repo="${key%#*}"; num="${key##*#}"
  if gh pr merge "$num" --repo "$repo" --merge --delete-branch >/dev/null 2>>"$LOG"; then
    log "[$actor] MERGED $key (merge commit + delete branch)"; disarm "$key"; return 0
  fi
  log "[$actor] MERGE FAILED $key"; return 1
}

# Spawn a detached background fetch unless one is already running.
trigger_fetch() {
  if [ -d "$LOCK" ]; then
    local age; age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
    [ "$age" -lt 180 ] && return 0   # a fresh fetch is in flight
    rm -rf "$LOCK"                   # stale lock, clear it
  fi
  nohup "$SELF" fetch >/dev/null 2>&1 &
}

# ---- the heavy lifting: fetch from GitHub, run engine, update cache --------
do_fetch() {
  mkdir "$LOCK" 2>/dev/null || exit 0          # someone else is fetching
  trap 'rm -rf "$LOCK" "$TMP" "$TMP".pg "$TMP".m' EXIT

  TMP="$(mktemp)"; cursor=""; pages=0; EXPECTED=""; echo "[]" > "$TMP"
  while :; do
    pages=$((pages+1)); [ "$pages" -gt 6 ] && break
    if [ -z "$cursor" ]; then AFTER="null"; else AFTER="\"$cursor\""; fi
    resp=$(gh api graphql -f query="
      query {
        search(query: \"$SEARCH_Q\", type: ISSUE, first: 25, after: $AFTER) {
          issueCount
          pageInfo { hasNextPage endCursor }
          nodes { ... on PullRequest {
            number title url isDraft reviewDecision
            repository { nameWithOwner }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          } }
        }
      }" 2>/dev/null)
    echo "$resp" | jq -e '.data.search' >/dev/null 2>&1 || break
    [ -z "$EXPECTED" ] && EXPECTED=$(echo "$resp" | jq -r '.data.search.issueCount')
    echo "$resp" | jq '[.data.search.nodes[] | {
        key: "\(.repository.nameWithOwner)#\(.number)",
        repo: .repository.nameWithOwner, num: .number, title: .title, url: .url,
        isDraft: .isDraft, review: (.reviewDecision // "NONE"),
        checks: (.commits.nodes[0].commit.statusCheckRollup.state // "NONE")
      }]' > "$TMP".pg
    jq -s '.[0] + .[1]' "$TMP" "$TMP".pg > "$TMP".m && mv "$TMP".m "$TMP"
    [ "$(echo "$resp" | jq -r '.data.search.pageInfo.hasNextPage')" = "true" ] || break
    cursor=$(echo "$resp" | jq -r '.data.search.pageInfo.endCursor')
  done

  # Completeness gate: only act + cache on a complete fetch.
  FETCHED=$(jq 'length' "$TMP")
  if [ -z "$EXPECTED" ]; then
    log "[engine] FETCH failed (no GitHub response) — keeping previous snapshot"
    open -g "swiftbar://refreshplugin?name=$PLUGIN_NAME" 2>/dev/null; exit 0
  fi
  if [ "$FETCHED" -lt "$EXPECTED" ]; then
    log "[engine] PARTIAL fetch: got $FETCHED of $EXPECTED — skipping engine, keeping previous snapshot"
    open -g "swiftbar://refreshplugin?name=$PLUGIN_NAME" 2>/dev/null; exit 0
  fi

  # Merge engine: merge every armed PR that is ready (complete data only).
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if is_armed "$key" && do_merge "$key" "engine"; then
      # native SwiftBar notification, clickable to the merged PR
      enc=$(jq -rn --arg s "$key" '$s|@uri')
      url=$(jq -r --arg k "$key" '.[]|select(.key==$k)|.url' "$TMP")
      eurl=$(jq -rn --arg s "$url" '$s|@uri')
      open -g "swiftbar://notify?plugin=$PLUGIN_NAME&title=PR%20auto-merged%20%E2%9C%85&subtitle=$enc&body=merge%20commit%20%2B%20branch%20deleted&href=$eurl&silent=false" 2>/dev/null
    fi
  done < <(jq -r '.[] | select((.isDraft|not) and .review=="APPROVED" and (.checks=="SUCCESS" or .checks=="NONE")) | .key' "$TMP")

  mv "$TMP" "$CACHE"                              # publish fresh snapshot
  open -g "swiftbar://refreshplugin?name=$PLUGIN_NAME" 2>/dev/null   # redraw menu
  exit 0
}

# ---- action dispatch (clicks) ---------------------------------------------
case "$1" in
  toggle) if is_blacklisted "$2"; then log "[user] BLOCKED toggle (blacklist) $2"; exit 0; fi
          if is_armed "$2"; then disarm "$2"; log "[user] DISARM $2"; else arm "$2"; log "[user] ARM $2"; fi
          trigger_fetch; exit 0 ;;
  merge)  do_merge "$2" "user"; trigger_fetch; exit 0 ;;
  arm-all-ready) n=0; while IFS= read -r k; do [ -n "$k" ] && ! is_blacklisted "$k" && arm "$k" && n=$((n+1)); done < <(echo "$3" | tr ' ' '\n'); log "[user] ARM ALL ($n ready)"; trigger_fetch; exit 0 ;;
  disarm-all) : > "$STATE"; log "[user] DISARM ALL"; exit 0 ;;
  openlog) open "$LOG" 2>/dev/null; exit 0 ;;
  refresh) trigger_fetch; exit 0 ;;          # forced fetch (used by "Refresh now")
  fetch)  do_fetch ;;
esac

# ---- default: RENDER instantly from cache; fetch only if cache is stale ----
# (Guard prevents a render->fetch->redraw->render->fetch... hot loop.)
CACHE_AGE=999999
[ -s "$CACHE" ] && CACHE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
[ "$CACHE_AGE" -gt 45 ] && trigger_fetch

if [ ! -s "$CACHE" ]; then
  echo "🔖 …"
  echo "---"
  echo "Loading your PRs… | color=gray"
  echo "Refresh | refresh=true"
  exit 0
fi

AGE=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
if   [ "$AGE" -lt 90 ];   then AGED="${AGE}s ago"
elif [ "$AGE" -lt 3600 ]; then AGED="$((AGE/60))m ago"
else AGED="$((AGE/3600))h ago"; fi

jq -r \
  --rawfile armedraw "$STATE" \
  --arg blacklist "$BLACKLIST" \
  --arg aged "$AGED" \
  --arg self "$SELF" '
  ($armedraw | split("\n") | map(select(length>0))) as $armed |
  ($blacklist | split(" ") | map(select(length>0))) as $black |
  ([.[] | select(.repo as $r | ($black | index($r)) | not)
        | . + {armed: (.key as $k | ($armed | index($k)) != null)}]) as $prs |

  # mutually-exclusive section per PR, in priority order
  def bucket:
    if .isDraft                                              then {o:5, h:"DRAFTS",                 ico:"💤", hcol:"#8e8e93", rcol:"#8e8e93"}
    elif (.review=="APPROVED" and (.checks=="SUCCESS" or .checks=="NONE"))        then {o:0, h:"READY TO MERGE",         ico:"✅", hcol:"#28a745", rcol:"#28a745"}
    elif .armed                                              then {o:1, h:"ARMED · WAITING",        ico:"⚡", hcol:"#d98100", rcol:""}
    elif (.review=="CHANGES_REQUESTED" or .checks=="FAILURE" or .checks=="ERROR")
                                                             then {o:2, h:"NEEDS ATTENTION",        ico:"⚠️", hcol:"#e0245e", rcol:"#e0245e"}
    else                                                          {o:3, h:"WAITING ON REVIEW / CI", ico:"⏳", hcol:"#8e8e93", rcol:""} end;

  ($prs | map(select((.isDraft|not) and .review=="APPROVED" and (.checks=="SUCCESS" or .checks=="NONE")))) as $readyprs |
  ($readyprs | length) as $ready |
  ($readyprs | map(.key) | join(" ")) as $readykeys |
  ([$prs[] | select(.armed)] | length) as $narmed |

  (if $narmed>0 then "🔖 \($prs|length)  ⚡\($narmed)" else "🔖 \($prs|length)" end),
  "---",
  "\($prs|length) open · \($ready) ready · \($narmed) armed · updated \($aged) | size=12 color=#8e8e93",
  "Refresh | bash=\"\($self)\" param1=refresh terminal=false refresh=true",
  "Arm ALL | bash=\"\($self)\" param1=arm-all-ready param2=x param3=\"\($readykeys)\" terminal=false refresh=true",
  "Disarm ALL | bash=\"\($self)\" param1=disarm-all terminal=false refresh=true",
  "Logs | bash=\"\($self)\" param1=openlog terminal=false refresh=false",
  "---",

  ( ( if ($prs|length)==0
    then [ "✨ All caught up — no open PRs | size=13 color=#8e8e93" ]
    else
      ( $prs
        | map(. + {b: bucket})
        | group_by(.b.o)
        | sort_by(.[0].b.o)
        | map(
            (.[0].b) as $b
            | ([ "\($b.ico) \($b.h)  ·  \(length) | size=13 color=\($b.hcol)" ])
            + ( sort_by(.repo, .num)
                | map(
                    (.repo | sub("^[^/]+/";"")) as $short
                    | (.title | gsub("[|\\n]";"/") | if length>42 then .[0:41]+"…" else . end) as $t
                    | (if .armed then "  ⚡" else "" end) as $a
                    | (if .b.rcol=="" then "" else " color=\(.b.rcol)" end) as $c
                    | [ "  \($short)#\(.num)  \($t)\($a) |\($c) bash=\"\($self)\" param1=toggle param2=\"\(.key)\" terminal=false refresh=true",
                        "--\(if .armed then "Disarm" else "Arm" end) | bash=\"\($self)\" param1=toggle param2=\"\(.key)\" terminal=false refresh=true",
                        "--Open in browser | href=\(.url)",
                        "--Merge + Delete | bash=\"\($self)\" param1=merge param2=\"\(.key)\" terminal=false refresh=true color=#2da44e",
                        "--review: \(.review) · checks: \(.checks) | size=11 color=#8e8e93" ]
                  )
                | add // []
              )
          )
        | add // []
      )
    end ) | .[] )
' "$CACHE"
