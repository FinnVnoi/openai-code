#!/usr/bin/env bash
set -Eeuo pipefail

step() {
  printf '\033[36m==> %s\033[0m\n' "$*"
}

warn() {
  printf '\033[33m%s\033[0m\n' "$*"
}

die() {
  printf '\033[31merror: %s\033[0m\n' "$*" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_base_url() {
  local url
  url="$(trim "$1")"
  url="${url%/}"
  if [[ -n "$url" && "$url" != */v1 ]]; then
    url="$url/v1"
  fi
  printf '%s' "$url"
}

mask_value() {
  local value="$1"
  local len="${#value}"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    printf '(empty)'
  elif (( len <= 8 )); then
    printf '%*s' "$len" '' | tr ' ' '*'
  else
    printf '%s...%s' "${value:0:4}" "${value: -4}"
  fi
}

prompt_value_or_keep() {
  local label="$1"
  local current="$2"
  local suffix=""
  local value=""
  if [[ -n "${current//[[:space:]]/}" ]]; then
    suffix=" [$current]"
  fi
  read -r -p "$label$suffix (Enter = keep): " value
  printf '%s' "$(trim "$value")"
}

prompt_secret_or_keep() {
  local label="$1"
  local current_mask="$2"
  local value=""
  read -r -s -p "$label [$current_mask] (Enter = keep): " value
  printf '\n' >&2
  printf '%s' "$value"
}

prompt_choice() {
  local label="$1"
  local default="$2"
  shift 2
  local allowed=("$@")
  local allowed_text
  local value
  local item
  allowed_text="$(IFS=/; printf '%s' "${allowed[*]}")"
  while true; do
    read -r -p "$label [$default] ($allowed_text): " value
    if [[ -z "${value//[[:space:]]/}" ]]; then
      printf '%s' "$default"
      return
    fi
    value="$(trim "${value,,}")"
    for item in "${allowed[@]}"; do
      if [[ "$value" == "$item" ]]; then
        printf '%s' "$item"
        return
      fi
    done
    warn "Choose one of: $allowed_text"
  done
}

parse_models_csv() {
  local value="$1"
  local part
  IFS=',' read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    part="$(trim "$part")"
    [[ -n "$part" ]] && printf '%s\n' "$part"
  done
}

append_unique() {
  local item="$1"
  local existing
  [[ -n "${item//[[:space:]]/}" ]] || return 0
  for existing in "${models_to_include[@]}"; do
    [[ "$existing" == "$item" ]] && return 0
  done
  models_to_include+=("$item")
}

json_query() {
  local path="$1"
  CURRENT_JSON_PATH="$current_json" node - "$path" <<'NODE'
const fs = require("fs");
const obj = JSON.parse(fs.readFileSync(process.env.CURRENT_JSON_PATH, "utf8"));
const path = process.argv[2].split(".");
let value = obj;
for (const key of path) value = value == null ? undefined : value[key];
if (Array.isArray(value)) {
  process.stdout.write(value.join(", "));
} else if (value == null) {
  process.stdout.write("");
} else {
  process.stdout.write(String(value));
}
NODE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

config_dir="$HOME/.claude-code-router"
config_path="$config_dir/config.json"
custom_router_path="$config_dir/custom-router.js"
claude_dir="$HOME/.claude"
settings_path="$claude_dir/settings.json"
backups_dir="$config_dir/backups"

require_cmd node

[[ -f "$config_path" ]] || die "Missing CCR config: $config_path. Run the Linux installer first."

mkdir -p "$config_dir" "$claude_dir" "$backups_dir"
current_json="$(mktemp)"
trap 'rm -f "$current_json"' EXIT

step "Loading current configuration"
CONFIG_PATH="$config_path" CUSTOM_ROUTER_PATH="$custom_router_path" SETTINGS_PATH="$settings_path" node > "$current_json" <<'NODE'
const fs = require("fs");

function loadJson(path) {
  if (!fs.existsSync(path)) return {};
  const raw = fs.readFileSync(path, "utf8");
  if (!raw.trim()) return {};
  return JSON.parse(raw);
}

function normalizeBaseUrl(url) {
  if (!url || !String(url).trim()) return "";
  let trimmed = String(url).trim().replace(/\/+$/, "");
  if (!trimmed.endsWith("/v1")) trimmed += "/v1";
  return trimmed;
}

function asArray(value) {
  if (value == null) return [];
  return Array.isArray(value) ? value : [value];
}

function stringList(value) {
  return asArray(value)
    .map((item) => String(item))
    .filter((item) => item.trim());
}

function resolveProviderName(config) {
  const providers = asArray(config.Providers);
  if (providers.length === 0) throw new Error(`No providers found in ${process.env.CONFIG_PATH}`);
  const routerDefault = config.Router && config.Router.default;
  if (typeof routerDefault === "string" && routerDefault.includes(",")) {
    const candidate = routerDefault.split(",")[0].trim();
    if (providers.some((provider) => provider && provider.name === candidate)) return candidate;
  }
  if (providers.some((provider) => provider && provider.name === "custom-openai")) return "custom-openai";
  if (providers[0] && providers[0].name) return String(providers[0].name);
  throw new Error("Could not resolve provider name.");
}

function getProvider(config, providerName) {
  const provider = asArray(config.Providers).find((item) => item && item.name === providerName);
  if (!provider) throw new Error(`Provider not found: ${providerName}`);
  return provider;
}

function getCurrentBaseUrl(config, provider) {
  if (config.OPENAI_BASE_URL && String(config.OPENAI_BASE_URL).trim()) {
    return normalizeBaseUrl(config.OPENAI_BASE_URL);
  }
  let providerUrl = String(provider.api_base_url || "");
  if (!providerUrl.trim()) return "";
  if (providerUrl.endsWith("/chat/completions")) {
    providerUrl = providerUrl.slice(0, -"/chat/completions".length);
  }
  return normalizeBaseUrl(providerUrl);
}

function getCurrentRouteModel(config, provider) {
  if (config.OPENAI_MODEL && String(config.OPENAI_MODEL).trim()) return String(config.OPENAI_MODEL);
  const routerDefault = config.Router && config.Router.default;
  if (typeof routerDefault === "string" && routerDefault.includes(",")) {
    return routerDefault.split(",", 2)[1].trim();
  }
  const models = stringList(provider.models);
  return models[0] || "";
}

function getFamilyModelMapping(path, defaultModel) {
  const mapping = { sonnet: defaultModel, opus: defaultModel, haiku: defaultModel };
  if (!fs.existsSync(path)) return mapping;
  const content = fs.readFileSync(path, "utf8");
  for (const family of ["sonnet", "opus", "haiku"]) {
    const re = new RegExp(`claude-${family}['"\`]\\s*:\\s*['"\`]([^'"\`]+)['"\`]`);
    const match = content.match(re);
    if (match) mapping[family] = match[1];
  }
  return mapping;
}

const config = loadJson(process.env.CONFIG_PATH);
const settings = loadJson(process.env.SETTINGS_PATH);
if (!config.Providers || asArray(config.Providers).length === 0) {
  throw new Error(`No providers found in ${process.env.CONFIG_PATH}`);
}

const providerName = resolveProviderName(config);
const provider = getProvider(config, providerName);
const routeModel = getCurrentRouteModel(config, provider);
const family = getFamilyModelMapping(process.env.CUSTOM_ROUTER_PATH, routeModel);
const permissionMode =
  settings.permissions && settings.permissions.defaultMode
    ? String(settings.permissions.defaultMode)
    : "default";

process.stdout.write(JSON.stringify({
  providerName,
  baseUrl: getCurrentBaseUrl(config, provider),
  apiKey: String(provider.api_key || config.OPENAI_API_KEY || ""),
  models: stringList(provider.models),
  routeModel,
  sonnetModel: family.sonnet || routeModel,
  opusModel: family.opus || routeModel,
  haikuModel: family.haiku || routeModel,
  permissionMode,
}, null, 2));
NODE

provider_name="$(json_query providerName)"
current_base_url="$(trim "$(json_query baseUrl)")"
current_api_key="$(trim "$(json_query apiKey)")"
current_models_csv="$(trim "$(json_query models)")"
current_route_model="$(trim "$(json_query routeModel)")"
current_sonnet_model="$(trim "$(json_query sonnetModel)")"
current_opus_model="$(trim "$(json_query opusModel)")"
current_haiku_model="$(trim "$(json_query haikuModel)")"
current_permission_mode="$(trim "$(json_query permissionMode)")"

printf '\n\033[32mCurrent values:\033[0m\n'
printf '  Provider: %s\n' "$provider_name"
printf '  Endpoint: %s\n' "$current_base_url"
printf '  API key: %s\n' "$(mask_value "$current_api_key")"
printf '  Provider models: %s\n' "$current_models_csv"
printf '  Default CCR route model: %s\n' "$current_route_model"
printf '  Sonnet downstream model: %s\n' "$current_sonnet_model"
printf '  Opus downstream model: %s\n' "$current_opus_model"
printf '  Haiku downstream model: %s\n' "$current_haiku_model"
printf '  Permission mode: %s\n\n' "$current_permission_mode"

new_base_url_input="$(prompt_value_or_keep "Endpoint URL" "$current_base_url")"
new_api_key="$(prompt_secret_or_keep "API key" "$(mask_value "$current_api_key")")"
new_models_input="$(prompt_value_or_keep "Provider models (comma-separated)" "$current_models_csv")"
new_route_model_input="$(prompt_value_or_keep "Default CCR route model" "$current_route_model")"
model_mode="$(prompt_choice "Claude family downstream routing" "keep" keep all individual)"
bypass_mode="$(prompt_choice "Bypass permissions mode" "keep" keep enable disable)"

base_url="$current_base_url"
[[ -n "$new_base_url_input" ]] && base_url="$(normalize_base_url "$new_base_url_input")"

api_key="$current_api_key"
[[ -n "$new_api_key" ]] && api_key="$(trim "$new_api_key")"

provider_models=()
if [[ -n "$new_models_input" ]]; then
  mapfile -t provider_models < <(parse_models_csv "$new_models_input")
else
  mapfile -t provider_models < <(parse_models_csv "$current_models_csv")
fi

route_model="$current_route_model"
[[ -n "$new_route_model_input" ]] && route_model="$(trim "$new_route_model_input")"
if [[ -z "$route_model" && "${#provider_models[@]}" -gt 0 ]]; then
  route_model="${provider_models[0]}"
fi
[[ -n "$route_model" ]] || die "A default CCR route model is required."
if [[ "${#provider_models[@]}" -eq 0 ]]; then
  provider_models=("$route_model")
fi

sonnet_model="$current_sonnet_model"
opus_model="$current_opus_model"
haiku_model="$current_haiku_model"

case "$model_mode" in
  all)
    all_model="$(prompt_value_or_keep "Downstream model for Sonnet/Opus/Haiku" "$current_sonnet_model")"
    if [[ -n "$all_model" ]]; then
      sonnet_model="$all_model"
      opus_model="$all_model"
      haiku_model="$all_model"
    fi
    ;;
  individual)
    new_sonnet_model="$(prompt_value_or_keep "Sonnet downstream model" "$current_sonnet_model")"
    new_opus_model="$(prompt_value_or_keep "Opus downstream model" "$current_opus_model")"
    new_haiku_model="$(prompt_value_or_keep "Haiku downstream model" "$current_haiku_model")"
    [[ -n "$new_sonnet_model" ]] && sonnet_model="$new_sonnet_model"
    [[ -n "$new_opus_model" ]] && opus_model="$new_opus_model"
    [[ -n "$new_haiku_model" ]] && haiku_model="$new_haiku_model"
    ;;
