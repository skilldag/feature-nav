#!/bin/bash

# Neovim integration script for feature-nav
# Provides commands that Neovim can call via system()

set -e

FEATURE_NAV_DIR="$HOME/.feature_nav"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PATH="$FEATURE_NAV_DIR/logs/nvim_integration.log"

mkdir -p "$FEATURE_NAV_DIR/logs"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_PATH"
}

# Execute feature-nav command
execute_command() {
    local command="$1"
    shift
    local args="$@"
    
    log "Executing: feature-nav $command $args"
    
    # Call the main feature-nav script
    "$SCRIPT_DIR/feature-nav.sh" "$command" "$@"
}

# Initialize database
init_db() {
    log "Initializing database via Neovim"
    execute_command "init"
}

# Export GitNexus data
export_gitnexus() {
    local project_path="${1:-$PWD}"
    log "Exporting GitNexus data for: $project_path"
    execute_command "export" "$project_path"
}

# Parse GitNexus data
parse_gitnexus() {
    local data_dir="${1:-$FEATURE_NAV_DIR/temp/gitnexus_export}"
    log "Parsing GitNexus data from: $data_dir"
    
    if [ ! -d "$data_dir" ]; then
        echo "ERROR: Data directory not found: $data_dir"
        return 1
    fi
    
    "$SCRIPT_DIR/parse-gitnexus.sh" "parse-all" "$data_dir"
}

# Analyze with LLM
analyze_llm() {
    local limit="${1:-10}"
    log "Analyzing $limit communities with LLM"
    "$SCRIPT_DIR/llm-analyze.sh" "batch" "$limit"
}

# Search features (returns JSON)
search_features() {
    local query="$1"
    log "Searching features: $query"
    execute_command "search" "$query"
}

# Get feature details (returns JSON)
get_feature() {
    local feature_id="$1"
    log "Getting feature: $feature_id"
    execute_command "get" "$feature_id"
}

# Jump to code (returns JUMP:file:line:column)
jump_to_code() {
    local feature_id="$1"
    local target_index="${2:-0}"
    log "Jumping to feature: $feature_id, index: $target_index"
    execute_command "jump" "$feature_id" "$target_index"
}

# Get system status
get_status() {
    log "Getting system status"
    execute_command "status"
}

# Refresh all data (export + parse + analyze)
refresh_all() {
    local project_path="${1:-$PWD}"
    local limit="${2:-10}"
    
    log "Refreshing all data for: $project_path, limit: $limit"
    
    echo "Starting full refresh..."
    echo "1. Exporting GitNexus data..."
    export_gitnexus "$project_path"
    
    echo "2. Parsing GitNexus data..."
    parse_gitnexus
    
    echo "3. Analyzing with LLM..."
    analyze_llm "$limit"
    
    echo "✅ Refresh completed!"
}

# Quick setup (init + export + parse)
quick_setup() {
    local project_path="${1:-$PWD}"
    
    log "Quick setup for: $project_path"
    
    echo "Setting up feature navigation..."
    echo "1. Initializing database..."
    init_db
    
    echo "2. Exporting GitNexus data..."
    export_gitnexus "$project_path"
    
    echo "3. Parsing data..."
    parse_gitnexus
    
    echo "✅ Setup completed! Run 'analyze_llm' for LLM analysis."
}

# Show help
show_help() {
    cat <<EOF
Feature Navigation Neovim Integration

Usage: $0 <command> [args]

Commands:
  init                     Initialize database
  export [path]            Export GitNexus data (default: current dir)
  parse [dir]              Parse GitNexus JSON files
  analyze [limit]          LLM analysis (default: 10 communities)
  search <query>           Search features (JSON output)
  get <id>                 Get feature details (JSON output)
  jump <id> [index]        Jump to code (JUMP:file:line:column)
  status                   System status
  refresh [path] [limit]   Full refresh: export + parse + analyze
  setup [path]             Quick setup: init + export + parse
  help                     Show this help

Neovim Integration Examples:
  :call system('$0 search authentication')  # Search features
  :call system('$0 jump feature_123')       # Jump to code
  :call system('$0 refresh ~/myproject 15') # Full refresh

Environment:
  Scripts: $SCRIPT_DIR
  Database: $FEATURE_NAV_DIR/db/feature_nav.db
  Logs: $LOG_PATH
EOF
}

# Main dispatcher
main() {
    local command="$1"
    
    case "$command" in
        init)
            init_db
            ;;
        export)
            export_gitnexus "$2"
            ;;
        parse)
            parse_gitnexus "$2"
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
            get_status
            ;;
        refresh)
            refresh_all "$2" "$3"
            ;;
        setup)
            quick_setup "$2"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            if [ -z "$command" ]; then
                show_help
            else
                echo "ERROR: Unknown command: $command"
                exit 1
            fi
            ;;
    esac
}

main "$@"