#!/bin/bash
# 可选 CLI（历史）；日常与 Neovim 请用: node "$(dirname "$0")/feature-tool.js" …

set -e

FEATURE_NAV_DIR="$HOME/.feature_nav"
DB_PATH="$FEATURE_NAV_DIR/db/feature_nav.db"
SCHEMA_PATH="$FEATURE_NAV_DIR/db/schema.sql"
LOG_PATH="$FEATURE_NAV_DIR/logs/feature_nav.log"

mkdir -p "$FEATURE_NAV_DIR/db"
mkdir -p "$FEATURE_NAV_DIR/logs"
mkdir -p "$FEATURE_NAV_DIR/cache"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_PATH"
    echo "$1"
}

error() {
    log "ERROR: $1"
    exit 1
}

check_sqlite() {
    if ! command -v sqlite3 &> /dev/null; then
        error "sqlite3 is not installed. Please install it first."
    fi
}

init_db() {
    log "Initializing database..."
    check_sqlite
    
    if [ ! -f "$SCHEMA_PATH" ]; then
        error "Schema file not found: $SCHEMA_PATH"
    fi
    
    sqlite3 "$DB_PATH" < "$SCHEMA_PATH"
    
    if [ $? -eq 0 ]; then
        log "Database initialized successfully at $DB_PATH"
        
        sqlite3 "$DB_PATH" <<EOF
INSERT INTO config (key, value, description) VALUES
('version', '1.0.0', 'Database version'),
('created_at', datetime('now'), 'Creation timestamp'),
('project_path', '', 'Current project path'),
('gitnexus_analyzed', 'false', 'Whether GitNexus data has been analyzed'),
('llm_analyzed', 'false', 'Whether LLM analysis has been performed');
EOF
        
        log "Default configuration inserted"
    else
        error "Failed to initialize database"
    fi
}

export_gitnexus() {
    local project_path="${1:-$PWD}"
    
    log "Exporting GitNexus data for project: $project_path"
    
    if ! command -v npx &> /dev/null; then
        error "npx is not available. Please install Node.js first."
    fi
    
    if ! npx gitnexus --version &> /dev/null; then
        error "GitNexus is not installed. Please run: npx gitnexus analyze"
    fi
    
    local project_name=$(basename "$project_path")
    local temp_dir="$FEATURE_NAV_DIR/temp/gitnexus_export"
    mkdir -p "$temp_dir"
    
    log "Exporting communities..."
    npx gitnexus cypher -r "$project_name" "MATCH (c:Community) RETURN c.id AS id, c.label AS label, c.cohesion AS cohesion, c.symbolCount AS symbolCount ORDER BY c.symbolCount DESC" > "$temp_dir/communities.json" 2>/dev/null || {
        log "WARNING: Failed to export communities, creating empty file"
        echo "[]" > "$temp_dir/communities.json"
    }
    
    log "Exporting processes..."
    npx gitnexus cypher -r "$project_name" "MATCH (p:Process) RETURN p.id AS id, p.name AS name, p.description AS description, p.steps AS steps ORDER BY p.name" > "$temp_dir/processes.json" 2>/dev/null || {
        log "WARNING: Failed to export processes, creating empty file"
        echo "[]" > "$temp_dir/processes.json"
    }
    
    log "Exporting code elements..."
    # 导出到单独文件，然后合并
    npx gitnexus cypher -r "$project_name" "MATCH (f:Function) RETURN f.id AS id, f.name AS name, 'Function' AS kind, f.filePath AS file, f.startLine AS line, f.endLine AS endLine LIMIT 500" > "$temp_dir/symbols.json" 2>/dev/null || echo "[]" > "$temp_dir/symbols.json"
    
    # 验证并保存为 JSON 数组格式
    python3 -c "
import json
with open('$temp_dir/symbols.json', 'r') as f:
    content = f.read()
    try:
        data = json.loads(content)
        if isinstance(data, dict) and 'markdown' in data:
            print('Markdown format - needs parsing')
        elif isinstance(data, dict):
            with open('$temp_dir/symbols.json', 'w') as out:
                json.dump([data], out)
    except:
        pass
"
    
    log "Exporting File nodes..."
    npx gitnexus cypher -r "$project_name" "MATCH (f:File) RETURN f.id AS id, f.name AS name, f.filePath AS filePath LIMIT 500" > "$temp_dir/files.json" 2>/dev/null || {
        log "WARNING: Failed to export files, creating empty file"
        echo "[]" > "$temp_dir/files.json"
    }
    
    log "Exporting community-function relationships..."
    npx gitnexus cypher -r "$project_name" "MATCH (c:Community)-[:CONTAINS]->(f:Function) RETURN c.id AS community_id, f.id AS element_id, f.filePath AS file_path, f.startLine AS line LIMIT 2000" > "$temp_dir/community_elements.json" 2>/dev/null || {
        log "WARNING: Failed to export community-function relationships, creating empty file"
        echo "[]" > "$temp_dir/community_elements.json"
    }
    
    log "Exporting community-class relationships..."
    npx gitnexus cypher -r "$project_name" "MATCH (c:Community)-[:CONTAINS]->(cl:Class) RETURN c.id AS community_id, cl.id AS element_id, cl.filePath AS file_path, cl.startLine AS line LIMIT 1000" > "$temp_dir/community_classes.json" 2>/dev/null || {
        log "WARNING: Failed to export community-class relationships, creating empty file"
        echo "[]" > "$temp_dir/community_classes.json"
    }
    
    log "Parsing and inserting data into database..."
    
    sqlite3 "$DB_PATH" "UPDATE config SET value='$project_path' WHERE key='project_path'"
    sqlite3 "$DB_PATH" "UPDATE config SET value='true' WHERE key='gitnexus_analyzed'"
    
    log "GitNexus data export completed. Files saved to: $temp_dir"
    log "Note: JSON files contain raw data. Actual parsing will be implemented in next phase."
}