esac

models_to_include=()
for model in "${provider_models[@]}" "$route_model" "$sonnet_model" "$opus_model" "$haiku_model" "claude-sonnet" "claude-opus" "claude-haiku"; do
  append_unique "$model"
done
provider_models=("${models_to_include[@]}")

[[ -n "$base_url" ]] || die "Endpoint URL is required."
[[ -n "$api_key" ]] || die "API key is required."

printf '\n\033[32mNew values:\033[0m\n'
printf '  Endpoint: %s\n' "$base_url"
printf '  API key: %s\n' "$(mask_value "$api_key")"
printf '  Provider models: %s\n' "$(IFS=', '; printf '%s' "${provider_models[*]}")"
printf '  Default CCR route model: %s\n' "$route_model"
printf '  Sonnet downstream model: %s\n' "$sonnet_model"
printf '  Opus downstream model: %s\n' "$opus_model"
printf '  Haiku downstream model: %s\n' "$haiku_model"
printf '  Permission mode request: %s\n\n' "$bypass_mode"

read -r -p "Apply changes? [y/N]: " apply
case "$apply" in
  y|Y|yes|YES) ;;
  *) die "Canceled." ;;
esac

timestamp="$(date +%Y%m%d-%H%M%S)"
cp "$config_path" "$backups_dir/config.reconfigure.$timestamp.json"
if [[ -f "$settings_path" ]]; then
  cp "$settings_path" "$backups_dir/settings.reconfigure.$timestamp.json"
