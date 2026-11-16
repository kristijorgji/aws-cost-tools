#!/usr/bin/env bash
#
# aws-cost-snapshot.sh — read-only AWS spend snapshot
#
# Usage (from repo root):
#   AWS_PROFILE=<cost-analysis-iam-user> bash scripts/aws-cost-snapshot.sh
#   AWS_PROFILE=<cost-analysis-iam-user> bash scripts/aws-cost-snapshot.sh --from-dir tmp/aws-cost/<stamp>
#   AWS_PROFILE=<cost-analysis-iam-user> bash scripts/aws-cost-snapshot.sh --region eu-central-1
#   AWS_PROFILE=<cost-analysis-iam-user> bash scripts/aws-cost-snapshot.sh --phase 2 --confirm-phase
#
# Requires: aws CLI, jq, AWS_PROFILE set to the cost-analysis IAM user name
#           (aws CLI only if a JSON file is missing).
# Output:   tmp/aws-cost/<UTC timestamp>/   (gitignored), or --from-dir
#
# Each new Cost Explorer API request costs $0.01. Phase 1 makes 8 of them unless the
# output JSON already exists (then that call is skipped and not billed).
# Phase 2 and Phase 3 do not run unless --confirm-phase is set.
# The script never opts in to Compute Optimizer or Cost Optimization Hub,
# never activates cost allocation tags, and never deletes or resizes anything.

set -euo pipefail

PROFILE="${AWS_PROFILE:-}"
PHASE="1"
CONFIRM=0
ONLY_REGION=""
FROM_DIR=""

PHASE1_JSON=(
  monthly-by-service.json
  monthly-by-region.json
  monthly-by-record-type.json
  monthly-by-service-usage-type.json
  daily-by-service.json
  anomalies.json
  cost-allocation-tags-Active.json
  cost-allocation-tags-Inactive.json
)

usage() {
  cat <<'EOF'
Usage: AWS_PROFILE=<cost-analysis-iam-user> bash scripts/aws-cost-snapshot.sh [options]

  AWS_PROFILE must match the IAM user name. The script checks that
  sts get-caller-identity is user/<AWS_PROFILE>.

  --from-dir DIR    Reuse JSON in DIR. Skip Cost Explorer for files that already exist.
                    When all phase 1 JSON files are present, no AWS calls are made.
  --region REGION   Limit inventory and Cost Explorer to one enabled region.
                    Default: every enabled region, and Cost Explorer with no region filter.
  --phase 1|2|3     1 = spend (default). 2 = rightsizing. 3 = idle resources.
  --confirm-phase   Required for phase 2 and phase 3.

Each new Cost Explorer request costs $0.01. A skipped file is not billed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      ONLY_REGION="${2:-}"
      if [[ -z "$ONLY_REGION" ]]; then
        echo "Missing value for --region" >&2
        exit 1
      fi
      shift 2
      ;;
    --phase)
      PHASE="${2:-}"
      shift 2
      ;;
    --confirm-phase)
      CONFIRM=1
      shift
      ;;
    --from-dir)
      FROM_DIR="${2:-}"
      if [[ -z "$FROM_DIR" ]]; then
        echo "Missing value for --from-dir" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$PHASE" in
  1|2|3) ;;
  *)
    echo "Phase must be 1, 2, or 3 (got: ${PHASE})" >&2
    exit 1
    ;;
esac

if [[ "$PHASE" != "1" && "$CONFIRM" -ne 1 ]]; then
  echo "Phase ${PHASE} reads more of the account than the bill." >&2
  echo "Re-run with --confirm-phase after you have read the phase 1 summary." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Missing required command: jq" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -n "$FROM_DIR" ]]; then
  if [[ ! -d "$FROM_DIR" ]]; then
    echo "--from-dir is not a directory: ${FROM_DIR}" >&2
    exit 1
  fi
  OUT="$(cd "$FROM_DIR" && pwd)"
else
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  OUT="${REPO_ROOT}/tmp/aws-cost/${STAMP}"
  mkdir -p "$OUT"
fi

phase1_json_missing() {
  local f
  for f in "${PHASE1_JSON[@]}"; do
    if [[ ! -s "${OUT}/${f}" ]]; then
      return 0
    fi
  done
  return 1
}

