#!/bin/sh

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 <function_name> <code_file> <ip_address> [port]"
    echo "Example: $0 hello hello.ol 10.81.80.214"
    echo "Example with custom port: $0 time time.ol 10.0.2.10 8000"
    exit 1
fi

NAME="$1"
CODE_FILE="$2"
IP_ADDR="$3"
PORT="${4:-8000}" # Default to 8000 if not provided

# Verify the code file exists
if [ ! -f "$CODE_FILE" ]; then
    echo "❌ Error: Code file '$CODE_FILE' not found!"
    exit 1
fi

echo "⬆️  Uploading function '$NAME' from '$CODE_FILE' to http://${IP_ADDR}:${PORT}/put ..."

# Execute the upload
jq -n --arg name "$NAME" --arg code "$(cat "$CODE_FILE")" \
  '{name: $name, code: $code}' | \
curl -s -X POST "http://${IP_ADDR}:${PORT}/put" \
  -H "Content-Type: application/json" -d @-

# Print a newline so the terminal prompt doesn't overlap the JSON response
echo -e "\n✅ Done."