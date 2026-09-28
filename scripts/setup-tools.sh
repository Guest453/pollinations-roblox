#!/usr/bin/env bash
# Fetches the Luau toolchain used by CI/local verification into ./tools
set -euo pipefail
mkdir -p tools
cd tools
curl -sL -o luau.zip https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip && unzip -o luau.zip && rm luau.zip
curl -sL -o lualsp.zip https://github.com/JohnnyMorganz/luau-lsp/releases/latest/download/luau-lsp-linux-x86_64.zip && unzip -o lualsp.zip && rm lualsp.zip
curl -sL -o rojo.zip https://github.com/rojo-rbx/rojo/releases/download/v7.7.0/rojo-7.7.0-linux-x86_64.zip && unzip -o rojo.zip && rm rojo.zip
curl -sL -o globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
chmod +x luau luau-analyze luau-ast luau-compile luau-lsp rojo
echo "tools ready:"
./luau-lsp --version && ./rojo --version
