#!/bin/bash

# Database initialization script
# Can be called independently or via feature-nav init

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEATURE_NAV_DIR="$HOME/.feature_nav"
DB_PATH="$FEATURE_NAV_DIR/db/feature_nav.db"
FEATURE_TOOL_JS="$SCRIPT_DIR/feature-tool.js"
LOG_PATH="$FEATURE_NAV_DIR/logs/db_init.log"

mkdir -p "$FEATURE_NAV_DIR/db"
mkdir -p "$FEATURE_NAV_DIR/logs"

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

check_node_tool() {
    if ! command -v node &> /dev/null; then
        error "node is required (same schema as feature-tool.js / Neovim)"
    fi
    if [ ! -f "$FEATURE_TOOL_JS" ]; then
        error "feature-tool.js not found: $FEATURE_TOOL_JS"
    fi
}

init_database() {
    log "Initializing database via Node feature-tool.js init (same schema as Neovim)..."
    check_node_tool
    
    log "Creating database at: $DB_PATH"
    local out
    out=$(node "$FEATURE_TOOL_JS" init) || error "node feature-tool.js init failed"
    echo "$out"
    if ! echo "$out" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
        error "init did not return success"
    fi
    
    check_sqlite
    local table_count
    table_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';")
    local config_count
    config_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM config;")
    log "Created $table_count tables, $config_count config row(s)"
    log "Database initialized successfully"
    log "Location: $DB_PATH"
    log "Size: $(du -h "$DB_PATH" | cut -f1)"
    
    echo "✅ Feature navigation database initialized successfully!"
    echo "   Database: $DB_PATH"
    echo "   Tables: $table_count"
    echo "   Config entries: $config_count"
}

verify_database() {
    log "Verifying database structure..."
    
    if [ ! -f "$DB_PATH" ]; then
        error "Database file not found: $DB_PATH"
    fi
    
    # Check required tables
    # Align with feature-tool.js (Node): gitnexus_entity, jump_targets, symbols_cache, label_annotations, config, process_steps
    local required_tables=("gitnexus_entity" "jump_targets" "symbols_cache" "label_annotations" "config" "process_steps")
    local missing_tables=()
    
    for table in "${required_tables[@]}"; do
        if ! sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';" | grep -q "$table"; then
            missing_tables+=("$table")
        fi
    done
    
    if [ ${#missing_tables[@]} -eq 0 ]; then
        log "✅ All required tables exist"
        
        # Show table row counts
        echo "Database verification successful:"
        echo "================================"
        for table in "${required_tables[@]}"; do
            local count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo "0")
            echo "  $table: $count rows"
        done
    else
        error "Missing tables: ${missing_tables[*]}"
    fi
}

backup_database() {
    local backup_dir="$FEATURE_NAV_DIR/backups"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="$backup_dir/feature_nav_${timestamp}.db"
    
    mkdir -p "$backup_dir"
    
    if [ ! -f "$DB_PATH" ]; then
        error "Database file not found: $DB_PATH"
    fi
    
    log "Backing up database to: $backup_file"
    cp "$DB_PATH" "$backup_file"
    
    if [ $? -eq 0 ]; then
        log "Backup created successfully"
        echo "✅ Database backed up to: $backup_file"
        echo "   Size: $(du -h "$backup_file" | cut -f1)"
    else
        error "Failed to create backup"
    fi
}

show_help() {
    cat <<EOF
Feature Navigation Database Management

Usage: $0 <command>

Commands:
  init      Initialize new database (destroys existing data)
  verify    Verify database structure and integrity
  backup    Create backup of current database
  help      Show this help message

Examples:
  $0 init    # Initialize new database
  $0 verify  # Verify database structure
  $0 backup  # Create backup

Environment:
  Database: $DB_PATH
  Schema: defined in feature-tool.js (initDatabase)
  Logs: $LOG_PATH
EOF
}

main() {
    local command="$1"
    
    case "$command" in
        init)
            init_database
            ;;
        verify)
            verify_database
            ;;
        backup)
            backup_database
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