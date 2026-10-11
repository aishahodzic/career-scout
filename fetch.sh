#!/bin/bash
set -uo pipefail
APP_ID="${1:-}"
API_BASE_URL="${API_BASE_URL:-http://localhost:8000}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOG_DIR="${APP_JOB_STATE_DIR:-/data/cron-logs}"
LOG_FILE="$LOG_DIR/career-scout.log"
TIMEOUT="${CAREER_SCOUT_TIMEOUT:-900}"
WORK=$(mktemp -d -t career-scout.XXXXXX)
REQUEST_TRACK=""
REQUEST_FINISHED=0
cleanup(){
  local rc=$?
  if [ -n "${REQUEST_TRACK:-}" ] && [ "${REQUEST_FINISHED:-0}" -ne 1 ] && declare -F fail_request >/dev/null; then
    fail_request "Scout stopped before completion"
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
mkdir -p "$LOG_DIR"
log(){ printf '[%s] career-scout: %s\n' "$(date -Iseconds)" "$*" >>"$LOG_FILE"; }
case "$APP_ID" in ''|*[!0-9]*) echo 'career-scout: numeric app id required' >&2; exit 2;; esac
AUTH_TOKEN="${APP_TOKEN:-}"
unset APP_TOKEN
if [ -z "$AUTH_TOKEN" ]; then log 'missing supervised app token'; exit 3; fi
get_file(){ curl -sS -o "$2" -w '%{http_code}' -H "Authorization: Bearer $AUTH_TOKEN" "$API_BASE_URL$1"; }
put_json(){ curl -sS -o /dev/null -w '%{http_code}' -X PUT "$API_BASE_URL$1" -H "Authorization: Bearer $AUTH_TOKEN" -H 'Content-Type: application/json' --data-binary "@$2"; }
PROFILE="$WORK/profile.json"
PROFILE_CODE=$(get_file "/api/storage/apps/$APP_ID/profile.json" "$PROFILE") || PROFILE_CODE=000
SKILLS_MAP="$WORK/skills-map.json"
MAP_CODE=$(get_file "/api/storage/apps/$APP_ID/skills-map.json" "$SKILLS_MAP") || MAP_CODE=000
[ "$MAP_CODE" = 200 ] || printf '{}\n' >"$SKILLS_MAP"
COMPANY_UNIVERSE="$WORK/company-universe.json"
UNIVERSE_CODE=$(get_file "/api/storage/apps/$APP_ID/company-universe.json" "$COMPANY_UNIVERSE") || UNIVERSE_CODE=000
[ "$UNIVERSE_CODE" = 200 ] || printf '{"groups":[]}\n' >"$COMPANY_UNIVERSE"
if [ "$PROFILE_CODE" != 200 ]; then printf '{}\n' >"$PROFILE"; fi
if ! python3 - "$PROFILE" "$SKILLS_MAP" <<'PY'
import json,sys
try:
    p=json.load(open(sys.argv[1])); m=json.load(open(sys.argv[2]))
    ready = bool(str(p.get('targetRoles','')).strip() or m.get('positioning'))
    raise SystemExit(0 if ready else 1)
except Exception: raise SystemExit(1)
PY
then
  log 'profile not ready; weekly scout skipped'
  exit 0
fi
REACTIONS="$WORK/reactions.json"
REACTIONS_CODE=$(get_file "/api/storage/apps/$APP_ID/reactions.json" "$REACTIONS") || REACTIONS_CODE=000
[ "$REACTIONS_CODE" = 200 ] || printf '{}\n' >"$REACTIONS"
SCOUT_REQUEST="$WORK/scout-request.json"
REQUEST_CODE=$(get_file "/api/storage/apps/$APP_ID/scout-request.json" "$SCOUT_REQUEST") || REQUEST_CODE=000
if [ "$REQUEST_CODE" = 200 ]; then
  REQUEST_TRACK=$(python3 - "$SCOUT_REQUEST" <<'INNERPY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    track=d.get('track') if d.get('status')=='requested' else ''
    allowed=('job','jobs','internship','apprenticeship','contract','freelance','fellowship','fellowships','phd','phds','volunteer','other','all')
    print(track if track in allowed else '')
except Exception: print('')
INNERPY
)
fi
fail_request(){
  [ -n "$REQUEST_TRACK" ] || return 0
  local reason="${1:-Scout failed}"
  local failed="$WORK/scout-request-failed.json"
  python3 - "$failed" "$REQUEST_TRACK" "$reason" "$SCOUT_REQUEST" <<'INNERPY'
import json,sys
from datetime import datetime,timezone
try: requested=json.load(open(sys.argv[4])).get('requestedAt')
except Exception: requested=None
out={'track':sys.argv[2],'status':'failed','failedAt':datetime.now(timezone.utc).isoformat(),'reason':sys.argv[3][:240]}
if requested: out['requestedAt']=requested
json.dump(out,open(sys.argv[1],'w'))
INNERPY
  put_json "/api/storage/apps/$APP_ID/scout-request.json" "$failed" >/dev/null || true
  REQUEST_FINISHED=1
}
# The platform owns the user-configurable weekly schedule. A direct in-app run
# carries REQUEST_TRACK; a scheduled run has no track and refreshes everything.
if [ -n "$REQUEST_TRACK" ]; then
  RUNNING="$WORK/scout-request-running.json"
  python3 - "$SCOUT_REQUEST" "$RUNNING" "$REQUEST_TRACK" <<'INNERPY'
