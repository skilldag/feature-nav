#!/usr/bin/env python3
"""
Feature Navigation Tool for LLM
==============================
A reliable tool for LLM to query GitNexus data and manage feature navigation.

Usage:
    feature_tool.py <command> [args...]

Commands:
    sync <repo_path>      init + export + parse in one command
    label                  List all labels
    label --next           Get next unlabeled label
    label <name>           Get label details
    label --init          Initialize label table
    save-label <label> <json>  Save label annotation
    annotate <id>        Annotate single feature (LLM analysis)
    annotate --batch N   Annotate N features (LLM analysis)
    annotate --next      Annotate next unannotated feature
    annotate --status   Show annotation status
    export <repo_path>     Export GitNexus data for a repository
    parse                  Parse exported data into database
    search <query>        Search features by query
    get <feature_id>      Get feature details
    jump <feature_id>     Get code jump location
    status                Show system status

Examples:
    feature_tool.py sync ~/source/skilldag
    feature_tool.py annotate community_comm_161
    feature_tool.py annotate --batch 5
    feature_tool.py annotate --next
    feature_tool.py search clustering
    feature_tool.py get community_comm_161
    feature_tool.py jump process_proc_5_main
"""

import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

# Configuration
FEATURE_NAV_DIR = Path.home() / ".feature_nav"
DB_PATH = FEATURE_NAV_DIR / "db" / "feature_nav.db"
TEMP_DIR = FEATURE_NAV_DIR / "temp" / "gitnexus_export"
LOG_PATH = FEATURE_NAV_DIR / "logs" / "tool.log"

# Ensure directories exist
FEATURE_NAV_DIR.mkdir(parents=True, exist_ok=True)
(DB_PATH.parent).mkdir(parents=True, exist_ok=True)
TEMP_DIR.mkdir(parents=True, exist_ok=True)


def log(message: str, level: str = "INFO"):
    """Simple logging"""
    msg = f"[{level}] {message}"
    print(msg)
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_PATH, "a") as f:
        f.write(f"{msg}\n")


def run_command(cmd: list, cwd: str = None) -> tuple:
    """Run shell command and return (stdout, stderr, returncode)"""
    try:
        result = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=120
        )
        return result.stdout, result.stderr, result.returncode
    except Exception as e:
        return "", str(e), 1


def init_database() -> dict:
    """Initialize SQLite database"""
    if DB_PATH.exists():
        DB_PATH.unlink()

    schema = """
    CREATE TABLE IF NOT EXISTS gitnexus_entity (
        id TEXT PRIMARY KEY,
        gitnexus_id TEXT NOT NULL,
        gitnexus_label TEXT,
        gitnexus_type TEXT CHECK(gitnexus_type IN ('community', 'process')),
        gitnexus_symbol_count INTEGER,
        gitnexus_cohesion REAL,
        gitnexus_step_count INTEGER,
        llm_feature_name TEXT,
        llm_feature_description TEXT,
        llm_core_logic_summary TEXT,
        data_sources TEXT,
        last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS jump_targets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        feature_id TEXT NOT NULL,
        target_type TEXT,
        file_path TEXT,
        line_number INTEGER,
        source TEXT,
        confidence TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (feature_id) REFERENCES gitnexus_entity(id)
    );

    CREATE TABLE IF NOT EXISTS symbols_cache (
        symbol_id TEXT PRIMARY KEY,
        symbol_name TEXT,
        file_path TEXT,
        line_number INTEGER,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS config (
        key TEXT PRIMARY KEY,
        value TEXT,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE INDEX IF NOT EXISTS idx_gitnexus_entity_type ON gitnexus_entity(gitnexus_type);
    CREATE INDEX IF NOT EXISTS idx_gitnexus_entity_label ON gitnexus_entity(gitnexus_label);
    CREATE INDEX IF NOT EXISTS idx_jump_targets ON jump_targets(feature_id);
    """

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.executescript(schema)

    # Default config
    cursor.execute(
        "INSERT INTO config (key, value) VALUES (?, ?)", ("version", "1.0.0")
    )
    cursor.execute(
        "INSERT INTO config (key, value) VALUES (?, ?)", ("llm_model", "deepseek-chat")
    )
    cursor.execute(
        "INSERT INTO config (key, value) VALUES (?, ?)", ("max_batch_size", "10")
    )

    conn.commit()
    conn.close()

    return {
        "status": "success",
        "message": "Database initialized",
        "db_path": str(DB_PATH),
    }


