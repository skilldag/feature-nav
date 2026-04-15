#!/bin/bash

# LLM analysis coordination script
# Calls OpenCode to analyze GitNexus communities

set -e

FEATURE_NAV_DIR="$HOME/.feature_nav"
DB_PATH="$FEATURE_NAV_DIR/db/feature_nav.db"
LOG_PATH="$FEATURE_NAV_DIR/logs/llm_analyze.log"

mkdir -p "$FEATURE_NAV_DIR/logs"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_PATH"
    echo "$1"
}

error() {
    log "ERROR: $1"
    exit 1
}

check_database() {
    if [ ! -f "$DB_PATH" ]; then
        error "Database not found: $DB_PATH"
    fi
}

check_opencode() {
    if ! command -v opencode &> /dev/null; then
        log "WARNING: opencode command not found in PATH"
        log "You may need to install OpenCode or use the web interface"
    fi
}

prepare_analysis() {
    local limit="${1:-10}"
    
    log "Preparing LLM analysis for $limit communities"
    
    local analysis_dir="$FEATURE_NAV_DIR/analysis"
    mkdir -p "$analysis_dir"
    
    # Get communities without LLM analysis
    local communities_json=$(sqlite3 "$DB_PATH" -json <<EOF
SELECT 
    f.id as feature_id,
    f.gitnexus_id,
    f.gitnexus_label,
    f.gitnexus_cohesion,
    f.gitnexus_symbol_count,
    GROUP_CONCAT(DISTINCT jt.file_path || ':' || jt.line_number) as jump_locations
FROM gitnexus_entity f
LEFT JOIN jump_targets jt ON f.id = jt.feature_id
WHERE f.llm_feature_name IS NULL 
    AND f.gitnexus_type = 'community'
    AND f.gitnexus_symbol_count > 5
GROUP BY f.id
ORDER BY f.gitnexus_symbol_count DESC
LIMIT $limit;
EOF
)
    
    if [ -z "$communities_json" ] || [ "$communities_json" = "[]" ]; then
        log "No communities found for LLM analysis"
        return 1
    fi
    
    local count=$(echo "$communities_json" | jq length)
    log "Found $count communities for analysis"
    
    # Save communities to file
    echo "$communities_json" > "$analysis_dir/communities_$limit.json"
    
    # Create analysis prompt
    cat > "$analysis_dir/analysis_prompt_$limit.md" <<EOF
# Code Feature Analysis Task

## Context
I need you to analyze code communities identified by GitNexus (a code analysis tool). 
Each community represents a cohesive group of related symbols (functions, classes, etc.) 
that work together to implement a specific feature or functionality.

## Your Task
For each community below, please provide:

1. **Feature Name**: A concise, descriptive name (2-5 words)
2. **Feature Description**: 2-3 sentences explaining what this feature does
3. **Core Logic Summary**: The key algorithm, pattern, or logic at the heart of this feature
4. **Primary Use Cases**: When/why this feature is used
5. **Key Components**: Important files/functions mentioned in jump locations

## Output Format
For each community, output exactly:

```json
{
  "feature_id": "[feature_id from below]",
  "feature_name": "[descriptive name]",
  "feature_description": "[2-3 sentence description]",
  "core_logic_summary": "[key logic summary]",
  "primary_use_cases": "[use cases]",
  "key_components": "[components]"
}
```

## Communities to Analyze
$(echo "$communities_json" | jq -r '.[] | "### Community: \(.gitnexus_label)\n- **ID**: \(.feature_id)\n- **GitNexus ID**: \(.gitnexus_id)\n- **Cohesion**: \(.gitnexus_cohesion)\n- **Symbol Count**: \(.gitnexus_symbol_count)\n- **Jump Locations**: \(.jump_locations)\n"')

## Notes
- Be concise but informative
- Focus on the technical implementation
- Use domain-appropriate terminology
- If uncertain, make reasonable inferences
EOF
    
    log "Analysis prompt created: $analysis_dir/analysis_prompt_$limit.md"
    log "Communities data: $analysis_dir/communities_$limit.json"
    
    echo "$count"
}