NEED_AWS=0
if [[ "$PHASE" != "1" ]]; then
  NEED_AWS=1
elif phase1_json_missing; then
  NEED_AWS=1
fi

if [[ "$NEED_AWS" -eq 1 && -z "$PROFILE" ]]; then
  echo "Refusing to run: AWS_PROFILE must be set to the cost-analysis IAM user name." >&2
  echo "Other profiles in ~/.aws are left untouched. This script will not use them." >&2
  exit 1
fi

# Environment keys override --profile. Drop them in this process only.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE || true
if [[ -n "$PROFILE" ]]; then
  export AWS_PROFILE="$PROFILE"
fi

aws_json() {
  aws "$@" --profile "$PROFILE" --output json
}

bsd_date() {
  date -u -v-1d +%Y-%m-%d >/dev/null 2>&1
}

if bsd_date; then
  DATE_TODAY="$(date -u +%Y-%m-%d)"
  DATE_END="$(date -u -v+1d +%Y-%m-%d)"
  DATE_START_30="$(date -u -v-30d +%Y-%m-%d)"
  DATE_START_6="$(date -u -v-6m +%Y-%m-01)"
  CW_START="$(date -u -v-14d +%Y-%m-%dT%H:%M:%SZ)"
else
  DATE_TODAY="$(date -u +%Y-%m-%d)"
  DATE_END="$(date -u -d 'tomorrow' +%Y-%m-%d)"
  DATE_START_30="$(date -u -d '30 days ago' +%Y-%m-%d)"
  DATE_START_6="$(date -u -d '6 months ago' +%Y-%m-01)"
  CW_START="$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)"
fi
CW_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CALLER_ARN="user/${PROFILE:-unset}"
SELECTED_REGIONS=()

enabled_regions() {
  aws ec2 describe-regions \
    --profile "$PROFILE" \
    --region us-east-1 \
    --query 'Regions[].RegionName' \
    --output text | tr '\t' '\n' | sed '/^$/d' | sort
}