def export_gitnexus(repo_path: str) -> dict:
    """Export data from GitNexus"""
    repo_name = Path(repo_path).name
    temp_dir = TEMP_DIR / repo_name
    temp_dir.mkdir(parents=True, exist_ok=True)

    log(f"Exporting GitNexus data for: {repo_name}")

    # Export communities
    stdout, stderr, code = run_command(
        [
            "npx",
            "gitnexus",
            "cypher",
            "-r",
            repo_name,
            "MATCH (c:Community) RETURN c.id AS id, c.label AS label, c.cohesion AS cohesion, c.symbolCount AS symbolCount ORDER BY c.symbolCount DESC",
        ],
        cwd=repo_path,
    )

    if code != 0:
        return {"status": "error", "message": f"GitNexus export failed: {stderr}"}

    (temp_dir / "communities.json").write_text(stdout)

    # Export processes
    stdout, stderr, code = run_command(
        [
            "npx",
            "gitnexus",
            "cypher",
            "-r",
            repo_name,
            "MATCH (p:Process) RETURN p.id AS id, p.label AS label, p.processType AS process_type, p.stepCount AS step_count, p.entryPointId AS entry_point",
        ],
        cwd=repo_path,
    )

    if code == 0:
        (temp_dir / "processes.json").write_text(stdout)

    # Export symbols (Function)
    stdout, stderr, code = run_command(
        [
            "npx",
            "gitnexus",
            "cypher",
            "-r",
            repo_name,
            "MATCH (f:Function) RETURN f.id AS id, f.name AS name, f.filePath AS file, f.startLine AS line LIMIT 500",
        ],
        cwd=repo_path,
    )

    if code == 0:
        (temp_dir / "symbols.json").write_text(stdout)

    return {
        "status": "success",
        "message": f"Data exported to {temp_dir}",
        "export_dir": str(temp_dir),
    }


def parse_markdown_table(content: str) -> list:
    """Parse GitNexus markdown table to list of dicts"""
    lines = content.strip().split("\n")

    # Find header
    header_line = None
    for line in lines:
        if line.strip().startswith("|") and "---" not in line:
            header_line = line
            break

    if not header_line:
        return []

    headers = [h.strip() for h in header_line.split("|")[1:-1]]

    # Parse data
    results = []
    in_data = False
    for line in lines:
        if "---" in line:
            in_data = True
            continue
        if not in_data or not line.strip().startswith("|"):
            continue
        if '"row_count"' in line:
            break

        cells = [c.strip() for c in line.split("|")[1:-1]]
        if len(cells) == len(headers):
            row = {headers[i]: cells[i] for i in range(len(headers))}
            results.append(row)

    return results


