import std/[json, jsonutils]

# 1. Create a JsonNode (a JSON object)
let data = %*{"nome": "kairos", "attivo": true, "livello": 42}

# 2. Convert it to a JSON string
# Here you have to figure out what to use: look at the std/json docs
# Look for "writeJson" or "writePretty"
let jsonString = writeJson(data)

echo "Compact JSON:"
echo jsonString

echo "\nFormatted JSON:"
echo writePretty(data)
