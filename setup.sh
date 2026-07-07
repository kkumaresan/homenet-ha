#!/bin/bash
set -euo pipefail

# ============================================================
# Bootstrap script for homelab Docker stack on a Raspberry Pi
# Reads configuration from .env (copy .env.example first)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load .env ---
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    echo "ERROR: .env file not found."
    echo "Copy .env.example to .env and fill in your values:"
    echo "  cp .env.example .env"
    exit 1
fi
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env"

# Validate required variables
for var in DOCKER_USER DOCKER_BASE HA_NAME HA_LATITUDE HA_LONGITUDE HA_ELEVATION \
           HA_TIMEZONE HA_COUNTRY HA_CURRENCY HA_UNIT_SYSTEM HA_MAINS_VOLTAGE \
           MQTT_PREFIX_1 MQTT_PREFIX_2; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required variable ${var} is not set in .env"
        exit 1
    fi
done

echo "=== Homelab Docker Stack Setup ==="
echo "  User:        ${DOCKER_USER}"
echo "  Base dir:    ${DOCKER_BASE}"
echo "  HA name:     ${HA_NAME}"
echo "  Timezone:    ${HA_TIMEZONE}"
echo "  MQTT prefix: ${MQTT_PREFIX_1}, ${MQTT_PREFIX_2}"
echo ""

# ============================================================
# 1. Install Docker
# ============================================================
if ! command -v docker &> /dev/null; then
    echo "[1/7] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "${DOCKER_USER}"
    echo "  -> Docker installed. Log out and back in for group changes."
else
    echo "[1/7] Docker already installed, skipping."
fi

# ============================================================
# 2. Install Docker Compose plugin
# ============================================================
if ! docker compose version &> /dev/null; then
    echo "[2/7] Installing Docker Compose plugin..."
    sudo apt-get update && sudo apt-get install -y docker-compose-plugin
else
    echo "[2/7] Docker Compose plugin already installed, skipping."
fi

# ============================================================
# 3. Create directory structure
# ============================================================
echo "[3/7] Creating directory structure under ${DOCKER_BASE}..."
mkdir -p "${DOCKER_BASE}/hassio/homeassistant"
mkdir -p "${DOCKER_BASE}/mosquitto/config"
mkdir -p "${DOCKER_BASE}/mosquitto/data"
mkdir -p "${DOCKER_BASE}/mosquitto/log"
mkdir -p "${DOCKER_BASE}/portainer"

# ============================================================
# 4. Generate Home Assistant secrets.yaml from .env
# ============================================================
SECRETS_FILE="${DOCKER_BASE}/hassio/homeassistant/secrets.yaml"
echo "[4/7] Generating secrets.yaml..."
cat > "${SECRETS_FILE}" << EOF
# Auto-generated from .env by setup.sh — do not commit to git
ha_name: "${HA_NAME}"
ha_latitude: ${HA_LATITUDE}
ha_longitude: ${HA_LONGITUDE}
ha_elevation: ${HA_ELEVATION}
ha_timezone: "${HA_TIMEZONE}"
ha_unit_system: "${HA_UNIT_SYSTEM}"
ha_country: "${HA_COUNTRY}"
ha_currency: "${HA_CURRENCY}"
EOF
echo "  -> ${SECRETS_FILE} written."

# ============================================================
# 5. Copy config files and apply MQTT prefix substitution
# ============================================================
echo "[5/7] Deploying configuration files..."

# Copy HA config tree (excluding runtime data)
rsync -a --exclude '.storage' --exclude '*.log*' --exclude '*.db*' \
    --exclude 'deps/' --exclude 'tts/' --exclude 'backups/' \
    --exclude 'secrets.yaml' --exclude '.cloud/' \
    "${SCRIPT_DIR}/hassio/homeassistant/" "${DOCKER_BASE}/hassio/homeassistant/"

# Copy mosquitto.conf (not pwfile — that's created separately)
cp "${SCRIPT_DIR}/mosquitto/config/mosquitto.conf" "${DOCKER_BASE}/mosquitto/config/mosquitto.conf"

# Apply MQTT topic prefix substitution if prefixes differ from defaults
DEFAULT_PREFIX_1="kk"
DEFAULT_PREFIX_2="sai-nivas"

