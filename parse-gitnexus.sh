#!/bin/bash

set -e

FEATURE_NAV_DIR="$HOME/.feature_nav"
DB_PATH="$FEATURE_NAV_DIR/db/feature_nav.db"
LOG_PATH="$FEATURE_NAV_DIR/logs/parse_gitnexus.log"

mkdir -p "$FEATURE_NAV_DIR/logs"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_PATH"
    echo "$1"
}

error() {
    log "ERROR: $1"
    exit 1
}

check_dependencies() {
    if ! command -v sqlite3 &> /dev/null; then
        error "sqlite3 is not installed"
    fi
    
    if ! command -v python3 &> /dev/null; then
        error "python3 is not installed"
    fi
}

check_database() {
    if [ ! -f "$DB_PATH" ]; then
        error "Database not found: $DB_PATH"
    fi
}

parse_markdown_table() {
    local json_file="$1"
    
    python3 <<EOF
import json
import re
import sys

def parse_markdown_to_json(content):
    lines = content.strip().split('\n')
    
    # Find header line (contains |)
    header_idx = None
    for i, line in enumerate(lines):
        if line.strip().startswith('|') and '---' not in line:
            header_idx = i
            break
    
    if header_idx is None:
        return []
    
    # Parse header
    header_line = lines[header_idx]
    headers = [h.strip() for h in header_line.split('|')[1:-1]]
    
    # Skip separator line
    data_start = header_idx + 2
    
    # Parse data rows
    results = []
    for line in lines[data_start:]:
        if not line.strip().startswith('|'):
            continue
        
        cells = [c.strip() for c in line.split('|')[1:-1]]
        
        if len(cells) != len(headers):
            continue
        
        row = {}
        for i, header in enumerate(headers):
            row[header] = cells[i]
        
        results.append(row)
    
    return results

# Read from file
with open('$json_file', 'r') as f:
    content = f.read()

# Try to parse as JSON first
try:
    data = json.loads(content)
    if isinstance(data, dict) and 'markdown' in data:
        # Extract from markdown wrapper
        content = data['markdown']
    elif isinstance(data, list):
        print(json.dumps(data))
        sys.exit(0)
except:
    pass

# Parse markdown table
results = parse_markdown_to_json(content)
print(json.dumps(results))
EOF
}

parse_communities() {
    local json_file="$1"
    
    if [ ! -f "$json_file" ]; then
        error "Communities file not found: $json_file"
    fi
    
    log "Parsing communities from: $json_file"
    
    python3 <<EOF
import json
import re
import sqlite3
import sys

with open('$json_file', 'r') as f:
    content = f.read()

# Extract markdown from JSON wrapper
try:
    data = json.loads(content)
    if isinstance(data, dict) and 'markdown' in data:
        content = data['markdown']
except:
    pass

# Extract markdown table
lines = content.strip().split('\n')

# Parse header
header_line = None
for line in lines:
    if line.strip().startswith('|') and '---' not in line:
        header_line = line
        break

if not header_line:
    print("No header found")
    sys.exit(1)

headers = [h.strip() for h in header_line.split('|')[1:-1]]
print(f"Headers: {headers}", file=sys.stderr)

# Parse data rows
results = []
data_start = False
for line in lines:
    if '---' in line:
        data_start = True
        continue
    if not data_start or not line.strip().startswith('|'):
        continue
    
    cells = [c.strip() for c in line.split('|')[1:-1]]
    if len(cells) != len(headers):
        continue
    
    row = {}
    for i, header in enumerate(headers):
        row[header] = cells[i]
    results.append(row)

print(f"Found {len(results)} communities", file=sys.stderr)

# Insert into database
conn = sqlite3.connect('$DB_PATH')
cursor = conn.cursor()

inserted = 0
for community in results:
    community_id = f"community_{community.get('id', 'unknown')}"
    
    # Check if already exists
    cursor.execute("SELECT id FROM gitnexus_entity WHERE gitnexus_id = ? AND gitnexus_type = 'community'", 
                  (community.get('id'),))
    if cursor.fetchone():
        continue
    
    # Parse symbolCount
    symbol_count = 0
    try:
        symbol_count = int(community.get('symbolCount', 0))
    except:
        pass
    
    # Parse cohesion
    cohesion = 0.0
    try:
        cohesion = float(community.get('cohesion', 0))
    except:
        pass
    
    cursor.execute("""
        INSERT INTO gitnexus_entity (
            id, gitnexus_id, gitnexus_label, gitnexus_cohesion, 
            gitnexus_symbol_count, gitnexus_type, data_sources
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
    """, (
        community_id,
        community.get('id'),
        community.get('label', 'Unnamed'),
        cohesion,
        symbol_count,
        'community',
        '["gitnexus"]'
    ))
    
    inserted += 1

conn.commit()
conn.close()

print(f"Inserted {inserted} communities")
EOF
}