import json,sys
from datetime import datetime,timezone
try: requested=json.load(open(sys.argv[1])).get('requestedAt')
except Exception: requested=None
out={'track':sys.argv[3],'status':'running','startedAt':datetime.now(timezone.utc).isoformat()}
if requested: out['requestedAt']=requested
json.dump(out,open(sys.argv[2],'w'))
INNERPY
  put_json "/api/storage/apps/$APP_ID/scout-request.json" "$RUNNING" >/dev/null || true
fi
PIPELINE="$WORK/current-pipeline.json"
PIPE_CODE=$(get_file "/api/storage/apps/$APP_ID/pipeline.json" "$PIPELINE") || PIPE_CODE=000
[ "$PIPE_CODE" = 200 ] || printf '{"applyNow":[],"reachOut":[],"experiments":[],"questions":[]}\n' >"$PIPELINE"
if [ "${CAREER_SCOUT_DRY:-0}" = 1 ]; then
  python3 - "$PROFILE" "$REACTIONS" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); r=json.load(open(sys.argv[2]))
print(json.dumps({'dry_run':True,'target_roles':p.get('targetRoles',''),'reaction_count':len(r),'would_notify':False},ensure_ascii=False))
PY
  log 'dry run complete; no research, writes, or notification performed'
  exit 0
fi
CONTEXT="$WORK/job-context.json"
CONTEXT_CODE=$(get_file "/api/apps/$APP_ID/job-context" "$CONTEXT") || CONTEXT_CODE=000
if [ "$CONTEXT_CODE" != 200 ]; then log "job context unavailable ($CONTEXT_CODE)"; fail_request "Job context unavailable"; exit 4; fi
CHOICE=$(python3 - "$CONTEXT" <<'PY'
import json,sys
try: c=json.load(open(sys.argv[1])).get('primary') or {}
except Exception: c={}
p=c.get('provider') if c.get('provider') in ('claude','codex') else 'codex'
m=c.get('model') if isinstance(c.get('model'),str) else ''
e=c.get('effort') if isinstance(c.get('effort'),str) else ''
print('\t'.join((p,m,e)))
PY
)
IFS=$'\t' read -r PROVIDER MODEL EFFORT <<<"$CHOICE"
PROMPT="$WORK/prompt.md"
{
  cat "$SCRIPT_DIR/system-prompt.md"
  printf '\n\n## Run date\n\n%s\n\n## Confirmed profile\n\n```json\n' "$(date -u +%F)"
  cat "$PROFILE"
  printf '\n```\n\n## Confirmed skills and positioning map\n\n```json\n'
  cat "$SKILLS_MAP"
  printf '\n```\n\n## Personal company and organisation universe\n\n```json\n'
  cat "$COMPANY_UNIVERSE"
  printf '\n```\n\n## Explicit reactions to earlier leads\n\n```json\n'
  cat "$REACTIONS"
  printf '\n```\n\n## Current pipeline (retain relevant cards and append genuinely new verified matches)\n\n```json\n'
  cat "$PIPELINE"
  printf '\n```\n'
  if [ -n "$REQUEST_TRACK" ]; then
    printf '\n## Immediate Matches request\n\nThe partner clicked “find more” for: **%s**. Research that track now. Return a complete pipeline JSON which keeps viable current cards and appends new, direct-source-verified matches in that track. Do not merely describe results.\n' "$REQUEST_TRACK"
  else
    printf '\n## Scheduled weekly scout\n\nResearch and return this week’s complete Career Scout JSON.\n'
  fi
} >"$PROMPT"
RAW="$WORK/raw.txt"
ACTIVE_PROVIDER="$PROVIDER"
if [ "$PROVIDER" = claude ]; then
  FLAGS=(--system-prompt-file "$PROMPT" --allowedTools 'WebSearch,WebFetch' --max-turns 30)
  [ -z "$MODEL" ] || FLAGS+=(--model "$MODEL")
  [ -z "$EFFORT" ] || FLAGS+=(--effort "$EFFORT")
  timeout "$TIMEOUT" env CLAUDE_CONFIG_DIR=/data/cli-auth/claude claude -p 'Return the complete, verified Career Scout JSON now.' "${FLAGS[@]}" >"$RAW" 2>>"$LOG_FILE"
  CLI_EXIT=$?
  if [ "$CLI_EXIT" -ne 0 ]; then
    log "primary agent failed ($CLI_EXIT); retrying with Codex fallback"
    ACTIVE_PROVIDER="codex"
    MODEL=""; EFFORT=""
  fi