fi
if [[ -f "$custom_router_path" ]]; then
  cp "$custom_router_path" "$backups_dir/custom-router.reconfigure.$timestamp.js"
fi

models_json="$(printf '%s\n' "${provider_models[@]}" | node -e 'const fs=require("fs"); const lines=fs.readFileSync(0,"utf8").split(/\n/).filter(Boolean); process.stdout.write(JSON.stringify(lines));')"

step "Updating CCR config"
CONFIG_PATH="$config_path" \
CUSTOM_ROUTER_PATH="$custom_router_path" \
PROVIDER_NAME="$provider_name" \
BASE_URL="$base_url" \
API_KEY="$api_key" \
MODELS_JSON="$models_json" \
ROUTE_MODEL="$route_model" \
SONNET_MODEL="$sonnet_model" \
OPUS_MODEL="$opus_model" \
HAIKU_MODEL="$haiku_model" \
node <<'NODE'
const fs = require("fs");

function loadJson(path) {
  if (!fs.existsSync(path)) return {};
  const raw = fs.readFileSync(path, "utf8");
  return raw.trim() ? JSON.parse(raw) : {};
}

function asArray(value) {
  if (value == null) return [];
  return Array.isArray(value) ? value : [value];
}

function writeFamilyRouter(path, providerName, sonnetModel, opusModel, haikuModel) {
  const provider = JSON.stringify(providerName);
  const entries = {
    "claude-sonnet": sonnetModel,
    "claude-opus": opusModel,
    "claude-haiku": haikuModel,
    sonnet: sonnetModel,
    opus: opusModel,
    haiku: haikuModel,
  };
  const lines = Object.entries(entries)
    .map(([key, value]) => `  ${JSON.stringify(key)}: ${JSON.stringify(value)},`)
    .join("\n");
  const content = `const provider = ${provider};
const familyModels = {
${lines}
};

module.exports = async function router(req) {
  const requestedModel = req && req.body && req.body.model;
  if (typeof requestedModel === 'string') {
    for (const [familyModel, downstreamModel] of Object.entries(familyModels)) {
      if (requestedModel === familyModel || requestedModel.includes(familyModel)) {
        return provider + ',' + downstreamModel;
      }
    }
  }
  return null;
};
`;
  fs.writeFileSync(path, content);
}