parse_processes() {
    local json_file="$1"
    
    if [ ! -f "$json_file" ]; then
        log "Processes file not found: $json_file (skipping)"
        return 0
    fi
    
    log "Parsing processes from: $json_file"
    
    python3 <<EOF
import json
import re
import sqlite3
import sys

with open('$json_file', 'r') as f:
    content = f.read()

# Check if empty
if '"row_count": 0' in content or content.strip() == '[]':
    print("No processes to parse")
    sys.exit(0)

# Extract markdown table
lines = content.strip().split('\n')

header_line = None
for line in lines:
    if line.strip().startswith('|') and '---' not in line:
        header_line = line
        break

if not header_line:
    print("No processes found")
    sys.exit(0)

headers = [h.strip() for h in header_line.split('|')[1:-1]]

results = []
data_start = False
for line in lines:
    if '---' in line:
        data_start = True
        continue
    if not data_start or not line.strip().startswith('|'):
        continue
    
    cells = [c.strip() for c in line.split('|')[1:-1]]
    if len(cells) != len(headers):
        continue
    
    row = {}
    for i, header in enumerate(headers):
        row[header] = cells[i]
    results.append(row)

print(f"Found {len(results)} processes", file=sys.stderr)

conn = sqlite3.connect('$DB_PATH')
cursor = conn.cursor()

inserted = 0
for process in results:
    process_id = f"process_{process.get('id', 'unknown')}"
    
    cursor.execute("SELECT id FROM gitnexus_entity WHERE gitnexus_id = ? AND gitnexus_type = 'process'", 
                  (process.get('id'),))
    if cursor.fetchone():
        continue
    
    cursor.execute("""
        INSERT INTO gitnexus_entity (
            id, gitnexus_id, gitnexus_label, gitnexus_type, data_sources
        ) VALUES (?, ?, ?, ?, ?)
    """, (
        process_id,
        process.get('id'),
        process.get('name', 'Unnamed Process'),
        'process',
        '["gitnexus"]'
    ))
    
    inserted += 1

conn.commit()
conn.close()

print(f"Inserted {inserted} processes")
EOF
}