if [ "${MQTT_PREFIX_1}" != "${DEFAULT_PREFIX_1}" ] || [ "${MQTT_PREFIX_2}" != "${DEFAULT_PREFIX_2}" ]; then
    echo "  -> Applying MQTT prefix substitution..."
    echo "     ${DEFAULT_PREFIX_1}/ -> ${MQTT_PREFIX_1}/"
    echo "     ${DEFAULT_PREFIX_2}/ -> ${MQTT_PREFIX_2}/"

    # Safely escape prefixes for sed (handle hyphens, dots)
    ESC_OLD_1=$(printf '%s\n' "${DEFAULT_PREFIX_1}" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    ESC_NEW_1=$(printf '%s\n' "${MQTT_PREFIX_1}" | sed 's/[&/\\]/\\&/g')
    ESC_OLD_2=$(printf '%s\n' "${DEFAULT_PREFIX_2}" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    ESC_NEW_2=$(printf '%s\n' "${MQTT_PREFIX_2}" | sed 's/[&/\\]/\\&/g')

    find "${DOCKER_BASE}/hassio/homeassistant/entities" \
         "${DOCKER_BASE}/hassio/homeassistant/integrations" \
         -name '*.yaml' -type f \
         -exec sed -i "s|\"${ESC_OLD_1}/|\"${ESC_NEW_1}/|g" {} +

    # Also apply prefix substitution to seeded .storage JSON files (lovelace, config_entries)
    for sf in "${DOCKER_BASE}/hassio/homeassistant/.storage/lovelace" \
              "${DOCKER_BASE}/hassio/homeassistant/.storage/core.config_entries"; do
        [ -f "$sf" ] && sed -i "s|${ESC_OLD_1}/|${ESC_NEW_1}/|g" "$sf"
    done

    find "${DOCKER_BASE}/hassio/homeassistant/entities" \
         "${DOCKER_BASE}/hassio/homeassistant/integrations" \
         -name '*.yaml' -type f \
         -exec sed -i "s|\"${ESC_OLD_2}/|\"${ESC_NEW_2}/|g" {} +

    for sf in "${DOCKER_BASE}/hassio/homeassistant/.storage/lovelace" \
              "${DOCKER_BASE}/hassio/homeassistant/.storage/core.config_entries"; do
        [ -f "$sf" ] && sed -i "s|${ESC_OLD_2}/|${ESC_NEW_2}/|g" "$sf"
    done
else
    echo "  -> MQTT prefixes match defaults, no substitution needed."
fi

# Apply mains voltage substitution in energy templates
DEFAULT_VOLTAGE="220"
if [ "${HA_MAINS_VOLTAGE}" != "${DEFAULT_VOLTAGE}" ]; then
    echo "  -> Applying mains voltage substitution: ${DEFAULT_VOLTAGE}V -> ${HA_MAINS_VOLTAGE}V"
    find "${DOCKER_BASE}/hassio/homeassistant/entities" \
         -name '*.yaml' -type f \
         -exec sed -i "s/\* ${DEFAULT_VOLTAGE}/\* ${HA_MAINS_VOLTAGE}/g" {} +
fi

# ============================================================
# 6. Set up Mosquitto password file
# ============================================================
PWFILE="${DOCKER_BASE}/mosquitto/config/pwfile"
if [ ! -f "${PWFILE}" ]; then
    echo "[6/7] Mosquitto password file not found."
    echo "  -> Create one with:"
    echo "     docker run --rm -it -v ${DOCKER_BASE}/mosquitto/config:/mosquitto/config eclipse-mosquitto mosquitto_passwd -c /mosquitto/config/pwfile <username>"
else
    echo "[6/7] Mosquitto password file exists, skipping."
fi

# Set Mosquitto directory ownership (runs as UID 1883 inside container)
sudo chown -R 1883:1883 "${DOCKER_BASE}/mosquitto"

# ============================================================
# 7. Generate Portainer self-signed TLS certs
# ============================================================
PORTAINER_CERTS="${DOCKER_BASE}/portainer/certs"
mkdir -p "${PORTAINER_CERTS}"
if [ ! -f "${PORTAINER_CERTS}/cert.pem" ]; then
    echo "[7/7] Generating Portainer self-signed TLS certificates..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${PORTAINER_CERTS}/key.pem" \
        -out "${PORTAINER_CERTS}/cert.pem" \
        -days 3650 -nodes \
        -subj "/CN=portainer/O=homelab"
    echo "  -> Self-signed cert generated (valid 10 years)."
else
    echo "[7/7] Portainer TLS certs already exist, skipping."
fi

# ============================================================
# Done
# ============================================================
echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Create Mosquitto password (if not done):"
echo "     docker run --rm -it -v ${DOCKER_BASE}/mosquitto/config:/mosquitto/config \\"
echo "       eclipse-mosquitto mosquitto_passwd -c /mosquitto/config/pwfile <username>"
echo ""
echo "  2. Start the stack:"
echo "     cd ${SCRIPT_DIR}"
echo "     docker compose up -d"
echo ""
echo "  3. Access services:"
echo "     Home Assistant: http://<pi-ip>:${HA_PORT:-8123}"
echo "     Portainer:      http://<pi-ip>:${PORTAINER_PORT:-9000}"
echo "     Mosquitto MQTT: <pi-ip>:${MQTT_PORT:-1883}"
echo "     Mosquitto WS:   <pi-ip>:${MQTT_WS_PORT:-9001}"