def parse_data() -> dict:
    """Parse exported GitNexus data into database"""
    temp_dirs = list(TEMP_DIR.glob("*"))
    if not temp_dirs:
        return {
            "status": "error",
            "message": "No exported data found. Run export first.",
        }

    temp_dir = temp_dirs[0]  # Use most recent

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    inserted = {"communities": 0, "processes": 0, "symbols": 0, "jump_targets": 0}

    # Parse communities
    communities_file = temp_dir / "communities.json"
    if communities_file.exists():
        content = communities_file.read_text()
        data = parse_markdown_table(content)

        for item in data:
            proc_id = f"community_{item.get('id', '')}"
            cursor.execute(
                """
                INSERT OR IGNORE INTO gitnexus_entity 
                (id, gitnexus_id, gitnexus_label, gitnexus_type, gitnexus_symbol_count, gitnexus_cohesion, data_sources)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
                (
                    proc_id,
                    item.get("id"),
                    item.get("label"),
                    "community",
                    int(item.get("symbolCount", 0) or 0),
                    float(item.get("cohesion", 0) or 0),
                    '["gitnexus"]',
                ),
            )
            inserted["communities"] += 1

        log(f"Inserted {inserted['communities']} communities")

    # Parse processes (with real entry points)
    processes_file = temp_dir / "processes.json"
    if processes_file.exists():
        content = processes_file.read_text()
        data = parse_markdown_table(content)

        for item in data:
            proc_id = f"process_{item.get('id', '')}"

            # Parse entry point to create jump target
            entry = item.get("entry_point", "")
            file_path = ""
            if entry and ":" in entry:
                parts = entry.split(":")
                if len(parts) >= 2:
                    file_path = parts[1]

            cursor.execute(
                """
                INSERT OR IGNORE INTO gitnexus_entity 
                (id, gitnexus_id, gitnexus_label, gitnexus_type, gitnexus_step_count, data_sources)
                VALUES (?, ?, ?, ?, ?, ?)
            """,
                (
                    proc_id,
                    item.get("id"),
                    item.get("label"),
                    "process",
                    int(item.get("step_count", 0) or 0),
                    '["gitnexus"]',
                ),
            )
            inserted["processes"] += 1

            # Create jump target for process
            if file_path:
                cursor.execute(
                    """
                    INSERT OR IGNORE INTO jump_targets 
                    (feature_id, target_type, file_path, line_number, source, confidence)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                    (proc_id, "process", file_path, 1, "gitnexus", "high"),
                )
                inserted["jump_targets"] += 1

    # Parse symbols
    symbols_file = temp_dir / "symbols.json"
    if symbols_file.exists():
        content = symbols_file.read_text()
        data = parse_markdown_table(content)

        for item in data:
            cursor.execute(
                """
                INSERT OR IGNORE INTO symbols_cache 
                (symbol_id, symbol_name, file_path, line_number)
                VALUES (?, ?, ?, ?)
            """,
                (
                    item.get("id"),
                    item.get("name"),
                    item.get("file"),
                    int(item.get("line", 0) or 0),
                ),
            )
            inserted["symbols"] += 1

    conn.commit()
    conn.close()

    return {"status": "success", "inserted": inserted}


def search_features(query: str) -> dict:
    """Search features by query with semantic annotations"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    results = []

    cursor.execute(
        """
        SELECT label, llm_feature_name, llm_feature_description, llm_core_logic_summary, llm_use_cases, community_count
        FROM label_annotations
        WHERE label LIKE ? OR llm_feature_name LIKE ? OR llm_feature_description LIKE ?
        """,
        (f"%{query}%", f"%{query}%", f"%{query}%"),
    )
    for row in cursor.fetchall():
        results.append(
            {
                "type": "label",
                "label": row["label"],
                "feature_name": row["llm_feature_name"],
                "feature_description": row["llm_feature_description"],
                "core_logic": row["llm_core_logic_summary"],
                "use_cases": row["llm_use_cases"],
                "community_count": row["community_count"],
            }
        )

    cursor.execute(
        """
        SELECT id, gitnexus_id, gitnexus_label, gitnexus_type, llm_feature_name, llm_feature_description
        FROM gitnexus_entity
        WHERE gitnexus_label LIKE ? OR llm_feature_name LIKE ? OR llm_feature_description LIKE ?
        LIMIT 20
    """,
        (f"%{query}%", f"%{query}%", f"%{query}%"),
    )

    for row in cursor.fetchall():
        results.append(dict(row))

    conn.close()

    return {"status": "success", "results": results, "count": len(results)}


def get_feature(feature_id: str) -> dict:
    """Get feature details with jump targets"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    # Get feature
    cursor.execute("SELECT * FROM gitnexus_entity WHERE id = ?", (feature_id,))
    feature = cursor.fetchone()
    if not feature:
        return {"status": "error", "message": f"Feature not found: {feature_id}"}

    feature_dict = dict(feature)

    # Get jump targets
    cursor.execute(
        """
        SELECT file_path, line_number, target_type, confidence
        FROM jump_targets WHERE feature_id = ?
    """,
        (feature_id,),
    )
    jump_targets = [dict(row) for row in cursor.fetchall()]

    conn.close()

    return {"status": "success", "feature": feature_dict, "jump_targets": jump_targets}