fi
if [ "$ACTIVE_PROVIDER" = codex ]; then
  FLAGS=(exec --json --sandbox read-only)
  [ -z "$MODEL" ] || FLAGS+=(--model "$MODEL")
  case "$EFFORT" in none|minimal|low|medium|high|xhigh) FLAGS+=(-c "model_reasoning_effort=\"$EFFORT\"");; esac
  FLAGS+=(-)
  { cat "$PROMPT"; printf '\n\nReturn the complete, verified Career Scout JSON now.\n'; } | timeout "$TIMEOUT" env CODEX_HOME=/data/cli-auth/codex codex "${FLAGS[@]}" >"$RAW" 2>>"$LOG_FILE"
  CLI_EXIT=$?
fi
if [ "$CLI_EXIT" -ne 0 ]; then log "agent failed ($CLI_EXIT)"; fail_request "Research agent failed"; exit "$CLI_EXIT"; fi
REPORT="$WORK/report.json"
if ! python3 "$SCRIPT_DIR/extract_report.py" "$RAW" "$ACTIVE_PROVIDER" "$REPORT" >>"$LOG_FILE" 2>&1; then log 'agent output did not contain a usable report'; fail_request 'Agent output could not be processed'; exit 6; fi
python3 - "$PIPELINE" "$REPORT" <<'INNERPY'
import json,sys
try:
    old=json.load(open(sys.argv[1])); new=json.load(open(sys.argv[2]))
    for section in ('applyNow','reachOut'):
        known={x.get('id') for x in old.get(section,[]) if x.get('id')}
        for item in new.get(section,[]):
            item['isNew']=bool(item.get('id') and item.get('id') not in known)
    with open(sys.argv[2],'w') as f: json.dump(new,f,ensure_ascii=False)
except Exception:
    pass
INNERPY
UPDATED_UNIVERSE="$WORK/updated-company-universe.json"
python3 - "$COMPANY_UNIVERSE" "$REPORT" "$UPDATED_UNIVERSE" <<'INNERPY'
import json,sys
from datetime import datetime,timezone
try: universe=json.load(open(sys.argv[1]))
except Exception: universe={'groups':[]}
report=json.load(open(sys.argv[2]))
groups=universe.get('groups') if isinstance(universe.get('groups'),list) else []
known={str(c.get('name')) for g in groups if isinstance(g,dict) for c in g.get('companies',[]) if isinstance(c,dict) and c.get('name')}
found=[]
for item in [*report.get('applyNow',[]),*report.get('reachOut',[])]:
    name=str(item.get('company') or '').strip()
    if not name or name in known: continue
    category=str(item.get('companyCategory') or '').strip()
    if not category or category.lower() in {'from your latest scout','latest scout','new finds','new companies'}:
        continue
    known.add(name)
    found.append((category,{'name':name,'url':item.get('url') or '','whyFit':item.get('whyFit') or ''}))
for category,company in found:
    group=next((g for g in groups if str(g.get('label') or '').strip().lower()==category.lower()),None)
    if group is None:
        group={'label':category,'companies':[]}
        groups.append(group)
    group.setdefault('companies',[]).append(company)
universe['groups']=groups
universe['updatedAt']=report.get('generatedAt') or datetime.now(timezone.utc).isoformat()
json.dump(universe,open(sys.argv[3],'w'),ensure_ascii=False)
INNERPY
PIPE_CODE=$(put_json "/api/storage/apps/$APP_ID/pipeline.json" "$REPORT") || PIPE_CODE=000
WEEK_CODE=$(put_json "/api/storage/apps/$APP_ID/weekly/latest.json" "$REPORT") || WEEK_CODE=000
UNIVERSE_WRITE_CODE=$(put_json "/api/storage/apps/$APP_ID/company-universe.json" "$UPDATED_UNIVERSE") || UNIVERSE_WRITE_CODE=000
if [[ ! "$PIPE_CODE" =~ ^20[014]$ ]] || [[ ! "$WEEK_CODE" =~ ^20[014]$ ]] || [[ ! "$UNIVERSE_WRITE_CODE" =~ ^20[014]$ ]]; then log "storage write failed (pipeline=$PIPE_CODE weekly=$WEEK_CODE universe=$UNIVERSE_WRITE_CODE)"; fail_request "Could not save results"; exit 7; fi
if [ -n "$REQUEST_TRACK" ]; then
  DONE="$WORK/scout-request-complete.json"
  python3 - "$DONE" "$REQUEST_TRACK" "$SCOUT_REQUEST" <<'INNERPY'
