#!/usr/bin/env bash
# Run neovia tests via plenary in headless Neovim.
set -uo pipefail

cd "$(dirname "$0")/.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

dir="${1:-tests/neovia}"

echo "Running tests in ${dir} ..."
output=$(nvim --headless -u tests/minimal_init.lua \
  -c "lua require('plenary.test_harness').test_directory('${dir}', {minimal_init = './tests/minimal_init.lua', sequential = true})" 2>&1)

echo "$output"

# plenary exits non-zero even on success in headless mode;
# strip ANSI codes and check the actual output for failures.
clean=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

if echo "$clean" | grep -qE "Failed :[[:space:]]*0" && ! echo "$clean" | grep -q "^Fail.*||"; then
  echo -e "\n${GREEN}All tests passed.${NC}"
  exit 0
else
  echo -e "\n${RED}Tests failed.${NC}"
  exit 1
fi