def get_jump_location(feature_id: str, target_index: int = 0) -> dict:
    """Get code jump location for a feature"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute(
        """
        SELECT file_path, line_number, target_type, confidence, source
        FROM jump_targets
        WHERE feature_id = ?
        ORDER BY 
            CASE confidence WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
            CASE source WHEN 'gitnexus' THEN 1 ELSE 2 END
        LIMIT 1 OFFSET ?
    """,
        (feature_id, target_index),
    )

    row = cursor.fetchone()
    conn.close()

    if not row:
        return {"status": "error", "message": f"No jump target found for: {feature_id}"}

    return {
        "status": "success",
        "jumps": {"file": row[0], "line": row[1], "type": row[2]},
        "format": f"JUMP:{row[0]}:{row[1]}",
    }


def show_status() -> dict:
    """Show system status"""
    if not DB_PATH.exists():
        return {"status": "not_initialized", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute(
        "SELECT gitnexus_type, COUNT(*) FROM gitnexus_entity GROUP BY gitnexus_type"
    )
    by_type = {row[0]: row[1] for row in cursor.fetchall()}

    cursor.execute("SELECT COUNT(*) FROM jump_targets")
    jump_targets = cursor.fetchone()[0]

    cursor.execute("SELECT COUNT(*) FROM symbols_cache")
    symbols = cursor.fetchone()[0]

    # Annotation status
    cursor.execute("SELECT COUNT(*) FROM gitnexus_entity WHERE llm_feature_name IS NOT NULL")
    annotated = cursor.fetchone()[0]

    cursor.execute("SELECT COUNT(*) FROM gitnexus_entity")
    total = cursor.fetchone()[0]

    conn.close()

    return {
        "status": "success",
        "gitnexus_entity": by_type,
        "jump_targets": jump_targets,
        "symbols": symbols,
        "annotated": annotated,
        "total": total,
        "annotation_progress": f"{annotated}/{total}",
        "db_path": str(DB_PATH),
    }


def sync_all(repo_path: str) -> dict:
    """Run init + export + parse in one command"""
    # Step 1: init
    log("Step 1/3: Initializing database...")
    init_result = init_database()
    if init_result.get("status") != "success":
        return init_result

    # Step 2: export
    log("Step 2/3: Exporting GitNexus data...")
    export_result = export_gitnexus(repo_path)
    if export_result.get("status") != "success":
        return export_result

    # Step 3: parse
    log("Step 3/3: Parsing data into database...")
    parse_result = parse_data()
    if parse_result.get("status") != "success":
        return parse_result

    return {
        "status": "success",
        "message": "sync complete (init + export + parse)",
    }


def get_next_unannotated() -> dict:
    """Get next unannotated feature for LLM analysis"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    # Get next unannotated feature (prefer process over community)
    cursor.execute(
        """
        SELECT * FROM gitnexus_entity 
        WHERE llm_feature_name IS NULL
        ORDER BY 
            CASE gitnexus_type WHEN 'process' THEN 0 ELSE 1 END,
            gitnexus_symbol_count DESC
        LIMIT 1
        """
    )
    row = cursor.fetchone()
    conn.close()

    if not row:
        return {"status": "done", "message": "All features annotated"}

    # Get jump targets for this feature
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    cursor.execute(
        "SELECT * FROM jump_targets WHERE feature_id = ?",
        (row["id"],),
    )
    jump_targets = [dict(r) for r in cursor.fetchall()]

    conn.close()

    return {
        "status": "success",
        "feature": dict(row),
        "jump_targets": jump_targets,
    }


