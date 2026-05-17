#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common.sh"

require_cmd curl
require_cmd node

DISPATCH_API_TESTS_ENABLED="${DISPATCH_API_TESTS_ENABLED:-true}"
if [[ "${DISPATCH_API_TESTS_ENABLED}" != "true" ]]; then
  echo "[INFO] DISPATCH_API_TESTS_ENABLED=false, skipping dispatch API interface tests."
  exit 0
fi

if [[ -z "${DISPATCH_API_BASE_URL:-}" ]]; then
  load_env dev
  DISPATCH_API_BASE_URL="http://localhost:${NGINX_HOST_PORT}"
fi

DISPATCH_API_BASE_URL="${DISPATCH_API_BASE_URL%/}"
DISPATCH_TEST_LIMIT="${DISPATCH_TEST_LIMIT:-20}"
DISPATCH_TEST_TOKEN_TYPE_FALLBACK="${DISPATCH_TEST_TOKEN_TYPE_FALLBACK:-Bearer}"
API_TEST_REPORT_DIR="${API_TEST_REPORT_DIR:-${ROOT_DIR}/reports/api-interface}"
API_TEST_REPORT_JSON="${API_TEST_REPORT_JSON:-${API_TEST_REPORT_DIR}/results.json}"
API_TEST_REPORT_HTML="${API_TEST_REPORT_HTML:-${API_TEST_REPORT_DIR}/index.html}"
TEST_RESULT_JSONL="$(mktemp)"
TEST_RUN_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
login_response_file=""
workers_response_file=""
assignment_response_file=""
history_response_file=""
probe_order_create_response_file=""

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    echo "[ERROR] Missing required environment variable: ${key}" >&2
    exit 1
  fi
}

cleanup() {
  rm -f "${login_response_file}" "${workers_response_file}" "${assignment_response_file}" "${history_response_file}" "${probe_order_create_response_file}" "${TEST_RESULT_JSONL}"
}

finish() {
  local exit_code="$?"
  set +e
  generate_report "${exit_code}"
  cleanup
  exit "${exit_code}"
}

urlencode() {
  node -e 'process.stdout.write(encodeURIComponent(process.argv[1] || ""))' "$1"
}

now_ms() {
  node -e 'process.stdout.write(String(Date.now()))'
}

json_eval() {
  local response_file="$1"
  local script="$2"

  node -e '
const fs = require("fs");
const responseFile = process.argv[1];
const script = process.argv[2];
const data = JSON.parse(fs.readFileSync(responseFile, "utf8"));
const result = Function("data", script)(data);
if (result !== undefined && result !== null) {
  process.stdout.write(String(result));
}
' "${response_file}" "${script}"
}

record_result() {
  local name="$1"
  local method="$2"
  local url="$3"
  local code="$4"
  local result="$5"
  local duration_ms="$6"
  local category="$7"

  node -e '
const fs = require("fs");
const [file, name, method, url, code, result, durationMs, category] = process.argv.slice(1);
fs.appendFileSync(file, JSON.stringify({
  name,
  method,
  url,
  status_code: code,
  result,
  duration_ms: Number(durationMs),
  category,
  timestamp: new Date().toISOString()
}) + "\n");
' "${TEST_RESULT_JSONL}" "${name}" "${method}" "${url}" "${code}" "${result}" "${duration_ms}" "${category}"
}