analyze_llm() {
    local limit="${1:-20}"
    
    log "Starting LLM analysis for top $limit communities..."
    
    if [ ! -f "$DB_PATH" ]; then
        error "Database not found. Please run 'feature-nav init' first."
    fi
    
    local communities_json=$(sqlite3 "$DB_PATH" -json <<EOF
SELECT gitnexus_id, gitnexus_label, gitnexus_cohesion, gitnexus_symbol_count
FROM gitnexus_entity 
WHERE llm_feature_name IS NULL 
ORDER BY gitnexus_symbol_count DESC 
LIMIT $limit;
EOF
)
    
    if [ -z "$communities_json" ] || [ "$communities_json" = "[]" ]; then
        log "No communities found for LLM analysis"
        return 0
    fi
    
    log "Found $(echo "$communities_json" | jq length) communities for analysis"
    
    local analysis_dir="$FEATURE_NAV_DIR/analysis"
    mkdir -p "$analysis_dir"
    
    echo "$communities_json" > "$analysis_dir/communities_to_analyze.json"
    
    log "Communities saved to: $analysis_dir/communities_to_analyze.json"
    log "LLM analysis coordination ready. Next step: Use OpenCode agent to analyze these communities."
    
    cat > "$analysis_dir/analysis_prompt.md" <<EOF
# Feature Analysis Prompt

Please analyze the following code communities and provide:

1. **Feature Name**: A concise, descriptive name for what this community implements
2. **Feature Description**: 2-3 sentences explaining the feature's purpose
3. **Core Logic Summary**: Key algorithms, patterns, or logic at the heart of this feature
4. **Primary Use Cases**: Main scenarios where this feature is used
5. **Key Components**: Important files/functions in this community

For each community below, provide analysis in this format:

## Community: [gitnexus_label]
- **Feature Name**: [name]
- **Feature Description**: [description]
- **Core Logic Summary**: [summary]
- **Primary Use Cases**: [use cases]
- **Key Components**: [components]

Communities to analyze:
$(echo "$communities_json" | jq -r '.[] | " - \(.gitnexus_label) (ID: \(.gitnexus_id), Size: \(.gitnexus_size))"')
EOF
    
    log "Analysis prompt created at: $analysis_dir/analysis_prompt.md"
    log "To proceed with LLM analysis, provide this prompt to OpenCode agent."
}

search_features() {
    local query="$1"
    
    if [ -z "$query" ]; then
        error "Search query is required. Usage: feature-nav search <query>"
    fi
    
    log "Searching for features matching: $query"
    
    sqlite3 "$DB_PATH" -json <<EOF
SELECT 
    f.id,
    COALESCE(f.llm_feature_name, f.gitnexus_label) AS name,
    f.llm_feature_description AS description,
    f.llm_core_logic_summary AS core_logic,
    f.data_sources,
    GROUP_CONCAT(DISTINCT jt.file_path || ':' || jt.line_number) AS jump_targets
FROM gitnexus_entity f
LEFT JOIN jump_targets jt ON f.id = jt.feature_id
WHERE 
    f.llm_feature_name LIKE '%$query%' OR
    f.gitnexus_label LIKE '%$query%' OR
    f.llm_feature_description LIKE '%$query%' OR
    f.llm_core_logic_summary LIKE '%$query%'
GROUP BY f.id
ORDER BY 
    CASE 
        WHEN f.llm_feature_name LIKE '%$query%' THEN 1
        WHEN f.gitnexus_label LIKE '%$query%' THEN 2
        WHEN f.llm_feature_description LIKE '%$query%' THEN 3
        ELSE 4
    END
LIMIT 20;
EOF
}