const configPath = process.env.CONFIG_PATH;
const customRouterPath = process.env.CUSTOM_ROUTER_PATH;
const providerName = process.env.PROVIDER_NAME;
const baseUrl = process.env.BASE_URL;
const apiKey = process.env.API_KEY;
const models = JSON.parse(process.env.MODELS_JSON);
const routeModel = process.env.ROUTE_MODEL;
const sonnetModel = process.env.SONNET_MODEL;
const opusModel = process.env.OPUS_MODEL;
const haikuModel = process.env.HAIKU_MODEL;

const config = loadJson(configPath);
const providers = asArray(config.Providers);
const provider = providers.find((item) => item && item.name === providerName);
if (!provider) throw new Error(`Provider not found: ${providerName}`);

provider.api_base_url = `${baseUrl}/chat/completions`;
provider.api_key = apiKey;
provider.models = models;
config.OPENAI_BASE_URL = baseUrl;
config.OPENAI_API_KEY = apiKey;
config.OPENAI_MODEL = routeModel;
config.CUSTOM_ROUTER_PATH = customRouterPath;
config.Router = config.Router && typeof config.Router === "object" ? config.Router : {};
for (const key of ["default", "background", "think", "longContext"]) {
  config.Router[key] = `${providerName},${routeModel}`;
}
config.Providers = [provider];
if (config.transformers != null && !Array.isArray(config.transformers)) {
  config.transformers = [config.transformers];
}

writeFamilyRouter(customRouterPath, providerName, sonnetModel, opusModel, haikuModel);
fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
NODE

step "Updating Claude settings"
SETTINGS_PATH="$settings_path" BYPASS_MODE="$bypass_mode" node <<'NODE'
const fs = require("fs");

function loadJson(path) {
  if (!fs.existsSync(path)) return {};
  const raw = fs.readFileSync(path, "utf8");
  return raw.trim() ? JSON.parse(raw) : {};
}

const settingsPath = process.env.SETTINGS_PATH;
const bypassMode = process.env.BYPASS_MODE;
const settings = loadJson(settingsPath);

settings.env = settings.env && typeof settings.env === "object" ? settings.env : {};
settings.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:3456";
settings.env.ANTHROPIC_AUTH_TOKEN = "test";
settings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku";
settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus";
settings.env.ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet";
settings.env.CLAUDE_CODE_DISABLE_1M_CONTEXT = "1";

settings.permissions = settings.permissions && typeof settings.permissions === "object" ? settings.permissions : {};
if (bypassMode === "enable") settings.permissions.defaultMode = "bypassPermissions";
if (bypassMode === "disable") settings.permissions.defaultMode = "default";

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
NODE

effective_permission_mode="$(node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write((s.permissions&&s.permissions.defaultMode)||"default")' "$settings_path")"

step "Done"
printf '\n\033[32mUpdated values:\033[0m\n'
printf '  Endpoint: %s\n' "$base_url"
printf '  API key: %s\n' "$(mask_value "$api_key")"
printf '  Provider models: %s\n' "$(IFS=', '; printf '%s' "${provider_models[*]}")"
printf '  Default CCR route model: %s\n' "$route_model"
printf '  Sonnet downstream model: %s\n' "$sonnet_model"
printf '  Opus downstream model: %s\n' "$opus_model"
printf '  Haiku downstream model: %s\n' "$haiku_model"
printf '  Permission mode: %s\n' "$effective_permission_mode"
printf '\nRestart CCR before using Claude again:\n'
printf '  systemctl --user restart claude-code-router.service\n'
