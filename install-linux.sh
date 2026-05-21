#!/usr/bin/env bash
set -Eeuo pipefail

step() {
  printf '\033[36m==> %s\033[0m\n' "$*"
}

die() {
  printf '\033[31merror: %s\033[0m\n' "$*" >&2
  exit 1
}

prompt_value() {
  local label="$1"
  local default="${2:-}"
  local secret="${3:-false}"
  local suffix=""
  local value=""

  if [[ -n "$default" ]]; then
    suffix=" [$default]"
  fi

  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$label$suffix: " value
    printf '\n' >&2
  else
    read -r -p "$label$suffix: " value
  fi

  if [[ -z "${value//[[:space:]]/}" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

normalize_base_url() {
  local url="$1"
  url="${url%"${url##*[![:space:]]}"}"
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%/}"
  if [[ "$url" != */v1 ]]; then
    url="$url/v1"
  fi
  printf '%s' "$url"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

confirm() {
  local answer=""
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

step "Checking required commands"
require_cmd node
require_cmd npm
require_cmd claude
require_cmd curl

npm_prefix="${NPM_GLOBAL_PREFIX:-$HOME/.local/share/npm-global}"
npm_bin_dir="$npm_prefix/bin"
npm_root="$(npm root -g --prefix "$npm_prefix")"
ccr_package_dir="$npm_root/@musistudio/claude-code-router"
cli_path="$ccr_package_dir/dist/cli.js"

mkdir -p "$npm_bin_dir"
export PATH="$npm_bin_dir:$PATH"

if [[ ! -f "$cli_path" ]]; then
  step "claude-code-router is not installed in $npm_prefix"
  if confirm "Install @musistudio/claude-code-router with npm --prefix $npm_prefix"; then
    npm install -g --prefix "$npm_prefix" @musistudio/claude-code-router
  else
    die "claude-code-router is required."
  fi
fi

[[ -f "$cli_path" ]] || die "claude-code-router was not installed correctly: $cli_path"

base_url="$(normalize_base_url "$(prompt_value "Endpoint URL" "https://example.com/v1")")"
api_key="$(prompt_value "API key" "" true)"
models_input="$(prompt_value "Model(s), comma-separated" "gpt-5.4")"

[[ -n "${api_key//[[:space:]]/}" ]] || die "API key is required."

IFS=',' read -r -a raw_models <<< "$models_input"
models=()
for model in "${raw_models[@]}"; do
  model="${model#"${model%%[![:space:]]*}"}"
  model="${model%"${model##*[![:space:]]}"}"
  [[ -n "$model" ]] && models+=("$model")
done

[[ "${#models[@]}" -gt 0 ]] || die "At least one model is required."

provider_name="custom-openai"
default_model="${models[0]}"
config_dir="$HOME/.claude-code-router"
plugins_dir="$config_dir/plugins"
backups_dir="$config_dir/backups"
config_path="$config_dir/config.json"
claude_dir="$HOME/.claude"
settings_path="$claude_dir/settings.json"
plugin_path="$plugins_dir/strip-reasoning.js"
run_wrapper="$HOME/.local/bin/openai-code-claude"
ccr_wrapper="$HOME/.local/bin/ccr-openai-code"

printf '\nThis will write/update:\n'
printf '  %s\n' "$config_path" "$settings_path" "$plugin_path" "$run_wrapper"
printf '  %s\n' "$ccr_wrapper"
printf '\nIt will also patch the local claude-code-router CLI if the known reasoning snippet is present.\n'
confirm "Continue" || die "Canceled."

mkdir -p "$plugins_dir" "$backups_dir" "$claude_dir" "$HOME/.local/bin"

step "Writing CCR plugin"
cat > "$plugin_path" <<'JS'
class StripReasoningTransformer {
  constructor() {
    this.name = "strip-reasoning";
  }

  async transformRequestIn(request) {
    if (request && typeof request === "object") {
      delete request.reasoning;
      delete request.thinking;
    }
    return request;
  }

  async transformResponseOut(response) {
    return response;
  }
}

module.exports = StripReasoningTransformer;
JS

step "Writing CCR config"
models_json="$(printf '%s\n' "${models[@]}" | node -e 'const fs=require("fs"); const lines=fs.readFileSync(0,"utf8").split(/\n/).filter(Boolean); process.stdout.write(JSON.stringify(lines));')"
CONFIG_PATH="$config_path" \
PLUGIN_PATH="$plugin_path" \
PROVIDER_NAME="$provider_name" \
BASE_URL="$base_url" \
API_KEY="$api_key" \
MODELS_JSON="$models_json" \
DEFAULT_MODEL="$default_model" \
node <<'NODE'
const fs = require("fs");
const configPath = process.env.CONFIG_PATH;
const pluginPath = process.env.PLUGIN_PATH;
const providerName = process.env.PROVIDER_NAME;
const baseUrl = process.env.BASE_URL;
const apiKey = process.env.API_KEY;
const models = JSON.parse(process.env.MODELS_JSON);
const defaultModel = process.env.DEFAULT_MODEL;

const provider = {
  name: providerName,
  api_base_url: `${baseUrl}/chat/completions`,
  api_key: apiKey,
  models,
  transformer: {
    use: ["openai", "strip-reasoning"],
  },
};

const config = {
  LOG: true,
  LOG_LEVEL: "debug",
  API_TIMEOUT_MS: 600000,
  NON_INTERACTIVE_MODE: false,
  OPENAI_API_KEY: apiKey,
  OPENAI_BASE_URL: baseUrl,
  OPENAI_MODEL: defaultModel,
  transformers: [{ path: pluginPath }],
  Providers: [provider],
  Router: {
    default: `${providerName},${defaultModel}`,
    background: `${providerName},${defaultModel}`,
    think: `${providerName},${defaultModel}`,
    longContext: `${providerName},${defaultModel}`,
  },
};

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
NODE

step "Patching Claude settings"
if [[ -f "$settings_path" && ! -f "$backups_dir/settings.json.original" ]]; then
  cp "$settings_path" "$backups_dir/settings.json.original"
fi

SETTINGS_PATH="$settings_path" node <<'NODE'
const fs = require("fs");
const settingsPath = process.env.SETTINGS_PATH;
let settings = {};
if (fs.existsSync(settingsPath)) {
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch {
    settings = {};
  }
}

if (!settings.env || typeof settings.env !== "object") {
  settings.env = {};
}

settings.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:3456";
settings.env.ANTHROPIC_AUTH_TOKEN = "test";
settings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku";
settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus";
settings.env.ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet";
settings.env.CLAUDE_CODE_DISABLE_1M_CONTEXT = "1";
delete settings.statusLine;
settings.disableLoginPrompt = true;
if (!Object.prototype.hasOwnProperty.call(settings, "autoUpdatesChannel")) {
  settings.autoUpdatesChannel = "latest";
}

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
NODE

step "Patching local CCR OpenAI transformer"
CLI_PATH="$cli_path" BACKUP_PATH="$backups_dir/cli.js.original" node <<'NODE'
const fs = require("fs");
const cliPath = process.env.CLI_PATH;
if (fs.existsSync(cliPath)) {
  let content = fs.readFileSync(cliPath, "utf8");
  const oldSnippet = 'return e.thinking&&(r.reasoning={effort:EN(e.thinking.budget_tokens),enabled:e.thinking.type==="enabled"}),e.tool_choice&&';
  const newSnippet = 'return e.tool_choice&&';
  if (content.includes(oldSnippet)) {
    const backup = process.env.BACKUP_PATH;
    if (!fs.existsSync(backup)) fs.copyFileSync(cliPath, backup);
    content = content.replace(oldSnippet, newSnippet);
    fs.writeFileSync(cliPath, content);
  }
}
NODE

step "Writing Linux wrappers"
if [[ -f "$ccr_wrapper" && ! -f "$backups_dir/ccr.original" ]]; then
  cp "$ccr_wrapper" "$backups_dir/ccr.original"
fi

cat > "$ccr_wrapper" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=$(printf '%q' "$HOME/.local/bin"):$(printf '%q' "$npm_bin_dir"):/usr/local/bin:/usr/bin:\$PATH
cli_path=$(printf '%q' "$cli_path")

if [[ "\${1:-}" == "start" ]]; then
  if ! ss -H -ltn "sport = :3456" | grep -q .; then
    if command -v systemd-run >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
      systemctl --user stop claude-code-router.service >/dev/null 2>&1 || true
      systemctl --user reset-failed claude-code-router.service >/dev/null 2>&1 || true
      systemd-run --user \\
        --unit=claude-code-router \\
        --collect \\
        --setenv=PATH="\$PATH" \\
        /usr/bin/node "\$cli_path" start >/dev/null
    else
      nohup node "\$cli_path" start >/tmp/claude-code-router.log 2>&1 &
    fi
    ready=false
    for _ in \$(seq 1 20); do
      if curl -fsS --max-time 2 http://127.0.0.1:3456/ >/dev/null 2>&1 || ss -H -ltn "sport = :3456" | grep -q .; then
        ready=true
        break
      fi
      sleep 1
    done
    if [[ "\$ready" != "true" ]]; then
      echo "CCR did not become ready on http://127.0.0.1:3456" >&2
      exit 1
    fi
  fi
  shift
  exec claude "\$@"
fi

exec node "\$cli_path" "\$@"
EOF
chmod +x "$ccr_wrapper"

cat > "$run_wrapper" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=$(printf '%q' "$npm_bin_dir"):\$PATH
exec $(printf '%q' "$ccr_wrapper") start "\$@"
EOF
chmod +x "$run_wrapper"

step "Restarting CCR"
pkill -f 'claude-code-router.*/dist/cli.js.*start' 2>/dev/null || true
nohup node "$cli_path" start >/tmp/claude-code-router.log 2>&1 &

ready=false
for _ in $(seq 1 20); do
  if curl -fsSI http://127.0.0.1:3456/ >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done

[[ "$ready" == "true" ]] || die "CCR did not become ready on http://127.0.0.1:3456. See /tmp/claude-code-router.log"

step "Done"
printf '\nConfig written to:\n'
printf '  %s\n' "$config_path" "$settings_path" "$plugin_path" "$run_wrapper"
printf '\nOpen a new terminal and run:\n'
printf '  %s\n' "$run_wrapper"