generate_report() {
  local exit_code="$1"

  mkdir -p "${API_TEST_REPORT_DIR}"
  node -e '
const fs = require("fs");
const path = require("path");

const [jsonlFile, jsonFile, htmlFile, baseUrl, startedAt, exitCodeText] = process.argv.slice(1);
const exitCode = Number(exitCodeText || 0);
const rows = fs.existsSync(jsonlFile)
  ? fs.readFileSync(jsonlFile, "utf8").split(/\n/).filter(Boolean).map((line) => JSON.parse(line))
  : [];
const finishedAt = new Date().toISOString();
const counts = rows.reduce((acc, row) => {
  acc.total += 1;
  acc[row.result] = (acc[row.result] || 0) + 1;
  return acc;
}, { total: 0 });
const avgDuration = rows.length
  ? Math.round(rows.reduce((sum, row) => sum + Number(row.duration_ms || 0), 0) / rows.length)
  : 0;
const report = {
  name: "HSP API Interface Report",
  base_url: baseUrl,
  started_at: startedAt,
  finished_at: finishedAt,
  exit_code: exitCode,
  summary: {
    total: counts.total,
    passed: counts.PASS || 0,
    failed: counts.FAIL || 0,
    recorded: counts.RECORDED || 0,
    average_duration_ms: avgDuration
  },
  results: rows
};
fs.writeFileSync(jsonFile, JSON.stringify(report, null, 2));

const escapeHtml = (value) => String(value ?? "")
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll("\"", "&quot;")
  .replaceAll(String.fromCharCode(39), "&#39;");
const displayUrl = (value) => {
  try {
    const parsed = new URL(value);
    return `${parsed.pathname}${parsed.search}`;
  } catch {
    return value;
  }
};
const statusClass = (code) => {
  const n = Number(code);
  if (n >= 200 && n < 300) return "ok";
  if (n >= 300 && n < 400) return "redirect";
  if (n >= 400 && n < 500) return "warn";
  if (n >= 500 || code === "000") return "bad";
  return "muted";
};
const resultClass = (result) => {
  if (result === "PASS") return "pass";
  if (result === "FAIL") return "fail";
  return "recorded";
};
const methodClass = (method) => `method method-${String(method).toLowerCase()}`;
const cards = [
  ["Total", counts.total, "Requests"],
  ["Passed", counts.PASS || 0, "Core checks"],
  ["Recorded", counts.RECORDED || 0, "Interface calls"],
  ["Avg", `${avgDuration}ms`, "Latency"]
].map(([label, value, hint]) => `
  <section class="metric">
    <span>${escapeHtml(label)}</span>
    <strong>${escapeHtml(value)}</strong>
    <small>${escapeHtml(hint)}</small>
  </section>`).join("");
const tableRows = rows.map((row, index) => `
  <tr>
    <td class="index">${index + 1}</td>
    <td><span class="${methodClass(row.method)}">${escapeHtml(row.method)}</span></td>
    <td>
      <div class="endpoint">${escapeHtml(row.name)}</div>
      <div class="url">${escapeHtml(displayUrl(row.url))}</div>
    </td>
    <td><span class="pill ${statusClass(row.status_code)}">${escapeHtml(row.status_code)}</span></td>
    <td><span class="pill ${resultClass(row.result)}">${escapeHtml(row.result)}</span></td>
    <td class="duration">${escapeHtml(row.duration_ms)}ms</td>
  </tr>`).join("");
const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>HSP API Interface Report</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #17202a;
      --muted: #617084;
      --line: #dde5ee;
      --panel: #ffffff;
      --bg: #f5f7fb;
      --ok: #13795b;
      --ok-bg: #dff7ed;
      --warn: #9a6700;
      --warn-bg: #fff1c2;
      --bad: #b42318;
      --bad-bg: #ffe4df;
      --blue: #155eef;
      --blue-bg: #e6efff;
      --slate-bg: #eef2f7;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--ink);
    }
    header {
      background: linear-gradient(135deg, #123c69 0%, #1f7a8c 58%, #46a758 100%);
      color: white;
      padding: 36px 42px 76px;
    }
    .hero {
      max-width: 1180px;
      margin: 0 auto;
      display: flex;
      align-items: flex-end;
      justify-content: space-between;
      gap: 28px;
    }
    h1 {
      margin: 0 0 10px;
      font-size: 34px;
      line-height: 1.1;
      letter-spacing: 0;
    }
    .subtitle {
      margin: 0;
      color: rgba(255,255,255,.82);
      font-size: 15px;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      height: 34px;
      padding: 0 14px;
      border-radius: 999px;
      background: rgba(255,255,255,.16);
      border: 1px solid rgba(255,255,255,.28);
      color: white;
      font-weight: 700;
      white-space: nowrap;
    }
    main {
      max-width: 1180px;
      margin: -48px auto 42px;
      padding: 0 24px;
    }
    .metrics {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 14px;
      margin-bottom: 18px;
    }
    .metric, .table-wrap, .meta {
      background: var(--panel);
      border: 1px solid var(--line);
      box-shadow: 0 18px 48px rgba(22, 34, 51, .08);
    }
    .metric {
      min-height: 112px;
      border-radius: 8px;
      padding: 18px;
    }
    .metric span, .metric small {
      display: block;
      color: var(--muted);
      font-size: 13px;
      font-weight: 700;
    }
    .metric strong {
      display: block;
      margin: 8px 0 4px;
      font-size: 30px;
      line-height: 1;
    }
    .meta {
      border-radius: 8px;
      margin-bottom: 18px;
      padding: 16px 18px;
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px 20px;
      color: var(--muted);
      font-size: 13px;
    }
    .meta strong { color: var(--ink); }
    .table-wrap {
      border-radius: 8px;
      overflow: hidden;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }
    th {
      background: #f8fafc;
      color: var(--muted);
      text-align: left;
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: .04em;
      padding: 13px 14px;
      border-bottom: 1px solid var(--line);
    }
    td {
      padding: 14px;
      border-bottom: 1px solid var(--line);
      vertical-align: middle;
      font-size: 14px;
    }
    tr:last-child td { border-bottom: 0; }
    .index { width: 48px; color: var(--muted); font-variant-numeric: tabular-nums; }
    .endpoint {
      font-weight: 750;
      margin-bottom: 4px;
    }
    .url {
      color: var(--muted);
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
      font-size: 12px;
      overflow-wrap: anywhere;
    }
    .method, .pill {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 68px;
      height: 28px;
      padding: 0 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 800;
      font-variant-numeric: tabular-nums;
    }
    .method-get { color: #155eef; background: #e6efff; }
    .method-post { color: #13795b; background: #dff7ed; }
    .method-patch { color: #9a6700; background: #fff1c2; }
    .ok, .pass { color: var(--ok); background: var(--ok-bg); }
    .warn, .redirect { color: var(--warn); background: var(--warn-bg); }
    .bad, .fail { color: var(--bad); background: var(--bad-bg); }
    .recorded, .muted { color: #465668; background: var(--slate-bg); }
    .duration {
      color: var(--muted);
      font-variant-numeric: tabular-nums;
      text-align: right;
    }
    @media (max-width: 860px) {
      header { padding: 28px 20px 66px; }
      .hero { display: block; }
      .badge { margin-top: 18px; }
      main { padding: 0 14px; }
      .metrics, .meta { grid-template-columns: 1fr 1fr; }
      table { min-width: 820px; }
      .table-wrap { overflow-x: auto; }
    }
  </style>
</head>
<body>
  <header>
    <div class="hero">
      <div>
        <h1>HSP API Interface Report</h1>
        <p class="subtitle">${escapeHtml(baseUrl)} · ${escapeHtml(startedAt)} to ${escapeHtml(finishedAt)}</p>
      </div>
      <div class="badge">${exitCode === 0 ? "Pipeline Gate Passed" : "Pipeline Gate Failed"}</div>
    </div>
  </header>
  <main>
    <section class="metrics">${cards}</section>
    <section class="meta">
      <div>Base URL: <strong>${escapeHtml(baseUrl)}</strong></div>
      <div>Exit Code: <strong>${escapeHtml(exitCode)}</strong></div>
      <div>Started: <strong>${escapeHtml(startedAt)}</strong></div>
      <div>Finished: <strong>${escapeHtml(finishedAt)}</strong></div>
    </section>
    <section class="table-wrap">
      <table>
        <thead>
          <tr>
            <th style="width: 56px;">#</th>
            <th style="width: 100px;">Method</th>
            <th>Endpoint</th>
            <th style="width: 110px;">HTTP</th>
            <th style="width: 120px;">Result</th>
            <th style="width: 110px; text-align: right;">Time</th>
          </tr>
        </thead>
        <tbody>${tableRows || `<tr><td colspan="6">No requests recorded.</td></tr>`}</tbody>
      </table>
    </section>
  </main>
</body>
</html>`;
fs.mkdirSync(path.dirname(htmlFile), { recursive: true });
fs.writeFileSync(htmlFile, html);
' "${TEST_RESULT_JSONL}" "${API_TEST_REPORT_JSON}" "${API_TEST_REPORT_HTML}" "${DISPATCH_API_BASE_URL}" "${TEST_RUN_STARTED_AT}" "${exit_code}"

  echo "[INFO] API interface report written to ${API_TEST_REPORT_HTML}"
}

trap finish EXIT

append_query_param() {
  local url="$1"
  local key="$2"
  local value="$3"

  if [[ -z "${value}" ]]; then
    printf '%s' "${url}"
    return
  fi

  local sep="?"
  if [[ "${url}" == *"?"* ]]; then
    sep="&"
  fi

  printf '%s%s%s=%s' "${url}" "${sep}" "${key}" "$(urlencode "${value}")"
}

request_expect_2xx() {
  local name="$1"
  local method="$2"
  local url="$3"
  local response_file="$4"
  local payload="${5:-}"
  local token="${6:-}"

  local curl_args=(-sS --connect-timeout 5 --max-time 30 -o "${response_file}" -w '%{http_code}' -X "${method}")

  if [[ -n "${token}" ]]; then
    curl_args+=(-H "Authorization: ${token}")
  fi

  if [[ -n "${payload}" ]]; then
    curl_args+=(-H 'Content-Type: application/json' --data "${payload}")
  fi

  local start_ms end_ms duration_ms code
  start_ms="$(now_ms)"
  code="$(curl "${curl_args[@]}" "${url}" || true)"
  end_ms="$(now_ms)"
  duration_ms=$((end_ms - start_ms))

  if [[ "${code}" =~ ^2[0-9][0-9]$ ]]; then
    record_result "${name}" "${method}" "${url}" "${code}" "PASS" "${duration_ms}" "Core"
    echo "[PASS] ${name} succeeded (HTTP ${code})"
    return 0
  fi

  record_result "${name}" "${method}" "${url}" "${code}" "FAIL" "${duration_ms}" "Core"
  echo "[FAIL] ${name} failed (HTTP ${code})" >&2
  echo "[DEBUG] ${name} response body:" >&2
  cat "${response_file}" >&2 || true
  return 1
}

request_probe() {
  local name="$1"
  local method="$2"
  local url="$3"
  local payload="${4:-}"
  local token="${5:-}"
  local response_file="${6:-}"

  local temp_response_file=""
  if [[ -z "${response_file}" ]]; then
    temp_response_file="$(mktemp)"
    response_file="${temp_response_file}"
  fi

  local curl_args=(-sS --connect-timeout 5 --max-time 30 -o "${response_file}" -w '%{http_code}' -X "${method}")

  if [[ -n "${token}" ]]; then
    curl_args+=(-H "Authorization: ${token}")
  fi

  if [[ -n "${payload}" ]]; then
    curl_args+=(-H 'Content-Type: application/json' --data "${payload}")
  fi

  local start_ms end_ms duration_ms code
  start_ms="$(now_ms)"
  code="$(curl "${curl_args[@]}" "${url}" 2>/dev/null || true)"
  end_ms="$(now_ms)"
  duration_ms=$((end_ms - start_ms))
  if [[ -z "${code}" ]]; then
    code="000"
  fi

  record_result "${name}" "${method}" "${url}" "${code}" "RECORDED" "${duration_ms}" "Interface"
  echo "[INFO] ${name} requested (HTTP ${code})"

  if [[ -n "${temp_response_file}" ]]; then
    rm -f "${temp_response_file}"
  fi

  return 0
}

assert_json() {
  local name="$1"
  local response_file="$2"
  local script="$3"

  if node -e '
const fs = require("fs");
const responseFile = process.argv[1];
const script = process.argv[2];
const data = JSON.parse(fs.readFileSync(responseFile, "utf8"));
const result = Function("data", script)(data);
if (!result) {
  process.exit(1);
}
' "${response_file}" "${script}"; then
    return 0
  fi

  echo "[FAIL] ${name}: response shape mismatch" >&2
  cat "${response_file}" >&2 || true
  return 1
}

require_env DISPATCH_TEST_EMAIL
require_env DISPATCH_TEST_PASSWORD
require_env DISPATCH_TEST_ORDER_ID

if ! [[ "${DISPATCH_TEST_LIMIT}" =~ ^[0-9]+$ ]] || (( DISPATCH_TEST_LIMIT < 1 || DISPATCH_TEST_LIMIT > 200 )); then
  echo "[ERROR] DISPATCH_TEST_LIMIT must be an integer in range 1-200." >&2
  exit 1
fi

login_response_file="$(mktemp)"
workers_response_file="$(mktemp)"
assignment_response_file="$(mktemp)"
history_response_file="$(mktemp)"
probe_order_create_response_file="$(mktemp)"

echo "[INFO] Running dispatch API interface tests against ${DISPATCH_API_BASE_URL}"

login_payload="$(node -e 'process.stdout.write(JSON.stringify({email: process.env.DISPATCH_TEST_EMAIL, password: process.env.DISPATCH_TEST_PASSWORD}))')"

request_expect_2xx \
  "Login" \
  "POST" \
  "${DISPATCH_API_BASE_URL}/api/users/v1/auth/login" \
  "${login_response_file}" \
  "${login_payload}"

assert_json "Login" "${login_response_file}" '
const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const isString = (value) => typeof value === "string";
const isNumber = (value) => typeof value === "number" && Number.isFinite(value);
const profile = data.user && data.user.worker_profile;
return isString(data.access_token) && data.access_token.length > 0
  && (data.token_type === null || isString(data.token_type))
  && (data.expires_in === null || isNumber(data.expires_in))
  && (data.user === null || (
    isObject(data.user)
    && isNumber(data.user.id)
    && isString(data.user.email)
    && isString(data.user.role)
    && isString(data.user.status)
    && isString(data.user.created_at)
    && isString(data.user.updated_at)
    && (data.user.last_login_at === null || isString(data.user.last_login_at))
    && (profile === null || (
      isObject(profile)
      && isNumber(profile.id)
      && isNumber(profile.user_id)
      && isString(profile.worker_no)
      && isString(profile.display_name)
      && isString(profile.employment_status)
      && isString(profile.created_at)
      && isString(profile.updated_at)
    ))
  ));
'

access_token="$(json_eval "${login_response_file}" 'return data.access_token || "";')"
token_type="$(json_eval "${login_response_file}" 'return data.token_type || process.env.DISPATCH_TEST_TOKEN_TYPE_FALLBACK || "Bearer";')"
auth_header="${token_type} ${access_token}"

workers_url="${DISPATCH_API_BASE_URL}/api/dispatch/v1/workers/available"
workers_url="$(append_query_param "${workers_url}" "service_type" "${DISPATCH_TEST_SERVICE_TYPE:-}")"
workers_url="$(append_query_param "${workers_url}" "region" "${DISPATCH_TEST_REGION:-}")"
workers_url="$(append_query_param "${workers_url}" "at_time" "${DISPATCH_TEST_AT_TIME:-}")"
workers_url="$(append_query_param "${workers_url}" "limit" "${DISPATCH_TEST_LIMIT}")"

request_expect_2xx \
  "List available workers" \
  "GET" \
  "${workers_url}" \
  "${workers_response_file}" \
  "" \
  "${auth_header}"

assert_json "List available workers" "${workers_response_file}" '
const isString = (value) => typeof value === "string";
return Array.isArray(data.workers)
  && data.workers.every((worker) =>
    (worker.worker_id === null || isString(worker.worker_id))
    && (worker.name === null || isString(worker.name))
    && Array.isArray(worker.skills)
    && worker.skills.every(isString)
    && (worker.status === null || isString(worker.status))
  );
'

worker_id="${DISPATCH_TEST_WORKER_ID:-}"
if [[ -z "${worker_id}" ]]; then
  worker_id="$(json_eval "${workers_response_file}" '
const worker = Array.isArray(data.workers)
  ? data.workers.find((item) => typeof item.worker_id === "string" && item.worker_id.length > 0)
  : null;
return worker ? worker.worker_id : "";
')"
fi

if [[ -z "${worker_id}" ]]; then
  echo "[FAIL] List available workers returned no usable worker_id. Set DISPATCH_TEST_WORKER_ID to test a fixed worker." >&2
  cat "${workers_response_file}" >&2 || true
  exit 1
fi
export DISPATCH_SELECTED_WORKER_ID="${worker_id}"

assignment_payload="$(node -e 'process.stdout.write(JSON.stringify({order_id: process.env.DISPATCH_TEST_ORDER_ID, worker_id: process.env.DISPATCH_SELECTED_WORKER_ID}))')"

request_expect_2xx \
  "Manual assignment" \
  "POST" \
  "${DISPATCH_API_BASE_URL}/api/dispatch/v1/assignments/manual" \
  "${assignment_response_file}" \
  "${assignment_payload}" \
  "${auth_header}"

assert_json "Manual assignment" "${assignment_response_file}" '
const isString = (value) => typeof value === "string";
const isNumber = (value) => typeof value === "number" && Number.isFinite(value);
const dispatch = data.dispatch;
return dispatch !== null && typeof dispatch === "object" && !Array.isArray(dispatch)
  && (dispatch.dispatch_id === null || isString(dispatch.dispatch_id))
  && dispatch.order_id === process.env.DISPATCH_TEST_ORDER_ID
  && (dispatch.attempt_no === null || isNumber(dispatch.attempt_no))
  && dispatch.worker_id === process.env.DISPATCH_SELECTED_WORKER_ID
  && (dispatch.operator_id === null || isString(dispatch.operator_id))
  && (dispatch.status === null || isString(dispatch.status))
  && (dispatch.assigned_at === null || isString(dispatch.assigned_at))
  && (dispatch.responded_at === null || isString(dispatch.responded_at))
  && (dispatch.reject_reason === null || isString(dispatch.reject_reason));
'

dispatch_id="$(json_eval "${assignment_response_file}" 'return data.dispatch && data.dispatch.dispatch_id ? data.dispatch.dispatch_id : "";')"

history_order_id="$(urlencode "${DISPATCH_TEST_ORDER_ID}")"
request_expect_2xx \
  "Order dispatch history" \
  "GET" \
  "${DISPATCH_API_BASE_URL}/api/dispatch/v1/orders/${history_order_id}/history" \
  "${history_response_file}" \
  "" \
  "${auth_header}"

assert_json "Order dispatch history" "${history_response_file}" '
const isString = (value) => typeof value === "string";
const isNumber = (value) => typeof value === "number" && Number.isFinite(value);
return Array.isArray(data.dispatches)
  && data.dispatches.every((dispatch) =>
    (dispatch.dispatch_id === null || isString(dispatch.dispatch_id))
    && (dispatch.order_id === null || isString(dispatch.order_id))
    && (dispatch.attempt_no === null || isNumber(dispatch.attempt_no))
    && (dispatch.worker_id === null || isString(dispatch.worker_id))
    && (dispatch.operator_id === null || isString(dispatch.operator_id))
    && (dispatch.status === null || isString(dispatch.status))
    && (dispatch.assigned_at === null || isString(dispatch.assigned_at))
    && (dispatch.responded_at === null || isString(dispatch.responded_at))
    && (dispatch.reject_reason === null || isString(dispatch.reject_reason))
  )
  && data.dispatches.some((dispatch) =>
    dispatch.order_id === process.env.DISPATCH_TEST_ORDER_ID
    && dispatch.worker_id === process.env.DISPATCH_SELECTED_WORKER_ID
  );
'

run_additional_api_requests() {
  local now_tag
  now_tag="$(date +%Y%m%d%H%M%S)"

  local register_email="${API_PROBE_REGISTER_EMAIL:-probe-${now_tag}@hsp.local}"
  local register_password="${API_PROBE_REGISTER_PASSWORD:-Probe111111}"
  local register_role="${API_PROBE_REGISTER_ROLE:-CUSTOMER_SERVICE}"
  local register_worker_display_name="${API_PROBE_REGISTER_WORKER_DISPLAY_NAME:-}"
  local register_payload
  register_payload="$(API_PROBE_REGISTER_EMAIL="${register_email}" \
    API_PROBE_REGISTER_PASSWORD="${register_password}" \
    API_PROBE_REGISTER_ROLE="${register_role}" \
    API_PROBE_REGISTER_WORKER_DISPLAY_NAME="${register_worker_display_name}" \
    node -e 'process.stdout.write(JSON.stringify({
      email: process.env.API_PROBE_REGISTER_EMAIL,
      password: process.env.API_PROBE_REGISTER_PASSWORD,
      role: process.env.API_PROBE_REGISTER_ROLE,
      worker_display_name: process.env.API_PROBE_REGISTER_WORKER_DISPLAY_NAME || ""
    }))')"

  request_probe \
    "Register user" \
    "POST" \
    "${DISPATCH_API_BASE_URL}/api/users/v1/auth/register" \
    "${register_payload}"

  request_probe \
    "Current user profile" \
    "GET" \
    "${DISPATCH_API_BASE_URL}/api/users/v1/profile" \
    "" \
    "${auth_header}"

  request_probe \
    "Admin ping" \
    "GET" \
    "${DISPATCH_API_BASE_URL}/api/users/v1/admin/ping" \
    "" \
    "${auth_header}"

  request_probe \
    "User dispatch trigger" \
    "POST" \
    "${DISPATCH_API_BASE_URL}/api/users/v1/orders/dispatch" \
    "{}" \
    "${auth_header}"

  local order_customer_name="${API_PROBE_ORDER_CUSTOMER_NAME:-Probe Customer ${now_tag}}"
  local order_phone="${API_PROBE_ORDER_PHONE:-13800000000}"
  local order_service_address="${API_PROBE_ORDER_SERVICE_ADDRESS:-Probe Address}"
  local order_service_type="${API_PROBE_ORDER_SERVICE_TYPE:-CLEANING}"
  local order_appointment_time="${API_PROBE_ORDER_APPOINTMENT_TIME:-2026-04-07T10:00:00+08:00}"
  local order_estimated_duration="${API_PROBE_ORDER_ESTIMATED_DURATION_MINUTES:-60}"
  local order_payload
  order_payload="$(API_PROBE_ORDER_CUSTOMER_NAME="${order_customer_name}" \
    API_PROBE_ORDER_PHONE="${order_phone}" \
    API_PROBE_ORDER_SERVICE_ADDRESS="${order_service_address}" \
    API_PROBE_ORDER_SERVICE_TYPE="${order_service_type}" \
    API_PROBE_ORDER_APPOINTMENT_TIME="${order_appointment_time}" \
    API_PROBE_ORDER_ESTIMATED_DURATION_MINUTES="${order_estimated_duration}" \
    node -e 'process.stdout.write(JSON.stringify({
      customer_name: process.env.API_PROBE_ORDER_CUSTOMER_NAME,
      phone: process.env.API_PROBE_ORDER_PHONE,
      service_address: process.env.API_PROBE_ORDER_SERVICE_ADDRESS,
      service_type: process.env.API_PROBE_ORDER_SERVICE_TYPE,
      appointment_time: process.env.API_PROBE_ORDER_APPOINTMENT_TIME,
      estimated_duration_minutes: Number(process.env.API_PROBE_ORDER_ESTIMATED_DURATION_MINUTES || 60)
    }))')"

  request_probe \
    "Create order" \
    "POST" \
    "${DISPATCH_API_BASE_URL}/api/orders/v1/orders" \
    "${order_payload}" \
    "${auth_header}" \
    "${probe_order_create_response_file}"

  local probe_order_id="${API_PROBE_ORDER_ID:-}"
  if [[ -z "${probe_order_id}" ]]; then
    probe_order_id="$(json_eval "${probe_order_create_response_file}" '
const candidates = [
  data.order_id,
  data.id,
  data.order && data.order.order_id,
  data.order && data.order.id
].filter((value) => typeof value === "string" && value.length > 0);
return candidates[0] || "";
' 2>/dev/null || true)"
  fi
  if [[ -z "${probe_order_id}" ]]; then
    probe_order_id="${DISPATCH_TEST_ORDER_ID}"
  fi

  local encoded_probe_order_id
  encoded_probe_order_id="$(urlencode "${probe_order_id}")"

  request_probe \
    "Get order" \
    "GET" \
    "${DISPATCH_API_BASE_URL}/api/orders/v1/orders/${encoded_probe_order_id}" \
    "" \
    "${auth_header}"

  local list_orders_url="${DISPATCH_API_BASE_URL}/api/orders/v1/orders"
  list_orders_url="$(append_query_param "${list_orders_url}" "customer_name" "${API_PROBE_ORDER_QUERY_CUSTOMER_NAME:-}")"
  list_orders_url="$(append_query_param "${list_orders_url}" "service_type" "${API_PROBE_ORDER_QUERY_SERVICE_TYPE:-}")"
  list_orders_url="$(append_query_param "${list_orders_url}" "status" "${API_PROBE_ORDER_QUERY_STATUS:-}")"
  list_orders_url="$(append_query_param "${list_orders_url}" "page" "${API_PROBE_ORDER_QUERY_PAGE:-1}")"
  list_orders_url="$(append_query_param "${list_orders_url}" "page_size" "${API_PROBE_ORDER_QUERY_PAGE_SIZE:-20}")"

  request_probe \
    "List orders" \
    "GET" \
    "${list_orders_url}" \
    "" \
    "${auth_header}"

  local order_status_payload
  order_status_payload="$(API_PROBE_ORDER_TARGET_STATUS="${API_PROBE_ORDER_TARGET_STATUS:-PENDING}" \
    API_PROBE_ORDER_ASSIGNED_WORKER_ID="${API_PROBE_ORDER_ASSIGNED_WORKER_ID:-${worker_id}}" \
    node -e 'process.stdout.write(JSON.stringify({
      target_status: process.env.API_PROBE_ORDER_TARGET_STATUS,
      assigned_worker_id: process.env.API_PROBE_ORDER_ASSIGNED_WORKER_ID || null
    }))')"

  request_probe \
    "Patch order status" \
    "PATCH" \
    "${DISPATCH_API_BASE_URL}/api/orders/v1/orders/${encoded_probe_order_id}/status" \
    "${order_status_payload}" \
    "${auth_header}"

  request_probe \
    "Worker pending dispatches" \
    "GET" \
    "${DISPATCH_API_BASE_URL}/api/dispatch/v1/worker/pending-dispatches" \
    "" \
    "${auth_header}"

  local probe_dispatch_id="${API_PROBE_DISPATCH_ID:-${dispatch_id}}"
  if [[ -z "${probe_dispatch_id}" ]]; then
    probe_dispatch_id="dispatch-${now_tag}"
  fi
  local encoded_probe_dispatch_id
  encoded_probe_dispatch_id="$(urlencode "${probe_dispatch_id}")"

  local dispatch_confirm_payload
  dispatch_confirm_payload="$(API_PROBE_WORKER_RESPONSE="${API_PROBE_WORKER_RESPONSE:-ACCEPT}" \
    API_PROBE_REJECT_REASON="${API_PROBE_REJECT_REASON:-}" \
    node -e 'process.stdout.write(JSON.stringify({
      response: process.env.API_PROBE_WORKER_RESPONSE,
      reject_reason: process.env.API_PROBE_REJECT_REASON || null
    }))')"

  request_probe \
    "Confirm dispatch" \
    "POST" \
    "${DISPATCH_API_BASE_URL}/api/dispatch/v1/dispatches/${encoded_probe_dispatch_id}/confirm" \
    "${dispatch_confirm_payload}" \
    "${auth_header}"

  local schedule_worker_id="${API_PROBE_WORKER_ID:-${worker_id}}"
  local schedule_worker_name="${API_PROBE_WORKER_NAME:-Probe Worker}"
  local worker_register_payload
  worker_register_payload="$(API_PROBE_WORKER_ID="${schedule_worker_id}" \
    API_PROBE_WORKER_NAME="${schedule_worker_name}" \
    node -e 'process.stdout.write(JSON.stringify({
      worker_id: process.env.API_PROBE_WORKER_ID,
      worker_name: process.env.API_PROBE_WORKER_NAME
    }))')"

  request_probe \
    "Register schedule worker" \
    "POST" \
    "${DISPATCH_API_BASE_URL}/api/worker-schedule/v1/workers/register" \
    "${worker_register_payload}" \
    "${auth_header}"

  request_probe \
    "List schedule workers" \
    "GET" \
    "${DISPATCH_API_BASE_URL}/api/worker-schedule/v1/workers" \
    "" \
    "${auth_header}"

  local encoded_schedule_worker_id
  encoded_schedule_worker_id="$(urlencode "${schedule_worker_id}")"
  local worker_status_payload
  worker_status_payload="$(API_PROBE_WORKER_STATUS="${API_PROBE_WORKER_STATUS:-AVAILABLE}" \
    node -e 'process.stdout.write(JSON.stringify({status: process.env.API_PROBE_WORKER_STATUS}))')"

  request_probe \
    "Patch schedule worker status" \
    "PATCH" \
    "${DISPATCH_API_BASE_URL}/api/worker-schedule/v1/workers/${encoded_schedule_worker_id}/status" \
    "${worker_status_payload}" \
    "${auth_header}"

  local order_event_payload
  order_event_payload="$(API_PROBE_ORDER_ID_FOR_EVENT="${probe_order_id}" \
    API_PROBE_WORKER_ID_FOR_EVENT="${schedule_worker_id}" \
    API_PROBE_WORKER_NAME_FOR_EVENT="${schedule_worker_name}" \
    API_PROBE_ORDER_EVENT_TYPE="${API_PROBE_ORDER_EVENT_TYPE:-ASSIGNED}" \
    API_PROBE_ORDER_EVENT_START_TIME="${API_PROBE_ORDER_EVENT_START_TIME:-}" \
    API_PROBE_ORDER_EVENT_END_TIME="${API_PROBE_ORDER_EVENT_END_TIME:-}" \
    API_PROBE_ORDER_EVENT_TITLE="${API_PROBE_ORDER_EVENT_TITLE:-}" \
    node -e 'process.stdout.write(JSON.stringify({
      order_id: process.env.API_PROBE_ORDER_ID_FOR_EVENT,
      worker_id: process.env.API_PROBE_WORKER_ID_FOR_EVENT,
      worker_name: process.env.API_PROBE_WORKER_NAME_FOR_EVENT,
      event_type: process.env.API_PROBE_ORDER_EVENT_TYPE,
      start_time: process.env.API_PROBE_ORDER_EVENT_START_TIME || "",
      end_time: process.env.API_PROBE_ORDER_EVENT_END_TIME || "",
      title: process.env.API_PROBE_ORDER_EVENT_TITLE || ""
    }))')"

  request_probe \
    "Sync order event" \
    "POST" \
    "${DISPATCH_API_BASE_URL}/api/worker-schedule/v1/orders/sync-event" \
    "${order_event_payload}" \
    "${auth_header}"

  local schedule_daily_url="${DISPATCH_API_BASE_URL}/api/worker-schedule/v1/schedule/daily"
  schedule_daily_url="$(append_query_param "${schedule_daily_url}" "date" "${API_PROBE_SCHEDULE_DATE:-2026-04-07}")"

  request_probe \
    "Daily schedule" \
    "GET" \
    "${schedule_daily_url}" \
    "" \
    "${auth_header}"

  request_probe \
    "Get schedule order" \
    "GET" \
    "${DISPATCH_API_BASE_URL}/api/worker-schedule/v1/orders/${encoded_probe_order_id}" \
    "" \
    "${auth_header}"

  local invoice_id="${API_PROBE_INVOICE_ID:-invoice-${now_tag}}"
  local encoded_invoice_id
  encoded_invoice_id="$(urlencode "${invoice_id}")"

  request_probe \
    "Get invoice" \
    "GET" \
    "${DISPATCH_API_BASE_URL}/api/finance/v1/invoices/${encoded_invoice_id}" \
    "" \
    "${auth_header}"
}

run_additional_api_requests

echo "[INFO] Dispatch API interface tests completed."