get_feature() {
    local feature_id="$1"
    
    if [ -z "$feature_id" ]; then
        error "Feature ID is required. Usage: feature-nav get <id>"
    fi
    
    log "Getting details for feature ID: $feature_id"
    
    sqlite3 "$DB_PATH" -json <<EOF
SELECT 
    f.*,
    json_group_array(
        json_object(
            'id', jt.id,
            'target_type', jt.target_type,
            'file_path', jt.file_path,
            'line_number', jt.line_number,
            'column_number', jt.column_number,
            'source', jt.source,
            'confidence', jt.confidence
        )
    ) AS jump_targets
FROM gitnexus_entity f
LEFT JOIN jump_targets jt ON f.id = jt.feature_id
WHERE f.id = '$feature_id'
GROUP BY f.id;
EOF
}

jump_to_code() {
    local feature_id="$1"
    local target_index="${2:-0}"
    
    if [ -z "$feature_id" ]; then
        error "Feature ID is required. Usage: feature-nav jump <id> [target_index]"
    fi
    
    log "Jumping to code for feature ID: $feature_id, target index: $target_index"
    
    local target=$(sqlite3 "$DB_PATH" -json <<EOF
SELECT
    file_path,
    line_number,
    column_number,
    source,
    confidence
FROM jump_targets
WHERE feature_id = '$feature_id'
ORDER BY
    CASE confidence
        WHEN 'high' THEN 1
        WHEN 'medium' THEN 2
        WHEN 'low' THEN 3
        ELSE 4
    END,
    CASE source
        WHEN 'gitnexus' THEN 1
        WHEN 'hybrid' THEN 2
        WHEN 'llm' THEN 3
        ELSE 4
    END
LIMIT 1 OFFSET $target_index;
EOF
)
    
    if [ -z "$target" ] || [ "$target" = "[]" ]; then
        error "No jump target found for feature ID: $feature_id"
    fi
    
    local file=$(echo "$target" | jq -r '.[0].file_path')
    local line=$(echo "$target" | jq -r '.[0].line_number')
    local column=$(echo "$target" | jq -r '.[0].column_number')
    local source=$(echo "$target" | jq -r '.[0].source')
    local confidence=$(echo "$target" | jq -r '.[0].confidence')
    
    if [ "$file" = "null" ] || [ -z "$file" ]; then
        error "Invalid jump target data"
    fi
    
    log "Jump target: $file:$line:$column (source: $source, confidence: $confidence)"
    
    echo "JUMP:$file:$line:$column"
}

status() {
    log "Feature Navigation System Status"
    echo "========================================"
    
    if [ -f "$DB_PATH" ]; then
        echo "Database: $DB_PATH (exists)"
        
        local feature_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM gitnexus_entity;" 2>/dev/null || echo "0")
        local jump_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM jump_targets;" 2>/dev/null || echo "0")
        local analysis_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM analysis_logs;" 2>/dev/null || echo "0")
        
        echo "Features: $feature_count"
        echo "Jump Targets: $jump_count"
        echo "Analysis Logs: $analysis_count"
        
        echo ""
        echo "Configuration:"
        sqlite3 "$DB_PATH" <<EOF
SELECT key, value, description 
FROM config 
ORDER BY key;
EOF
    else
        echo "Database: Not initialized"
    fi
    
    echo ""
    echo "Directories:"
    echo "  Base: $FEATURE_NAV_DIR"
    echo "  Database: $FEATURE_NAV_DIR/db"
    echo "  Logs: $FEATURE_NAV_DIR/logs"
    echo "  Cache: $FEATURE_NAV_DIR/cache"
}

show_help() {
    cat <<EOF
Feature Navigation System - Command Line Interface

Usage: feature-nav <command> [options]

Commands:
  init                    Initialize database
  export [project_path]   Export GitNexus data (default: current directory)
  analyze [limit]         Prepare for LLM analysis (default: 20 communities)
  search <query>          Search features
  get <id>                Get feature details
  jump <id> [index]       Jump to code (returns JUMP:file:line:column)
  status                  Show system status
  help                    Show this help message

Examples:
  feature-nav init
  feature-nav export ~/source/skilldag
  feature-nav analyze 15
  feature-nav search "authentication"
  feature-nav get 1
  feature-nav jump 1
  feature-nav status

Environment:
  Database: $DB_PATH
  Logs: $LOG_PATH
EOF
}

main() {
    local command="$1"
    
    case "$command" in
        init)
            init_db
            ;;
        export)
            export_gitnexus "$2"
            ;;
        analyze)
            analyze_llm "$2"
            ;;
        search)
            search_features "$2"
            ;;
        get)
            get_feature "$2"
            ;;
        jump)
            jump_to_code "$2" "$3"
            ;;
        status)
            status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            if [ -z "$command" ]; then
                show_help
            else
                error "Unknown command: $command. Use 'feature-nav help' for usage."
            fi
            ;;
    esac
}

main "$@"