def annotate_feature(feature_id: str, annotation: dict) -> dict:
    """Save LLM annotation to database"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute(
        """
        UPDATE gitnexus_entity SET
            llm_feature_name = ?,
            llm_feature_description = ?,
            llm_core_logic_summary = ?,
            llm_complexity = COALESCE(?, llm_complexity),
            last_updated = CURRENT_TIMESTAMP
        WHERE id = ?
        """,
        (
            annotation.get("feature_name"),
            annotation.get("feature_description"),
            annotation.get("core_logic_summary"),
            annotation.get("complexity"),
            feature_id,
        ),
    )

    conn.commit()
    conn.close()

    return {"status": "success", "message": f"Annotated {feature_id}"}


def list_unannotated(limit: int = 10) -> dict:
    """List unannotated features"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    cursor.execute(
        """
        SELECT id, gitnexus_label, gitnexus_type, gitnexus_symbol_count
        FROM gitnexus_entity 
        WHERE llm_feature_name IS NULL
        ORDER BY 
            CASE gitnexus_type WHEN 'process' THEN 0 ELSE 1 END,
            gitnexus_symbol_count DESC
        LIMIT ?
        """,
        (limit,),
    )
    results = [dict(row) for row in cursor.fetchall()]
    conn.close()

    return {
        "status": "success",
        "results": results,
        "count": len(results),
    }


def list_labels() -> dict:
    """List all unique labels"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    cursor.execute(
        "SELECT label, llm_feature_name, community_count FROM label_annotations ORDER by community_count DESC"
    )
    results = [dict(row) for row in cursor.fetchall()]
    conn.close()

    return {"status": "success", "results": results, "count": len(results)}


def get_next_label() -> dict:
    """Get next unlabeled label"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    cursor.execute(
        "SELECT * FROM label_annotations WHERE llm_feature_name IS NULL ORDER BY community_count DESC LIMIT 1"
    )
    row = cursor.fetchone()
    conn.close()

    if not row:
        return {"status": "done", "message": "All labels annotated"}

    return {"status": "success", "label": dict(row)}


def get_label(label: str) -> dict:
    """Get label annotation"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    cursor.execute("SELECT * FROM label_annotations WHERE label = ?", (label,))
    row = cursor.fetchone()
    conn.close()

    if not row:
        return {"status": "error", "message": f"Label not found: {label}"}

    return {"status": "success", "label": dict(row)}


def save_label_annotation(label: str, annotation: dict) -> dict:
    """Save label annotation"""
    if not DB_PATH.exists():
        return {"status": "error", "message": "Database not initialized"}

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute(
        """
        UPDATE label_annotations SET
            llm_feature_name = ?,
            llm_feature_description = ?,
            llm_core_logic_summary = ?,
            llm_category = ?,
            llm_use_cases = ?,
            llm_complexity = ?,
            llm_model = ?,
            llm_analysis_time = CURRENT_TIMESTAMP
        WHERE label = ?
        """,
        (
            annotation.get("feature_name"),
            annotation.get("feature_description"),
            annotation.get("core_logic_summary"),
            annotation.get("category"),
            annotation.get("use_cases"),
            annotation.get("complexity", 3),
            annotation.get("model", "deepseek-chat"),
            label,
        ),
    )

    conn.commit()
    conn.close()

    return {"status": "success", "message": f"Annotated {label}"}


def init_label_table() -> dict:
    """Initialize label annotations table"""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    cursor.execute("""
        CREATE TABLE IF NOT EXISTS label_annotations (
            label TEXT PRIMARY KEY,
            llm_feature_name TEXT,
            llm_feature_description TEXT,
            llm_core_logic_summary TEXT,
            llm_category TEXT,
            llm_use_cases TEXT,
            llm_complexity INTEGER DEFAULT 3,
            community_count INTEGER,
            llm_model TEXT,
            llm_analysis_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)

    cursor.execute("""
        INSERT OR IGNORE INTO label_annotations (label, community_count)
        SELECT gitnexus_label, COUNT(*) as cnt
        FROM gitnexus_entity 
        WHERE gitnexus_type='community' 
        GROUP BY gitnexus_label
    """)

    conn.commit()
    conn.close()

    return {"status": "success", "message": "Label table initialized"}