import json,sys
from datetime import datetime,timezone
try: requested=json.load(open(sys.argv[3])).get('requestedAt')
except Exception: requested=None
out={'track':sys.argv[2],'status':'completed','completedAt':datetime.now(timezone.utc).isoformat()}
if requested: out['requestedAt']=requested
json.dump(out,open(sys.argv[1],'w'))
INNERPY
  put_json "/api/storage/apps/$APP_ID/scout-request.json" "$DONE" >/dev/null || true
  REQUEST_FINISHED=1
fi
read -r APPLY REACH < <(python3 - "$REPORT" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); print(len(d.get('applyNow',[])),len(d.get('reachOut',[])))
PY
)
INSTANCE=$(python3 - "$CONTEXT" <<'PY'
import json,sys
try: print(json.load(open(sys.argv[1])).get('app_instance_id') or '')
except Exception: print('')
PY
)
if [ -n "$INSTANCE" ]; then
  SIGNAL="$WORK/signal.json"
  python3 - "$SIGNAL" "$INSTANCE" "$APPLY" "$REACH" <<'PY'
import json,sys,uuid
from datetime import datetime,timezone
out,instance,a,r=sys.argv[1:]
with open(out,'w') as f: json.dump({'signals':[{'id':'career-weekly-'+uuid.uuid4().hex,'app_instance_id':instance,'occurred_at':datetime.now(timezone.utc).isoformat(),'name':'cron_summary','payload':{'status':'ok','open_roles':int(a),'outreach_leads':int(r)}}]},f)
PY
  curl -sS -o /dev/null -X POST "$API_BASE_URL/api/client-signal" -H "Authorization: Bearer $AUTH_TOKEN" -H 'Content-Type: application/json' --data-binary "@$SIGNAL" || true
fi
NOTIFY="$WORK/notification.json"
NOTIFY_KIND=$(python3 - "$REPORT" "$NOTIFY" "$APP_ID" "$REQUEST_TRACK" <<'PY'
import json,sys
report_path,out_path,app_id,request_track=sys.argv[1:]
d=json.load(open(report_path))
strong=[x for x in d.get('applyNow',[]) if x.get('isNew') and int(x.get('fitScore') or 0)>=85]
payload=None
if strong:
    strong.sort(key=lambda x:int(x.get('fitScore') or 0),reverse=True)
    best=strong[0]; title=str(best.get('title') or 'New opportunity'); company=str(best.get('company') or '')
    lead=f"{title} at {company}" if company else title
    body=f"{lead} · {int(best.get('fitScore') or 0)}% match"
    if len(strong)>1: body=f"{len(strong)} strong new matches, led by {body}"
    payload={'title':'Great new Career Scout match','body':body,'source_type':'app','source_id':app_id,'target':f'/shell/?app={app_id}&intent=matches','tag':'career-scout-strong-match','actions':[{'action':'open_app','title':'Review','target':f'/shell/?app={app_id}&intent=matches'}]}
    kind='strong-match'
elif not request_track:
    apply_count=len(d.get('applyNow',[])); reach_count=len(d.get('reachOut',[]))
    payload={'title':'Career Scout weekly update','body':f'{apply_count} open roles and {reach_count} outreach leads matched this week.','source_type':'app','source_id':app_id,'target':f'/shell/?app={app_id}&intent=matches','tag':'career-scout-weekly','actions':[{'action':'open_app','title':'Review','target':f'/shell/?app={app_id}&intent=matches'}]}
    kind='weekly'
else:
    kind=''
if payload:
    with open(out_path,'w') as f: json.dump(payload,f,ensure_ascii=False)
print(kind)
PY
)
if [ -n "$NOTIFY_KIND" ]; then
  NOTIFY_CODE=$(curl -sS -o "$WORK/notification-response.json" -w '%{http_code}' -X POST "$API_BASE_URL/api/notifications/send" -H "Authorization: Bearer $AUTH_TOKEN" -H 'Content-Type: application/json' --data-binary "@$NOTIFY") || NOTIFY_CODE=000
  if [[ "$NOTIFY_CODE" =~ ^20[0124]$ ]]; then
    log "$NOTIFY_KIND notification sent"
  else
    log "$NOTIFY_KIND notification failed (http=$NOTIFY_CODE)"
  fi
fi
log "weekly update saved (open=$APPLY reach=$REACH)"
