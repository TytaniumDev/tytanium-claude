#!/bin/bash
# setup-antigravity.sh
# Automatically configures the TytaniumAntigravitySkills plugin for Antigravity on macOS.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="${SCRIPT_DIR}/plugins/TytaniumAntigravitySkills"
PLUGIN_DEST="${HOME}/.gemini/config/plugins/tytanium-agent-skills"

echo "Setting up Tytanium Antigravity Skills..."

# Ensure the global plugins directory exists
mkdir -p "${HOME}/.gemini/config/plugins"

# Remove existing symlink or folder if present
if [ -e "${PLUGIN_DEST}" ] || [ -L "${PLUGIN_DEST}" ]; then
    echo "Removing existing link/directory at ${PLUGIN_DEST}"
    rm -rf "${PLUGIN_DEST}"
fi

# Create symlink
echo "Linking plugin from ${PLUGIN_SRC} to ${PLUGIN_DEST}"
ln -s "${PLUGIN_SRC}" "${PLUGIN_DEST}"

echo "Tytanium Antigravity Skills registered successfully!"
echo "Available skills: ship-it, ship-no-merge, review-prs, overnight"