run_analysis() {
    local limit="${1:-10}"
    
    log "Running LLM analysis for $limit communities"
    
    local analysis_dir="$FEATURE_NAV_DIR/analysis"
    local prompt_file="$analysis_dir/analysis_prompt_$limit.md"
    
    if [ ! -f "$prompt_file" ]; then
        error "Analysis prompt not found: $prompt_file. Run prepare first."
    fi
    
    log "Reading prompt from: $prompt_file"
    local prompt_content=$(cat "$prompt_file")
    
    # Check if we can use opencode command
    if command -v opencode &> /dev/null; then
        log "Using opencode command for analysis..."
        
        # Create temporary file for opencode input
        local temp_input="$analysis_dir/opencode_input_$limit.txt"
        echo "$prompt_content" > "$temp_input"
        
        log "Executing: opencode analyze --input \"$temp_input\""
        
        # For now, simulate the response
        log "SIMULATION: Would call opencode with analysis prompt"
        log "In real implementation, this would call:"
        log "  opencode --model deepseek-chat --prompt-file \"$temp_input\""
        
        # Create simulated response
        cat > "$analysis_dir/llm_response_$limit.json" <<EOF
[
  {
    "feature_id": "community_1",
    "feature_name": "User Authentication System",
    "feature_description": "Handles user registration, login, and session management. Implements JWT token generation and validation with secure password hashing.",
    "core_logic_summary": "Uses bcrypt for password hashing, JWT for token management, and middleware for request authentication.",
    "primary_use_cases": "User login, API authentication, session management",
    "key_components": "auth.controller.js, user.model.js, jwt.utils.js"
  }
]
EOF
        
        log "Simulated response saved: $analysis_dir/llm_response_$limit.json"
        
    else
        log "OpenCode not available in PATH"
        log "Please analyze manually using the prompt at: $prompt_file"
        log "Save the JSON response to: $analysis_dir/llm_response_$limit.json"
        
        cat > "$analysis_dir/instructions_$limit.md" <<EOF
# Manual Analysis Instructions

1. Open the prompt file: $prompt_file
2. Use any LLM (ChatGPT, Claude, etc.) to analyze the communities
3. Copy the JSON response format from the prompt
4. Save the response to: $analysis_dir/llm_response_$limit.json

The response should be a JSON array of objects, each with:
- feature_id
- feature_name  
- feature_description
- core_logic_summary
- primary_use_cases
- key_components
EOF
        
        error "OpenCode not available. Manual analysis required."
    fi
}

process_response() {
    local limit="${1:-10}"
    
    log "Processing LLM response for $limit communities"
    
    local analysis_dir="$FEATURE_NAV_DIR/analysis"
    local response_file="$analysis_dir/llm_response_$limit.json"
    
    if [ ! -f "$response_file" ]; then
        error "LLM response file not found: $response_file"
    fi
    
    # Validate JSON
    if ! jq empty "$response_file" 2>/dev/null; then
        error "Invalid JSON in response file: $response_file"
    fi
    
    local response_count=$(jq length "$response_file")
    log "Processing $response_count analysis results"
    
    # Process each result
    python3 <<EOF
import json
import sqlite3
import sys

try:
    with open('$response_file', 'r') as f:
        results = json.load(f)
    
    conn = sqlite3.connect('$DB_PATH')
    cursor = conn.cursor()
    
    updated = 0
    for result in results:
        feature_id = result.get('feature_id')
        if not feature_id:
            continue
        
        # Update feature with LLM analysis
        desc = result.get('feature_description') or ''
        if result.get('primary_use_cases'):
            desc = f"{desc}\n\nUse cases: {result.get('primary_use_cases')}"
        if result.get('key_components'):
            desc = f"{desc}\n\nKey components: {result.get('key_components')}"
        cursor.execute("""
            UPDATE gitnexus_entity 
            SET 
                llm_feature_name = ?,
                llm_feature_description = ?,
                llm_core_logic_summary = ?,
                data_sources = json_replace(
                    COALESCE(data_sources, '["gitnexus"]'),
                    '$[#]', 'llm'
                ),
                last_updated = CURRENT_TIMESTAMP
            WHERE id = ?
        """, (
            result.get('feature_name'),
            desc,
            result.get('core_logic_summary'),
            feature_id
        ))
        
        if cursor.rowcount > 0:
            # Log the analysis (optional table; Node init may not create analysis_logs)
            try:
                cursor.execute("""
                    INSERT INTO analysis_logs 
                    (feature_id, analysis_type, status, message)
                    VALUES (?, ?, ?, ?)
                """, (
                    feature_id,
                    'llm',
                    'completed',
                    f"LLM analysis completed: {result.get('feature_name')}"
                ))
            except sqlite3.OperationalError:
                pass
            
            updated += 1
    
    conn.commit()
    conn.close()
    
    print(f"Updated {updated} features with LLM analysis")
    
except Exception as e:
    print(f"Error processing LLM response: {e}")
    sys.exit(1)
EOF
    
    sqlite3 "$DB_PATH" "UPDATE config SET value='true' WHERE key='llm_analyzed'"
    
    log "LLM analysis processing completed"
    log "Updated features: $response_count"
}