parse_symbols() {
    local json_file="$1"
    
    if [ ! -f "$json_file" ]; then
        log "Symbols file not found: $json_file (skipping)"
        return 0
    fi
    
    log "Parsing symbols from: $json_file"
    
    python3 <<EOF
import json
import re
import sqlite3
import sys

with open('$json_file', 'r') as f:
    content = f.read()

if not content.strip() or content.strip() == '[]':
    print("No symbols to parse")
    sys.exit(0)

# Check if wrapped in markdown
if '"markdown":' in content:
    # Parse the JSON wrapper
    data = json.loads(content)
    content = data.get('markdown', '')

# Extract markdown table
lines = content.strip().split('\n')

header_line = None
for line in lines:
    if line.strip().startswith('|') and '---' not in line:
        header_line = line
        break

if not header_line:
    print("No symbols found")
    sys.exit(0)

headers = [h.strip() for h in header_line.split('|')[1:-1]]

results = []
data_start = False
for line in lines:
    if '---' in line:
        data_start = True
        continue
    if not data_start or not line.strip().startswith('|'):
        continue
    
    cells = [c.strip() for c in line.split('|')[1:-1]]
    if len(cells) != len(headers):
        continue
    
    row = {}
    for i, header in enumerate(headers):
        row[header] = cells[i]
    results.append(row)

print(f"Found {len(results)} symbols", file=sys.stderr)

conn = sqlite3.connect('$DB_PATH')
cursor = conn.cursor()

# Create cache table
cursor.execute("""
    CREATE TABLE IF NOT EXISTS symbols_cache (
        symbol_id TEXT PRIMARY KEY,
        symbol_name TEXT,
        symbol_kind TEXT,
        file_path TEXT,
        line_number INTEGER,
        column_number INTEGER,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
""")

inserted = 0
for symbol in results:
    symbol_id = symbol.get('id')
    if not symbol_id:
        continue
    
    # Parse line number
    line_number = 0
    try:
        line_number = int(symbol.get('line', 0))
    except:
        pass
    
    cursor.execute("""
        INSERT OR REPLACE INTO symbols_cache 
        (symbol_id, symbol_name, symbol_kind, file_path, line_number, column_number)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (
        symbol_id,
        symbol.get('name', ''),
        symbol.get('kind', ''),
        symbol.get('file', ''),
        line_number,
        0
    ))
    
    inserted += 1

conn.commit()
conn.close()

print(f"Cached {inserted} symbols")
EOF
}

parse_community_symbols() {
    local json_file="$1"
    
    if [ ! -f "$json_file" ]; then
        log "Community symbols file not found: $json_file (skipping)"
        return 0
    fi
    
    log "Parsing community-symbol relationships from: $json_file"
    
    python3 <<EOF
import json
import re
import sqlite3
import sys

with open('$json_file', 'r') as f:
    content = f.read()

if not content.strip() or '"row_count": 0' in content:
    print("No community-symbol relationships")
    sys.exit(0)

# Check if wrapped in markdown
if '"markdown":' in content:
    data = json.loads(content)
    content = data.get('markdown', '')

lines = content.strip().split('\n')

header_line = None
for line in lines:
    if line.strip().startswith('|') and '---' not in line:
        header_line = line
        break

if not header_line:
    print("No relationships found")
    sys.exit(0)

headers = [h.strip() for h in header_line.split('|')[1:-1]]

results = []
data_start = False
for line in lines:
    if '---' in line:
        data_start = True
        continue
    if not data_start or not line.strip().startswith('|'):
        continue
    
    cells = [c.strip() for c in line.split('|')[1:-1]]
    if len(cells) != len(headers):
        continue
    
    row = {}
    for i, header in enumerate(headers):
        row[header] = cells[i]
    results.append(row)

print(f"Found {len(results)} relationships", file=sys.stderr)

conn = sqlite3.connect('$DB_PATH')
cursor = conn.cursor()

# Get symbol file paths from cache
cursor.execute("SELECT symbol_id, file_path, line_number FROM symbols_cache")
symbol_cache = {row[0]: (row[1], row[2]) for row in cursor.fetchall()}

inserted = 0
for rel in results:
    community_id = rel.get('community_id')
    symbol_id = rel.get('symbol_id')
    
    if not community_id or not symbol_id:
        continue
    
    cursor.execute("SELECT id FROM gitnexus_entity WHERE gitnexus_id = ? AND gitnexus_type = 'community'", 
                  (community_id,))
    feature_row = cursor.fetchone()
    if not feature_row:
        continue
    
    feature_id = feature_row[0]
    
    symbol_location = symbol_cache.get(symbol_id)
    if not symbol_location:
        continue
    
    file_path, line_number = symbol_location
    
    if not file_path or not line_number:
        continue
    
    cursor.execute("""
        INSERT OR IGNORE INTO jump_targets 
        (feature_id, target_type, file_path, line_number, source, confidence)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (
        feature_id,
        'symbol',
        file_path,
        line_number,
        'gitnexus',
        'high'
    ))
    
    inserted += 1

conn.commit()
conn.close()

print(f"Created {inserted} jump targets")
EOF
}