if [[ "$NEED_AWS" -eq 1 ]]; then
  if ! command -v aws >/dev/null 2>&1; then
    echo "Missing required command: aws" >&2
    exit 1
  fi
  CALLER_ARN="$(aws sts get-caller-identity --profile "$PROFILE" --query Arn --output text)"
  case "$CALLER_ARN" in
    *:user/"${PROFILE}") ;;
    *)
      echo "Refusing to run: caller is ${CALLER_ARN}, expected user/${PROFILE}." >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$CALLER_ARN" > "${OUT}/caller-arn.txt"

  if [[ "$PHASE" != "1" || -z "$FROM_DIR" ]]; then
    if [[ -n "$ONLY_REGION" ]]; then
      if ! enabled_regions | grep -Fxq "$ONLY_REGION"; then
        echo "Region ${ONLY_REGION} is not an enabled region in this account." >&2
        exit 1
      fi
      SELECTED_REGIONS=("$ONLY_REGION")
    else
      while IFS= read -r region; do
        [[ -z "$region" ]] && continue
        SELECTED_REGIONS+=("$region")
      done < <(enabled_regions)
    fi
    if [[ ${#SELECTED_REGIONS[@]} -eq 0 ]]; then
      echo "No enabled regions returned." >&2
      exit 1
    fi
    printf '%s\n' "${SELECTED_REGIONS[@]}" > "${OUT}/enabled-regions.txt"
  fi
fi

CE_FILTER=()
if [[ -n "$ONLY_REGION" ]]; then
  CE_FILTER=(--filter "{\"Dimensions\":{\"Key\":\"REGION\",\"Values\":[\"${ONLY_REGION}\"]}}")
  echo "Cost Explorer is filtered to ${ONLY_REGION}. Charges tagged global (often CloudFront) are excluded."
fi

CE_CALLS=0

trim_cost() {
  jq '{
    ResultsByTime: [
      (.ResultsByTime // [])[] | {
        TimePeriod: .TimePeriod,
        Total: (.Total.UnblendedCost.Amount // "0"),
        Groups: [
          (.Groups // [])[] | {
            Keys: .Keys,
            Amount: .Metrics.UnblendedCost.Amount,
            Unit: .Metrics.UnblendedCost.Unit
          }
        ]
      }
    ]
  }'
}

run_ce() {
  local name="$1"
  shift
  if [[ -s "${OUT}/${name}.json" ]]; then
    echo "skip (exists): ${name}"
    return 0
  fi
  CE_CALLS=$((CE_CALLS + 1))
  echo "Cost Explorer request ${CE_CALLS}: ${name}"
  # ${CE_FILTER[@]+...} is safe on bash 3.2 when the array is empty and set -u is on.
  aws ce "$@" \
    --profile "$PROFILE" \
    --region us-east-1 \
    --output json \
    ${CE_FILTER[@]+"${CE_FILTER[@]}"} \
    | trim_cost > "${OUT}/${name}.json"
}

top_groups() {
  local file="$1"
  local idx="$2"
  jq -r --argjson idx "$idx" '
    [ .ResultsByTime[]?.Groups[]? ]
    | group_by(.Keys[$idx])
    | map({name: .[0].Keys[$idx], amount: (map(.Amount | tonumber) | add)})
    | sort_by(-.amount)
    | .[:10][]
    | "\((.amount * 100 | round) / 100)\t\(.name)"
  ' "$file"
}

table_from_groups() {
  local file="$1"
  local idx="$2"
  jq -r --argjson idx "$idx" '
    def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
    [ .ResultsByTime[]?.Groups[]? ]
    | group_by(.Keys[$idx])
    | map({name: .[0].Keys[$idx], amount: (map(.Amount | tonumber) | add)})
    | sort_by(-.amount)
    | .[:10]
    | if length == 0 then "<tr><td colspan=\"2\">none</td></tr>"
      else
        map("<tr><td>\(.name | tostring | esc)</td><td class=\"num\">\((.amount * 100 | round) / 100)</td></tr>")
        | join("\n")
      end
  ' "$file"
}

write_report() {
  local services regions records ipv4 anomalies tags_rows usd
  services="$(table_from_groups "${OUT}/monthly-by-service.json" 0)"
  regions="$(table_from_groups "${OUT}/monthly-by-region.json" 0)"
  records="$(table_from_groups "${OUT}/monthly-by-record-type.json" 0)"
  ipv4="$(jq -r '
    def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
    [ .ResultsByTime[]?.Groups[]? | select((.Keys[1] // "") | test("PublicIPv4")) ]
    | group_by(.Keys[1])
    | map({name: .[0].Keys[1], amount: (map(.Amount | tonumber) | add)})
    | sort_by(-.amount)
    | if length == 0 then "<tr><td colspan=\"2\">none</td></tr>"
      else
        map("<tr><td>\(.name | tostring | esc)</td><td class=\"num\">\((.amount * 100 | round) / 100)</td></tr>")
        | join("\n")
      end
  ' "${OUT}/monthly-by-service-usage-type.json")"
  anomalies="$(jq -r '
    def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
    (.Anomalies // [])
    | if length == 0 then "<tr><td colspan=\"4\">none</td></tr>"
      else
        map("<tr><td>\(.id | tostring | esc)</td><td>\(.start // "")</td><td>\(.end // "")</td><td class=\"num\">\(.totalImpact // 0)</td></tr>")
        | join("\n")
      end
  ' "${OUT}/anomalies.json")"
  tags_rows=""
  local key found
  for key in Project Parent Environment Owner; do
    found="$(jq -r --arg k "$key" '
      [ .CostAllocationTags[]? | select(.TagKey == $k) ] | if length > 0 then "active" else "inactive" end
    ' "${OUT}/cost-allocation-tags-Active.json")"
    tags_rows+="<tr><td>${key}</td><td>${found}</td></tr>"
  done
  usd="$(awk -v n="$CE_CALLS" 'BEGIN { printf "%.2f", n * 0.01 }')"
  cat > "${OUT}/report.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>AWS cost snapshot</title>
<style>
body { font-family: sans-serif; margin: 1.5rem; color: #111; }
table { border-collapse: collapse; margin: 0 0 1.5rem; }
th, td { border: 1px solid #ccc; padding: 0.35rem 0.6rem; text-align: left; }
th { background: #f3f3f3; }
td.num { text-align: right; font-variant-numeric: tabular-nums; }
.meta { margin-bottom: 1.5rem; }
</style>
</head>
<body>
<h1>AWS cost snapshot</h1>
<div class="meta">
<p>Period start (monthly): ${DATE_START_6}. Daily start: ${DATE_START_30}. End exclusive: ${DATE_END}.</p>
<p>Region scope: ${ONLY_REGION:-all}. Cost Explorer requests this run: ${CE_CALLS} (about \$${usd}).</p>
<p>Skipped files are not billed. Amounts are UnblendedCost USD.</p>
</div>
<h2>Top services</h2>
<table><thead><tr><th>Service</th><th>USD</th></tr></thead><tbody>
${services}
</tbody></table>
<h2>Top regions</h2>
<table><thead><tr><th>Region</th><th>USD</th></tr></thead><tbody>
${regions}
</tbody></table>
<h2>Public IPv4 usage types</h2>
<table><thead><tr><th>Usage type</th><th>USD</th></tr></thead><tbody>
${ipv4}
</tbody></table>
<h2>Record types</h2>
<table><thead><tr><th>Type</th><th>USD</th></tr></thead><tbody>
${records}
</tbody></table>
<h2>Anomalies</h2>
<table><thead><tr><th>Id</th><th>Start</th><th>End</th><th>Impact</th></tr></thead><tbody>
${anomalies}
</tbody></table>
<h2>Cost allocation tags</h2>
<table><thead><tr><th>Key</th><th>Status</th></tr></thead><tbody>
${tags_rows}
</tbody></table>
</body>
</html>
EOF
}

phase1() {
  run_ce monthly-by-service \
    get-cost-and-usage \
    --time-period "Start=${DATE_START_6},End=${DATE_END}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE

  run_ce monthly-by-region \
    get-cost-and-usage \
    --time-period "Start=${DATE_START_6},End=${DATE_END}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=REGION

  run_ce monthly-by-record-type \
    get-cost-and-usage \
    --time-period "Start=${DATE_START_6},End=${DATE_END}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=RECORD_TYPE

  run_ce monthly-by-service-usage-type \
    get-cost-and-usage \
    --time-period "Start=${DATE_START_6},End=${DATE_END}" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE Type=DIMENSION,Key=USAGE_TYPE

  run_ce daily-by-service \
    get-cost-and-usage \
    --time-period "Start=${DATE_START_30},End=${DATE_END}" \
    --granularity DAILY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE

  if [[ -s "${OUT}/anomalies.json" ]]; then
    echo "skip (exists): anomalies"
  else
    CE_CALLS=$((CE_CALLS + 1))
    echo "Cost Explorer request ${CE_CALLS}: anomalies"
    aws_json ce get-anomalies \
      --region us-east-1 \
      --date-interval "StartDate=${DATE_START_30},EndDate=${DATE_TODAY}" \
      | jq '{
          Anomalies: [
            (.Anomalies // [])[] | {
              id: .AnomalyId,
              start: .AnomalyStartDate,
              end: .AnomalyEndDate,
              score: .AnomalyScore.CurrentScore,
              totalImpact: .Impact.TotalImpact,
              dimension: .DimensionValue,
              services: [(.RootCauses // [])[] | .Service]
            }
          ]
        }' > "${OUT}/anomalies.json"
  fi

  local status
  for status in Active Inactive; do
    if [[ -s "${OUT}/cost-allocation-tags-${status}.json" ]]; then
      echo "skip (exists): cost-allocation-tags-${status}"
      continue
    fi
    CE_CALLS=$((CE_CALLS + 1))
    echo "Cost Explorer request ${CE_CALLS}: cost-allocation-tags-${status}"
    aws_json ce list-cost-allocation-tags \
      --region us-east-1 \
      --status "$status" \
      | jq '{
          CostAllocationTags: [
            (.CostAllocationTags // [])[] | {TagKey, Status, Type}
          ]
        }' > "${OUT}/cost-allocation-tags-${status}.json"
  done

  {
    echo "caller=${CALLER_ARN}"
    echo "monthly_start=${DATE_START_6}"
    echo "daily_start=${DATE_START_30}"
    echo "period_end_exclusive=${DATE_END}"
    echo "current_month_is_partial=yes"
    echo "cost_explorer_endpoint=us-east-1"
    if [[ -n "$ONLY_REGION" ]]; then
      echo "region_scope=${ONLY_REGION}"
      echo "global_charges=excluded"
    else
      echo "region_scope=all"
      echo "global_charges=included"
    fi
    echo "cost_explorer_requests=${CE_CALLS}"
    awk -v n="$CE_CALLS" 'BEGIN { printf "estimated_cost_explorer_usd=%.2f\n", n * 0.01 }'
    echo "output=${OUT}"
  } > "${OUT}/manifest.txt"

  echo
  echo "Top services (UnblendedCost, last 6 months including the partial current month):"
  top_groups "${OUT}/monthly-by-service.json" 0
  echo
  echo "Top regions:"
  top_groups "${OUT}/monthly-by-region.json" 0
  echo
  echo "Public IPv4 usage types:"
  jq -r '
    [ .ResultsByTime[]?.Groups[]? | select((.Keys[1] // "") | test("PublicIPv4")) ]
    | group_by(.Keys[1])
    | map({name: .[0].Keys[1], amount: (map(.Amount | tonumber) | add)})
    | sort_by(-.amount)
    | if length == 0 then
        "none"
      else
        .[] | "\((.amount * 100 | round) / 100)\t\(.name)"
      end
  ' "${OUT}/monthly-by-service-usage-type.json"
  echo
  echo "Cost allocation tags (Project, Parent, Environment, Owner):"
  local key found
  for key in Project Parent Environment Owner; do
    found="$(jq -r --arg k "$key" '
      [ .CostAllocationTags[]? | select(.TagKey == $k) ] | if length > 0 then "active" else "inactive" end
    ' "${OUT}/cost-allocation-tags-Active.json")"
    echo "${key}: ${found}"
  done
  echo
  echo "Cost Explorer requests: ${CE_CALLS} (about \$$(awk -v n="$CE_CALLS" 'BEGIN { printf "%.2f", n * 0.01 }'))."
  echo "JSON: ${OUT}"
  write_report
  echo "HTML: ${OUT}/report.html"
  echo "Phase 2 and phase 3 were not run."
}

record_or_fail() {
  local dest="$1"
  shift
  local err="${dest}.err"
  if "$@" >"$dest" 2>"$err"; then
    rm -f "$err"
    return 0
  fi
  echo "failed ($?): $* (see ${err})" | tee -a "${OUT}/phase-errors.txt" >&2
  return 0
}

phase2() {
  local region status dir hub_filter
  mkdir -p "${OUT}/phase2"
  for region in "${SELECTED_REGIONS[@]}"; do
    dir="${OUT}/phase2/${region}"
    mkdir -p "$dir"
    record_or_fail "${dir}/enrollment.json" \
      aws_json compute-optimizer get-enrollment-status --region "$region"
    status="$(jq -r '.status // "unknown"' "${dir}/enrollment.json" 2>/dev/null || echo unknown)"
    if [[ "$status" != "Active" ]]; then
      echo "${region}: Compute Optimizer status ${status}"
      continue
    fi
    echo "${region}: Compute Optimizer active"
    record_or_fail "${dir}/ec2.json" \
      aws_json compute-optimizer get-ec2-instance-recommendations --region "$region"
    record_or_fail "${dir}/ebs.json" \
      aws_json compute-optimizer get-ebs-volume-recommendations --region "$region"
    record_or_fail "${dir}/idle.json" \
      aws_json compute-optimizer get-idle-recommendations --region "$region"
    record_or_fail "${dir}/rds.json" \
      aws_json compute-optimizer get-rds-database-recommendations --region "$region"
    for name in ec2 ebs idle rds; do
      [[ -s "${dir}/${name}.json" ]] || continue
      jq '
        if .instanceRecommendations then
          {items: [.instanceRecommendations[] | {
            id: .instanceArn, current: .currentInstanceType, finding: .finding,
            recommended: .recommendationOptions[0].instanceType,
            savings: .recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value
          }]}
        elif .volumeRecommendations then
          {items: [.volumeRecommendations[] | {
            id: .volumeArn, current: .currentConfiguration.volumeType, finding: .finding,
            recommended: .volumeRecommendationOptions[0].configuration.volumeType,
            savings: .volumeRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value
          }]}
        elif .idleRecommendations then
          {items: [.idleRecommendations[] | {id: .resourceArn, type: .resourceType, finding: .finding}]}
        elif .rdsDBRecommendations then
          {items: [.rdsDBRecommendations[] | {
            id: .resourceArn, current: .currentDBInstanceClass, finding: .finding,
            savings: .recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value
          }]}
        else {items: []}
        end
      ' "${dir}/${name}.json" > "${dir}/${name}.summary.json" || true
    done
  done

  hub_filter=()
  if [[ -n "$ONLY_REGION" ]]; then
    hub_filter=(--filter "{\"regions\":[\"${ONLY_REGION}\"]}")
  fi
  record_or_fail "${OUT}/phase2/hub-enrollment.json" \
    aws_json cost-optimization-hub list-enrollment-statuses --region us-east-1
  if jq -e '[.items[]? | select(.status == "Active")] | length > 0' "${OUT}/phase2/hub-enrollment.json" >/dev/null 2>&1; then
    record_or_fail "${OUT}/phase2/hub-recommendations.json" \
      aws cost-optimization-hub list-recommendations \
        --region us-east-1 \
        --profile "$PROFILE" \
        --output json \
        ${hub_filter[@]+"${hub_filter[@]}"}
    if [[ -s "${OUT}/phase2/hub-recommendations.json" ]]; then
      jq '{
        items: [(.items // [])[] | {
          action: .actionType,
          resourceType: .currentResourceType,
          resourceId: .resourceId,
          region: .region,
          savings: (.estimatedMonthlySavings.value // .estimatedMonthlySavings)
        }]
      }' "${OUT}/phase2/hub-recommendations.json" > "${OUT}/phase2/hub-recommendations.summary.json" || true
    fi
  else
    echo "Cost Optimization Hub is not enrolled. Recommendations were not requested."
  fi
  echo "Phase 2 JSON: ${OUT}/phase2"
}

flag_age() {
  jq '
    def instant:
      if . == null or . == "" then null
      else (sub("\\.[0-9]+"; "") | fromdateiso8601)
      end;
    (if type == "array" then . else [] end)
    | map(. + {
        ageDays: (try ((now - (.start | instant)) / 86400 | floor) catch null),
        olderThan90Days: (try ((now - (.start | instant)) / 86400 > 90) catch false)
      })
  '
}

phase3_region() {
  local region="$1"
  local dir="${OUT}/phase3/${region}"
  mkdir -p "$dir"

  record_or_fail "${dir}/volumes.json" \
    aws ec2 describe-volumes \
      --region "$region" --profile "$PROFILE" --output json \
      --filters Name=status,Values=available \
      --query 'Volumes[].{id:VolumeId,size:Size,type:VolumeType,created:CreateTime,az:AvailabilityZone}'

  record_or_fail "${dir}/addresses.json" \
    aws ec2 describe-addresses \
      --region "$region" --profile "$PROFILE" --output json \
      --query 'Addresses[].{ip:PublicIp,alloc:AllocationId,assoc:AssociationId,instance:InstanceId,eni:NetworkInterfaceId}'

  record_or_fail "${dir}/snapshots.raw.json" \
    aws ec2 describe-snapshots \
      --region "$region" --profile "$PROFILE" --output json \
      --owner-ids self \
      --query 'Snapshots[].{id:SnapshotId,start:StartTime,vol:VolumeId,size:VolumeSize,desc:Description}'
  if [[ -s "${dir}/snapshots.raw.json" ]]; then
    flag_age < "${dir}/snapshots.raw.json" > "${dir}/snapshots.json" \
      || cp "${dir}/snapshots.raw.json" "${dir}/snapshots.json"
  fi

  record_or_fail "${dir}/nat.json" \
    aws ec2 describe-nat-gateways \
      --region "$region" --profile "$PROFILE" --output json \
      --filter Name=state,Values=available,pending \
      --query 'NatGateways[].{id:NatGatewayId,state:State,vpc:VpcId}'

  record_or_fail "${dir}/elbv2.json" \
    aws elbv2 describe-load-balancers \
      --region "$region" --profile "$PROFILE" --output json \
      --query 'LoadBalancers[].{name:LoadBalancerName,type:Type,scheme:Scheme,arn:LoadBalancerArn}'

  record_or_fail "${dir}/elb-classic.json" \
    aws elb describe-load-balancers \
      --region "$region" --profile "$PROFILE" --output json \
      --query 'LoadBalancerDescriptions[].{name:LoadBalancerName,scheme:Scheme}'

  record_or_fail "${dir}/rds.json" \
    aws rds describe-db-instances \
      --region "$region" --profile "$PROFILE" --output json \
      --query 'DBInstances[].{id:DBInstanceIdentifier,class:DBInstanceClass,engine:Engine,status:DBInstanceStatus}'

  record_or_fail "${dir}/rds-snapshots.raw.json" \
    aws rds describe-db-snapshots \
      --region "$region" --profile "$PROFILE" --output json \
      --snapshot-type manual \
      --query 'DBSnapshots[].{id:DBSnapshotIdentifier,instance:DBInstanceIdentifier,start:SnapshotCreateTime,size:AllocatedStorage}'
  if [[ -s "${dir}/rds-snapshots.raw.json" ]]; then
    flag_age < "${dir}/rds-snapshots.raw.json" > "${dir}/rds-snapshots.json" || cp "${dir}/rds-snapshots.raw.json" "${dir}/rds-snapshots.json"
  fi

  phase3_lb_traffic "$region" "$dir"
}

phase3_lb_traffic() {
  local region="$1"
  local dir="$2"
  local arn name type dim ns metric queries values
  [[ -s "${dir}/elbv2.json" ]] || return 0
  jq -e 'type == "array" and length > 0' "${dir}/elbv2.json" >/dev/null 2>&1 || return 0

  : > "${dir}/lb-traffic.jsonl"
  while IFS= read -r row; do
    arn="$(jq -r '.arn' <<<"$row")"
    name="$(jq -r '.name' <<<"$row")"
    type="$(jq -r '.type' <<<"$row")"
    dim="${arn#*loadbalancer/}"
    case "$type" in
      application) ns="AWS/ApplicationELB"; metric="RequestCount" ;;
      network) ns="AWS/NetworkELB"; metric="ProcessedBytes" ;;
      *)
        jq -nc --arg name "$name" --arg type "$type" '{name:$name,type:$type,note:"no traffic metric"}' >> "${dir}/lb-traffic.jsonl"
        continue
        ;;
    esac
    queries="$(jq -n --arg dim "$dim" --arg ns "$ns" --arg metric "$metric" '[{
      Id: "m1",
      MetricStat: {
        Metric: {
          Namespace: $ns,
          MetricName: $metric,
          Dimensions: [{Name: "LoadBalancer", Value: $dim}]
        },
        Period: 86400,
        Stat: "Sum"
      }
    }]')"
    if values="$(aws cloudwatch get-metric-data \
      --region "$region" --profile "$PROFILE" --output json \
      --start-time "$CW_START" --end-time "$CW_END" \
      --metric-data-queries "$queries" 2>"${dir}/lb-${name}.err")"; then
      rm -f "${dir}/lb-${name}.err"
      echo "$values" | jq -c --arg name "$name" --arg metric "$metric" \
        '{name:$name,metric:$metric,sum:([.MetricDataResults[0].Values[]?] | add // 0)}' \
        >> "${dir}/lb-traffic.jsonl"
    else
      echo "${region} ${name}: cloudwatch failed" >> "${OUT}/phase-errors.txt"
    fi
  done < <(jq -c '.[]' "${dir}/elbv2.json")
}

phase3() {
  local region
  mkdir -p "${OUT}/phase3"
  for region in "${SELECTED_REGIONS[@]}"; do
    echo "Phase 3: ${region}"
    phase3_region "$region"
  done
  echo
  echo "Unassociated addresses (list price about \$0.005 per hour while unattached):"
  for region in "${SELECTED_REGIONS[@]}"; do
    [[ -s "${OUT}/phase3/${region}/addresses.json" ]] || continue
    jq -r --arg region "$region" '
      [(if type == "array" then . else [] end)[] | select(.assoc == null)]
      | length as $n
      | if $n > 0 then "\($region)\t\($n)" else empty end
    ' "${OUT}/phase3/${region}/addresses.json" || echo "${region}: could not read addresses"
  done
  echo "In-use public IPv4 is on the phase 1 usage-type report, not in this idle count."
  echo "Phase 3 JSON: ${OUT}/phase3"
  echo "Snapshots older than 90 days are flagged olderThan90Days. Nothing was deleted."
}

case "$PHASE" in
  1) phase1 ;;
  2) phase2 ;;
  3) phase3 ;;
esac
