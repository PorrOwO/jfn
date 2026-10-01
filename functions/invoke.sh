#!/bin/sh

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: $0 <function_name> <data> <ip_address> [port]"
    echo "Example: $0 hello world 10.81.80.214"
    echo "Example with custom port: $0 time 'yyyy-MM-dd HH:mm:ss' 10.0.2.10 8000"
    exit 1
fi

NAME="$1"
DATA="$2"
IP_ADDR="$3"
PORT="${4:-8000}"

echo "▶️  Invoking function '$NAME' on http://${IP_ADDR}:${PORT}/op ..."

curl -s -X POST "http://${IP_ADDR}:${PORT}/op" \
  -H "Content-Type: application/json" \
  -d "{\"fn\": \"$NAME\", \"data\": \"$DATA\"}"

echo -e "\n✅ Done."