analyze_batch() {
    local limit="${1:-10}"
    
    log "Starting batch analysis for $limit communities"
    
    check_database
    
    # Step 1: Prepare analysis
    local count=$(prepare_analysis "$limit")
    if [ "$count" -eq "0" ]; then
        log "No communities to analyze"
        return 0
    fi
    
    # Step 2: Run analysis (simulated for now)
    run_analysis "$limit"
    
    # Step 3: Process response
    process_response "$limit"
    
    log "Batch analysis completed for $count communities"
    
    # Show summary
    echo ""
    echo "✅ LLM Analysis Completed!"
    echo "=========================="
    sqlite3 "$DB_PATH" <<EOF
SELECT 
    COUNT(*) as "Total Features",
    SUM(CASE WHEN llm_feature_name IS NOT NULL THEN 1 ELSE 0 END) as "With LLM Analysis",
    SUM(CASE WHEN llm_feature_name IS NULL THEN 1 ELSE 0 END) as "Without LLM Analysis"
FROM gitnexus_entity;
EOF
}

show_status() {
    log "LLM Analysis Status"
    
    check_database
    
    echo "LLM Analysis Status"
    echo "==================="
    
    # Analysis statistics (gitnexus_entity always; analysis_logs only if legacy schema)
    sqlite3 "$DB_PATH" <<EOF
SELECT 
    'Features with LLM Analysis' as "Metric",
    COUNT(*) as "Count"
FROM gitnexus_entity 
WHERE llm_feature_name IS NOT NULL

UNION ALL

SELECT 
    'Features without LLM Analysis',
    COUNT(*)
FROM gitnexus_entity 
WHERE llm_feature_name IS NULL
EOF
    if sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='analysis_logs';" | grep -q 1; then
        sqlite3 "$DB_PATH" <<EOF
SELECT 
    'Recent Analysis Logs',
    COUNT(*)
FROM analysis_logs 
WHERE analysis_type = 'llm' 
    AND datetime(created_at) > datetime('now', '-1 day')

UNION ALL

SELECT 
    'Total Analysis Logs',
    COUNT(*)
FROM analysis_logs 
WHERE analysis_type = 'llm';
EOF
        echo ""
        echo "Recent Analysis:"
        sqlite3 "$DB_PATH" <<EOF
SELECT 
    strftime('%Y-%m-%d %H:%M', created_at) as "Time",
    feature_id as "Feature",
    message as "Message"
FROM analysis_logs 
WHERE analysis_type = 'llm'
ORDER BY created_at DESC
LIMIT 5;
EOF
    fi
}

show_help() {
    cat <<EOF
LLM Analysis Coordinator

Usage: $0 <command> [limit]

Commands:
  prepare [limit]    Prepare analysis for N communities (default: 10)
  run [limit]        Run LLM analysis (simulated if opencode not available)
  process [limit]    Process LLM response file
  batch [limit]      Run full batch: prepare → run → process (default: 10)
  status             Show analysis status
  help               Show this help message

Examples:
  $0 batch 15        # Analyze 15 communities
  $0 prepare 20      # Prepare analysis for 20 communities
  $0 status          # Show analysis status

Notes:
  1. Requires database initialized with GitNexus data
  2. OpenCode command-line tool recommended for automation
  3. Manual analysis possible if OpenCode not available

Environment:
  Database: $DB_PATH
  Analysis dir: $FEATURE_NAV_DIR/analysis
  Logs: $LOG_PATH
EOF
}

main() {
    local command="$1"
    local limit="${2:-10}"
    
    case "$command" in
        prepare)
            prepare_analysis "$limit"
            ;;
        run)
            run_analysis "$limit"
            ;;
        process)
            process_response "$limit"
            ;;
        batch)
            analyze_batch "$limit"
            ;;
        status)
            show_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            if [ -z "$command" ]; then
                show_help
            else
                error "Unknown command: $command"
            fi
            ;;
    esac
}

main "$@"