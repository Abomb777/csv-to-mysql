#!/bin/bash

# CSV to MySQL Import Script
# Usage: ./new_bash.sh [-d] [-u URL] [-c CAST_FIELDS] [-s SKIP] [-q SQL_ARGS] [-t TARGET_TABLE] [-f SQL_FIELDS] [-e UPDATE_FIELDS] [-k PRIM_KEYS]...

DEBUG=false
URL_ARG=""
CAST_FIELDS=""
SKIP=0
SQL_ARGS=""
TARGET_TABLE=""
SQL_FIELDS=""
UPDATE_FIELDS_LIST=""
PRIM_KEYS=()
SKIP_LOADING_URL=false

# Parse arguments
while getopts "du:c:s:q:t:f:e:k:zh?" opt; do
  case $opt in
    d) DEBUG=true ;;
    u) URL_ARG="$OPTARG" ;;
    c) CAST_FIELDS="$OPTARG" ;;
    s) SKIP="$OPTARG" ;;
    q) SQL_ARGS="$OPTARG" ;;
    t) TARGET_TABLE="$OPTARG" ;;
    f) SQL_FIELDS="$OPTARG" ;;
    e) UPDATE_FIELDS_LIST="$OPTARG" ;;
    k) PRIM_KEYS+=("$OPTARG") ;;
    z) SKIP_LOADING_URL=true ;;
    h|?) echo "Usage: $0 [-d] [-u URL] [-c CAST_FIELDS] [-s SKIP] [-q SQL_ARGS] [-t TARGET_TABLE] [-f SQL_FIELDS] [-e UPDATE_FIELDS] [-k PRIM_KEYS]..."; exit 0 ;;
  esac
done