def main():
    """Main entry point"""
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    command = sys.argv[1]

    try:
        if command == "sync":
            repo_path = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
            result = sync_all(repo_path)
            print(json.dumps(result))

        elif command == "annotate":
            if len(sys.argv) == 2:
                result = show_status()
                print(json.dumps(result))
            elif sys.argv[2] == "--status":
                result = show_status()
                print(json.dumps(result))
            elif sys.argv[2] == "--next":
                result = get_next_unannotated()
                print(json.dumps(result, ensure_ascii=False))
            elif sys.argv[2] == "--batch":
                batch_size = int(sys.argv[3]) if len(sys.argv) > 3 else 5
                result = list_unannotated(batch_size)
                print(json.dumps(result, ensure_ascii=False))
            elif sys.argv[2] == "--all":
                result = list_unannotated(9999)
                print(json.dumps(result, ensure_ascii=False))
            else:
                feature_id = sys.argv[2]
                result = get_feature(feature_id)
                print(json.dumps(result, ensure_ascii=False))

        elif command == "init":
            result = init_database()
            print(json.dumps(result))

        elif command == "export":
            repo_path = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
            result = export_gitnexus(repo_path)
            print(json.dumps(result))

        elif command == "parse":
            result = parse_data()
            print(json.dumps(result))

        elif command == "search":
            query = sys.argv[2] if len(sys.argv) > 2 else ""
            result = search_features(query)
            print(json.dumps(result, ensure_ascii=False))

        elif command == "get":
            feature_id = sys.argv[2] if len(sys.argv) > 2 else ""
            result = get_feature(feature_id)
            print(json.dumps(result, ensure_ascii=False))

        elif command == "jump":
            feature_id = sys.argv[2] if len(sys.argv) > 2 else ""
            target_index = int(sys.argv[3]) if len(sys.argv) > 3 else 0
            result = get_jump_location(feature_id, target_index)
            print(json.dumps(result))

        elif command == "status":
            result = show_status()
            print(json.dumps(result))

        elif command == "label":
            if len(sys.argv) == 2:
                result = list_labels()
                print(json.dumps(result, ensure_ascii=False))
            elif sys.argv[2] == "--init":
                result = init_label_table()
                print(json.dumps(result))
            elif sys.argv[2] == "--next":
                result = get_next_label()
                print(json.dumps(result, ensure_ascii=False))
            else:
                label = sys.argv[2]
                result = get_label(label)
                print(json.dumps(result, ensure_ascii=False))

        elif command == "save-label":
            label = sys.argv[2] if len(sys.argv) > 2 else ""
            annotation_json = sys.argv[3] if len(sys.argv) > 3 else "{}"
            try:
                annotation = json.loads(annotation_json)
            except:
                annotation = {}
            result = save_label_annotation(label, annotation)
            print(json.dumps(result))

        elif command == "save":
            feature_id = sys.argv[2] if len(sys.argv) > 2 else ""
            annotation_json = sys.argv[3] if len(sys.argv) > 3 else "{}"
            try:
                annotation = json.loads(annotation_json)
            except:
                annotation = {}
            result = annotate_feature(feature_id, annotation)
            print(json.dumps(result))

        else:
            print(
                json.dumps(
                    {"status": "error", "message": f"Unknown command: {command}"}
                )
            )
            sys.exit(1)

    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()