parse_process_steps() {
    local json_file="$1"
    
    if [ ! -f "$json_file" ]; then
        log "Process steps file not found: $json_file (skipping)"
        return 0
    fi
    
    log "Parsing process-step relationships from: $json_file"
    
    python3 <<EOF
import json
import re
import sqlite3
import sys

with open('$json_file', 'r') as f:
    content = f.read()

if not content.strip() or '"row_count": 0' in content:
    print("No process-step relationships")
    sys.exit(0)

# Check if wrapped in markdown
if '"markdown":' in content:
    data = json.loads(content)
    content = data.get('markdown', '')

lines = content.strip().split('\n')

header_line = None
for line in lines:
    if line.strip().startswith('|') and '---' not in line:
        header_line = line
        break

if not header_line:
    print("No process-step relationships found")
    sys.exit(0)

headers = [h.strip() for h in header_line.split('|')[1:-1]]

results = []
data_start = False
for line in lines:
    if '---' in line:
        data_start = True
        continue
    if not data_start or not line.strip().startswith('|'):
        continue
    
    cells = [c.strip() for c in line.split('|')[1:-1]]
    if len(cells) != len(headers):
        continue
    
    row = {}
    for i, header in enumerate(headers):
        row[header] = cells[i]
    results.append(row)

print(f"Found {len(results)} process-step relationships", file=sys.stderr)

conn = sqlite3.connect('$DB_PATH')
cursor = conn.cursor()

cursor.execute("SELECT symbol_id, file_path, line_number FROM symbols_cache")
symbol_cache = {row[0]: (row[1], row[2]) for row in cursor.fetchall()}

inserted = 0
for rel in results:
    process_id = rel.get('process_id')
    symbol_id = rel.get('symbol_id')
    
    if not process_id or not symbol_id:
        continue
    
    cursor.execute("SELECT id FROM gitnexus_entity WHERE gitnexus_id = ? AND gitnexus_type = 'process'", 
                  (process_id,))
    feature_row = cursor.fetchone()
    if not feature_row:
        continue
    
    feature_id = feature_row[0]
    
    symbol_location = symbol_cache.get(symbol_id)
    if not symbol_location:
        continue
    
    file_path, line_number = symbol_location
    
    if not file_path or not line_number:
        continue
    
    cursor.execute("""
        INSERT OR IGNORE INTO jump_targets 
        (feature_id, target_type, file_path, line_number, source, confidence)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (
        feature_id,
        'process',
        file_path,
        line_number,
        'gitnexus',
        'high'
    ))
    
    inserted += 1

conn.commit()
conn.close()

print(f"Created {inserted} process jump targets")
EOF
}

parse_all() {
    local data_dir="${1:-$FEATURE_NAV_DIR/temp/gitnexus_export}"
    
    if [ ! -d "$data_dir" ]; then
        error "Data directory not found: $data_dir"
    fi
    
    log "Parsing all GitNexus data from: $data_dir"
    
    check_dependencies
    check_database
    
    parse_communities "$data_dir/communities.json"
    parse_processes "$data_dir/processes.json"
    parse_symbols "$data_dir/symbols.json"
    parse_community_symbols "$data_dir/community_symbols.json"
    parse_process_steps "$data_dir/process_steps.json"
    
    sqlite3 "$DB_PATH" <<EOF
INSERT INTO analysis_logs (feature_id, analysis_type, status, message)
VALUES ('system', 'gitnexus', 'completed', 'GitNexus data parsed');
EOF
    
    log "GitNexus data parsing completed"
    
    echo ""
    echo "✅ Parsing completed!"
    echo "===================="
    sqlite3 -header -column "$DB_PATH" <<EOF
SELECT 
    gitnexus_type as "Type",
    COUNT(*) as "Count"
FROM gitnexus_entity 
GROUP BY gitnexus_type;
EOF
    
    echo ""
    echo "Jump targets:"
    sqlite3 -header -column "$DB_PATH" <<EOF
SELECT 
    target_type as "Type",
    COUNT(*) as "Count"
FROM jump_targets 
GROUP BY target_type;
EOF
}

show_help() {
    cat <<EOF
GitNexus Data Parser

Usage: $0 <command> [data_directory]

Commands:
  parse-all [dir]    Parse all GitNexus JSON files
  help               Show help
EOF
}

main() {
    local command="$1"
    local arg="${2:-}"
    
    case "$command" in
        parse-all)
            parse_all "$arg"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            show_help
            ;;
    esac
}

main "$@"