# Jenkins hash function
jenkins_hash() {
  local key="$1"
  local hash=0
  local i char
  for ((i=0; i<${#key}; i++)); do
    char=$(printf '%d' "'${key:$i:1}")
    hash=$((hash + char))
    hash=$(( (hash + (hash << 10)) & 0xFFFFFFFF ))
    hash=$(( (hash ^ (hash >> 6)) & 0xFFFFFFFF ))
  done
  hash=$(( (hash + (hash << 3)) & 0xFFFFFFFF ))
  hash=$(( (hash ^ (hash >> 11)) & 0xFFFFFFFF ))
  hash=$(( (hash + (hash << 15)) & 0xFFFFFFFF ))
  echo $((hash & 0xFFFFFFFF))
}

# CUID generator
cuid() {
  local chars="abcdefghijklmnopqrstuvwxyz0123456789"
  local out=""
  for i in {1..24}; do
    out+="${chars:RANDOM%${#chars}:1}"
  done
  echo "$out"
}

# Time now function
timenow() {
  local date_only="${1:-false}"
  if [ "$date_only" = "true" ]; then
    date '+%Y-%m-%d'
  else
    date '+%Y-%m-%d %H:%M:%S'
  fi
}

# JS date conversion
jsdate() {
  local str="$1"
  if [ -z "$str" ]; then
    echo ""
    return
  fi
  # Try to parse and format date
  local result
  result=$(date -d "$str" '+%Y-%m-%d' 2>/dev/null) || result=""
  echo "$result"
}

# Calculate file names
HASH=$(jenkins_hash "$URL_ARG")
INPUT_FILE="$(pwd)/${HASH}.csv"
OUTPUT_FILE="$(pwd)/${HASH}_rez.csv"

echo "=== CSV Import Configuration ==="
echo "Url (-u): ${URL_ARG:0:50}..."
echo "Debug (-d): $DEBUG"
echo "Cast (-c): $CAST_FIELDS"
echo "Sql (-q -t): $SQL_ARGS -> $TARGET_TABLE"
echo "Skip lines (-s): $SKIP"
echo "Sql fields (-f): $SQL_FIELDS"
echo "Update fields (-e): $UPDATE_FIELDS_LIST"
echo "Prim keys (-k): $(IFS=,; echo "${PRIM_KEYS[*]}")"
echo "Input file: $INPUT_FILE"
echo "Output file: $OUTPUT_FILE"
echo "================================"

echo "Starting CSV import..."

# Download file if not skipping
if [ "$SKIP_LOADING_URL" = "false" ]; then
  if [ -n "$URL_ARG" ]; then
    curl -sL "$URL_ARG" -o "$INPUT_FILE"
    if [ $? -ne 0 ]; then
      echo "Error downloading file"
      exit 1
    fi
    [ "$DEBUG" = "true" ] && echo "DEBUG: Downloaded from URL: $INPUT_FILE"
  fi
else
  echo "DEBUG: Skipping CSV file load!"
fi

[ "$DEBUG" = "true" ] && echo "DEBUG: Parsing CAST_FIELDS..."

# Process CSV with awk
awk -v skip="$SKIP" -v cast_fields="$CAST_FIELDS" -v debug="$DEBUG" '
BEGIN {
  FS = "\",\""
  OFS = ","
  # Parse JSON-like cast_fields array
  gsub(/^\[|\]$/, "", cast_fields)
  n = split(cast_fields, rules, /,/)
  for (i = 1; i <= n; i++) {
    gsub(/^[ \t"]+|[ \t"]+$/, "", rules[i])
  }
  rule_count = n
  srand()
}

function cuid() {
  chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  out = ""
  for (i = 1; i <= 24; i++) {
    out = out substr(chars, int(rand() * length(chars)) + 1, 1)
  }
  return out
}

function timenow() {
  cmd = "date \"+%Y-%m-%d %H:%M:%S\""
  cmd | getline result
  close(cmd)
  return result
}

function jsdate(str) {
  if (str == "") return ""
  gsub(/^["'\'']+|["'\'']+$/, "", str)
  cmd = "date -d \"" str "\" \"+%Y-%m-%d\" 2>/dev/null"
  result = ""
  cmd | getline result
  close(cmd)
  return result
}

NR > skip && $0 != "" {
  # Remove leading/trailing quotes from first and last fields
  gsub(/^"/, "", $1)
  gsub(/"$/, "", $NF)
  
  all_empty = 1
  out_line = ""
  
  for (i = 1; i <= rule_count; i++) {
    rule = rules[i]
    value = ""
    
    if (rule ~ /^[0-9]+$/) {
      # Numeric index
      idx = int(rule)
      value = $idx
      gsub(/^["'\'']+|["'\'']+$/, "", value)
      if (value ~ /[a-zA-Z0-9]/) all_empty = 0
    } else if (rule ~ /^jsdate\(/) {
      # jsdate function
      gsub(/jsdate\(|\)/, "", rule)
      idx = int(rule)
      value = jsdate($idx)
    } else if (rule == "cuid") {
      value = cuid()
    } else if (rule == "timenow") {
      value = timenow()
    } else if (rule ~ /^line\(/) {
      value = NR
    } else {
      # String literal
      value = rule
    }
    
    if (out_line != "") out_line = out_line ","
    out_line = out_line "\"" value "\""
  }
  
  if (all_empty == 0) {
    print out_line
  }
}
' "$INPUT_FILE" > "$OUTPUT_FILE"

# Build unique keys for SQL
UNIQ_KEYS=""
DELETE_KEYS=""
for key in "${PRIM_KEYS[@]}"; do
  safe_key=$(echo "$key" | tr -c 'a-zA-Z0-9_' '_')
  if [ -n "$UNIQ_KEYS" ]; then
    UNIQ_KEYS="$UNIQ_KEYS,"
  fi
  UNIQ_KEYS="${UNIQ_KEYS}ADD UNIQUE KEY uniq_${safe_key} (${key})"
  
  # Build delete keys
  IFS=',' read -ra key_parts <<< "$key"
  for part in "${key_parts[@]}"; do
    if [ -n "$DELETE_KEYS" ]; then
      DELETE_KEYS="$DELETE_KEYS AND "
    fi
    DELETE_KEYS="${DELETE_KEYS}t.${part} = a.${part}"
  done
done

# Determine mysql path and csv file path
if [ "$(uname)" = "Linux" ]; then
  MYSQL_PATH="mysql"
  CSV_FILE="$OUTPUT_FILE"
else
  MYSQL_PATH="C:\\xampp\\mysql\\bin\\mysql.exe"
  CSV_FILE=$(echo "$OUTPUT_FILE" | sed 's/\\/\\\\/g')
fi

# Build SQL field lists
SQL_FIELDS_AT=$(echo "$SQL_FIELDS" | sed 's/,/,@/g; s/^/@/')
SQL_FIELDS_SET=$(echo "$SQL_FIELDS" | sed "s/\([^,]*\)/\1=NULLIF(@\1,'')/g")
SQL_FIELDS_T=$(echo "$SQL_FIELDS" | sed 's/\([^,]*\)/t.\1/g')
UPDATE_SET=$(echo "$UPDATE_FIELDS_LIST" | sed 's/\([^,]*\)/\1 = t.\1/g')

# Build SQL commands
SQL_FLOW="
CREATE TEMPORARY TABLE \`tmp_preload_${TARGET_TABLE}\` LIKE \`${TARGET_TABLE}\`;
CREATE TEMPORARY TABLE \`tmp_prep_${TARGET_TABLE}\` LIKE \`${TARGET_TABLE}\`;
CREATE TEMPORARY TABLE \`tmp_orig_${TARGET_TABLE}\` LIKE \`${TARGET_TABLE}\`;

INSERT IGNORE INTO \`tmp_orig_${TARGET_TABLE}\` SELECT * FROM \`${TARGET_TABLE}\`;

ALTER TABLE \`tmp_preload_${TARGET_TABLE}\` ${UNIQ_KEYS};
ALTER TABLE \`tmp_prep_${TARGET_TABLE}\` ${UNIQ_KEYS};
ALTER TABLE \`tmp_orig_${TARGET_TABLE}\` ${UNIQ_KEYS};
"

if [ "$DEBUG" = "true" ]; then
  SQL_FLOW="$SQL_FLOW
SELECT 'original data tbl duplicated ' as status,(SELECT COUNT(1) FROM \`tmp_orig_${TARGET_TABLE}\`) as count;
"
fi

SQL_FLOW="$SQL_FLOW
ALTER TABLE \`tmp_orig_${TARGET_TABLE}\`
  ADD COLUMN row_hash BINARY(32)
      GENERATED ALWAYS AS (
        UNHEX(SHA2(
          CONCAT_WS('#', ${UPDATE_FIELDS_LIST}
  ), 256))
  ) STORED,
  ADD INDEX (row_hash);

ALTER TABLE \`tmp_preload_${TARGET_TABLE}\`
  ADD COLUMN row_hash BINARY(32)
      GENERATED ALWAYS AS (
        UNHEX(SHA2(
          CONCAT_WS('#', ${UPDATE_FIELDS_LIST}
  ), 256))
  ) STORED,
  ADD INDEX (row_hash);

LOAD DATA LOCAL INFILE '${CSV_FILE}'
    INTO TABLE \`tmp_preload_${TARGET_TABLE}\`
    FIELDS TERMINATED BY ','
    ENCLOSED BY '\"'
    LINES TERMINATED BY '\n'
    (${SQL_FIELDS_AT})
    SET ${SQL_FIELDS_SET};

SELECT 'Loaded data size ' as status,(SELECT COUNT(1) FROM \`tmp_preload_${TARGET_TABLE}\`) as count;

DELETE FROM \`${TARGET_TABLE}\` a WHERE NOT EXISTS ( SELECT 1 FROM \`tmp_preload_${TARGET_TABLE}\` t WHERE ${DELETE_KEYS} );

SELECT 'Deleted rows count ' as status,(SELECT COUNT(1) FROM \`${TARGET_TABLE}\`) as count;

INSERT INTO \`tmp_prep_${TARGET_TABLE}\`(${SQL_FIELDS}) SELECT ${SQL_FIELDS} FROM \`tmp_preload_${TARGET_TABLE}\`;

SELECT 'Prepered by keys ' as status,(SELECT COUNT(1) FROM \`tmp_prep_${TARGET_TABLE}\`) as count;
"

if [ "$DEBUG" = "true" ]; then
  SQL_FLOW="$SQL_FLOW
SELECT * FROM \`tmp_prep_${TARGET_TABLE}\` LIMIT 20;
"
fi

SQL_FLOW="$SQL_FLOW
INSERT INTO \`${TARGET_TABLE}\`(${SQL_FIELDS})
 SELECT ${SQL_FIELDS_T}
 FROM \`tmp_prep_${TARGET_TABLE}\` t ON DUPLICATE KEY
UPDATE ${UPDATE_SET};
"

echo "Executing MySQL command..."
[ "$DEBUG" = "true" ] && echo "$SQL_FLOW"

echo "$SQL_FLOW" | $MYSQL_PATH $SQL_ARGS

if [ $? -ne 0 ]; then
  echo "MySQL process failed"
  exit 1
fi

echo "Executing MySQL Done..."

# Cleanup
rm -f "$INPUT_FILE" "$OUTPUT_FILE"

echo "All done"

