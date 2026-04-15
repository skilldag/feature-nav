#!/usr/bin/env node
const Database = require("better-sqlite3");
const { execSync } = require("child_process");
const {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  unlinkSync,
} = require("fs");
const { join, dirname } = require("path");
const { homedir } = require("os");

const FEATURE_NAV_DIR = join(homedir(), ".feature_nav");
const DB_DIR = join(FEATURE_NAV_DIR, "db");
let currentRepo = "default";
function setRepo(name) {
  currentRepo = name;
}
function DB_PATH(repoName) {
  return join(DB_DIR, `${repoName || currentRepo}.db`);
}
const TEMP_DIR = join(FEATURE_NAV_DIR, "temp", "gitnexus_export");

mkdirSync(DB_DIR, { recursive: true });
mkdirSync(TEMP_DIR, { recursive: true });

function getDb(repoName) {
  const name = repoName || currentRepo;
  const db = new Database(DB_PATH(name));
  migrateGnexEntityTable(db);
  return db;
}

/** 同步行表：旧名 features / feature → gitnexus_entity（Community + Process，避免与「产品功能」混淆） */
function migrateGnexEntityTable(db) {
  const hasTable = (name) =>
    !!db
      .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?")
      .get(name);
  const hasColumn = (table, col) =>
    !!db
      .prepare("PRAGMA table_info(" + table + ")")
      .all()
      .find((r) => r.name === col);

  if (hasTable("gitnexus_entity")) {
    if (!hasColumn("gitnexus_entity", "heuristic_label")) {
      db.exec("ALTER TABLE gitnexus_entity ADD COLUMN heuristic_label TEXT");
    }
    return;
  }
  if (hasTable("feature")) {
    db.exec("ALTER TABLE feature RENAME TO gitnexus_entity");
    db.exec("ALTER TABLE gitnexus_entity ADD COLUMN heuristic_label TEXT");
    return;
  }
  if (hasTable("features")) {
    db.exec("ALTER TABLE features RENAME TO gitnexus_entity");
    db.exec("ALTER TABLE gitnexus_entity ADD COLUMN heuristic_label TEXT");
  }
}

function initDatabase(repoName) {
  const db = getDb(repoName);
  db.exec(`
CREATE TABLE IF NOT EXISTS gitnexus_entity (
  id TEXT PRIMARY KEY,
  gitnexus_id TEXT NOT NULL,
  gitnexus_label TEXT,
  heuristic_label TEXT,
  gitnexus_type TEXT CHECK(gitnexus_type IN ('community', 'process')),
  gitnexus_symbol_count INTEGER,
  gitnexus_cohesion REAL,
  gitnexus_step_count INTEGER,
  llm_feature_name TEXT,
  llm_feature_description TEXT,
  llm_core_logic_summary TEXT,
  data_sources TEXT,
  last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  llm_complexity INTEGER DEFAULT 3
);

CREATE TABLE IF NOT EXISTS jump_targets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      feature_id TEXT NOT NULL,
      target_type TEXT,
      file_path TEXT,
      line_number INTEGER,
      source TEXT,
      confidence TEXT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS symbols_cache (
      symbol_id TEXT PRIMARY KEY,
      symbol_name TEXT,
      file_path TEXT,
      line_number INTEGER,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

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
    );

    CREATE TABLE IF NOT EXISTS config (
      key TEXT PRIMARY KEY,
      value TEXT,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS process_steps (
      feature_id TEXT NOT NULL,
      step_index INTEGER NOT NULL,
      symbol_id TEXT,
      file_path TEXT,
      line_number INTEGER,
      PRIMARY KEY (feature_id, step_index)
    );
  `);

  db.exec(
    `INSERT OR IGNORE INTO config (key, value) VALUES ('version', '1.0.0')`,
  );
  db.close();
  return {
    status: "success",
    message: "Database initialized",
    db_path: DB_PATH,
  };
}

function runCommand(cmd, cwd) {
  try {
    const fullCmd = cmd.map((a) => (a.includes(" ") ? `"${a}"` : a)).join(" ");
    const result = execSync(fullCmd, {
      cwd,
      encoding: "utf-8",
      timeout: 120000,
      shell: true,
    });
    return { stdout: result, stderr: "", code: 0 };
  } catch (e) {
    return { stdout: e.stdout || "", stderr: e.message, code: e.status || 1 };
  }
}

function runCypherQuery(repoPath, query) {
  const repoName = repoPath.split("/").pop() || "";
  return runCommand(
    ["npx", "gitnexus", "cypher", "-r", repoName, query],
    repoPath,
  );
}

function exportGitNexus(repoPath) {
  const repoName = repoPath.split("/").pop() || "";
  const tempDir = join(TEMP_DIR, repoName);
  mkdirSync(tempDir, { recursive: true });

  const r1 = runCypherQuery(
    repoPath,
    "MATCH (c:Community) RETURN c.id AS id, c.label AS label, c.heuristicLabel AS heuristicLabel, c.cohesion AS cohesion, c.symbolCount AS symbolCount ORDER BY c.symbolCount DESC",
  );

  if (r1.code !== 0)
    return { status: "error", message: `GitNexus export failed: ${r1.stderr}` };
  writeFileSync(join(tempDir, "communities.json"), r1.stdout);

  const r2 = runCypherQuery(
    repoPath,
    "MATCH (p:Process) " +
      "OPTIONAL MATCH (f:Function) WHERE f.id = p.entryPointId " +
      "OPTIONAL MATCH (m:Method) WHERE m.id = p.entryPointId " +
      "RETURN p.id AS id, p.label AS label, p.processType AS process_type, p.stepCount AS step_count, " +
      "p.entryPointId AS entry_point, p.communities AS communities, " +
      "COALESCE(f.startLine, m.startLine) AS entry_line " +
      "ORDER BY p.id",
  );

  if (r2.code === 0) writeFileSync(join(tempDir, "processes.json"), r2.stdout);

  exportProcessStepsBatched(repoPath, tempDir);

  return {
    status: "success",
    message: `Data exported to ${tempDir}`,
    export_dir: tempDir,
  };
}

/** 导出 Process 执行链。gitnexus cypher 写 stdout 时 JSON 约固定截断 8KB，必须重定向到文件再读。 */
function exportProcessStepsBatched(repoPath, tempDir) {
  const repoName = repoPath.split("/").pop() || "";
  const query =
    "MATCH (n)-[r]->(p:Process) WHERE r.type = 'STEP_IN_PROCESS' " +
    "OPTIONAL MATCH (f:Function) WHERE f.id = n.id " +
    "OPTIONAL MATCH (m:Method) WHERE m.id = n.id " +
    "OPTIONAL MATCH (st:Struct) WHERE st.id = n.id " +
    "RETURN p.id AS process_id, r.step AS step, n.id AS symbol_id, " +
    "COALESCE(f.filePath, m.filePath, st.filePath) AS file_path, " +
    "COALESCE(f.startLine, m.startLine, st.startLine) AS line_number " +
    "ORDER BY p.id, r.step";
  const rawPath = join(tempDir, "_process_steps_cypher.json");
  const out = join(tempDir, "process_steps.json");
  try {
    execSync(
      `npx gitnexus cypher -r ${JSON.stringify(repoName)} ${JSON.stringify(query)} > ${JSON.stringify(rawPath)}`,
      { cwd: repoPath, shell: true, timeout: 300000 },
    );
    const stdout = readFileSync(rawPath, "utf-8");
    const md = parseGitNexusJson(stdout);
    const rows = parseMarkdownTable(md);
    writeFileSync(out, JSON.stringify({ rows }, null, 0));
    try {
      unlinkSync(rawPath);
    } catch {
      /* ignore */
    }
  } catch {
    writeFileSync(out, JSON.stringify({ rows: [] }));
  }
}

function parseMarkdownTable(content) {
  const lines = content.trim().split("\n");
  let headerLine = "";
  for (const line of lines) {
    if (line.trim().startsWith("|") && !line.includes("---")) {
      headerLine = line;
      break;
    }
  }
  if (!headerLine) return [];

  const headers = headerLine
    .split("|")
    .slice(1, -1)
    .map((h) => h.trim());
  const results = [];
  let inData = false;

  for (const line of lines) {
    if (line.includes("---")) {
      inData = true;
      continue;
    }
    if (!inData || !line.trim().startsWith("|")) continue;

    const cells = line
      .split("|")
      .slice(1, -1)
      .map((c) => c.trim());
    if (cells.length === headers.length) {
      const row = {};
      headers.forEach((h, i) => (row[h] = cells[i]));
      results.push(row);
    }
  }
  return results;
}

/**
 * 解析 GitNexus entry_point。
 * - 无行号: Function:relative/path/to/file.go:SymbolName → line_number 为 null（图里未给行号时只能如此）
 * - 含行号: Function:relative/path.go:42:SymbolName（倒数第二段为纯数字时视为行号）
 * 路径中可含冒号：从右侧切分，避免 (.+):(\\w+) 误伤多级路径。
 */
function parseGitNexusEntryPoint(entryPoint) {
  if (!entryPoint || typeof entryPoint !== "string") return null;
  const s = entryPoint.trim();
  const kindM = s.match(/^(Function|Method):([\s\S]+)$/);
  if (!kindM) return null;
  const targetType = kindM[1].toLowerCase();
  const parts = kindM[2].split(":");
  if (parts.length < 2) return null;
  const symbol = parts[parts.length - 1];
  if (!/^\w+$/.test(symbol)) return null;
  const maybeLine = parts[parts.length - 2];
  if (parts.length >= 3 && /^\d+$/.test(maybeLine)) {
    const lineNumber = parseInt(maybeLine, 10);
    const filePath = parts.slice(0, -2).join(":");
    if (!filePath) return null;
    return { targetType, filePath, lineNumber };
  }
  const filePath = parts.slice(0, -1).join(":");
  if (!filePath) return null;
  return { targetType, filePath, lineNumber: null };
}

/** 导出表中的 entry_line（图里 Function/Method.startLine）；无则回退 ep 串内解析出的行号 */
function lineNumberFromProcessRow(row, epParsedLine) {
  if (!row || typeof row !== "object") return epParsedLine ?? null;
  const raw = row.entry_line;
  if (raw === undefined || raw === null || String(raw).trim() === "")
    return epParsedLine ?? null;
  const n = parseInt(String(raw).trim(), 10);
  if (!Number.isFinite(n) || n < 1) return epParsedLine ?? null;
  return n;
}

function parseGitNexusJson(content) {
  const trimmed = content.trim();
  if (trimmed.startsWith("|")) return trimmed;
  try {
    const parsed = JSON.parse(content);
    if (parsed.markdown) return parsed.markdown;
  } catch {
    const match = content.match(/\|[^|]+\|[^|]+\|/);
    if (match) {
      const startIdx = content.indexOf(match);
      const endIdx = content.lastIndexOf("| ");
      if (startIdx >= 0 && endIdx > startIdx) {
        let extracted = content.substring(startIdx, endIdx + 1);
        return extracted.replace(/\\n/g, "\n").replace(/\\"/g, '"');
      }
    }
  }
  return content;
}

function parseData(repoName) {
  const tempDir = join(TEMP_DIR, repoName || currentRepo);
  if (!existsSync(tempDir))
    return {
      status: "error",
      message: "No exported data found for repo: " + (repoName || currentRepo),
    };

  const db = getDb();
  const inserted = { communities: 0, processes: 0, process_steps: 0 };

const communitiesFile = join(tempDir, "communities.json");
  if (existsSync(communitiesFile)) {
    const raw = parseGitNexusJson(readFileSync(communitiesFile, "utf-8"));
    const data = parseMarkdownTable(raw);
    const stmt = db.prepare(`
INSERT OR REPLACE INTO gitnexus_entity
(id, gitnexus_id, gitnexus_label, heuristic_label, gitnexus_type, gitnexus_symbol_count, gitnexus_cohesion, data_sources)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)`);

    for (const item of data) {
      const effectiveLabel = item.heuristicLabel && item.heuristicLabel.trim() !== "" 
        ? item.heuristicLabel 
        : item.label;
      stmt.run(
        `community_${item.id}`,
        item.id,
        item.label,
        effectiveLabel,
        "community",
        parseInt(item.symbolCount) || 0,
        parseFloat(item.cohesion) || 0,
        '["gitnexus"]',
      );
      inserted.communities++;
    }

    // Second pass: add jump_targets for Communities based on Process entry_points
    const processesFile = join(tempDir, "processes.json");
    if (existsSync(processesFile)) {
      const raw = parseGitNexusJson(readFileSync(processesFile, "utf-8"));
      const processData = parseMarkdownTable(raw);

      for (const pItem of processData) {
        if (pItem.communities && pItem.entry_point) {
          const ep = parseGitNexusEntryPoint(pItem.entry_point);
          if (!ep) continue;
          const filePath = ep.filePath;
          const lineNumber = lineNumberFromProcessRow(pItem, ep.lineNumber);

          const normalized = pItem.communities
            .replace(/\\"/g, '"')
            .replace(/\\'/g, "'");
          const commMatches = normalized.match(/'([^']+)'/g);
          if (!commMatches) continue;

          const jstmt = db.prepare(`
            INSERT OR IGNORE INTO jump_targets (feature_id, target_type, file_path, line_number, source, confidence)
            VALUES (?, ?, ?, ?, ?, ?)`);
          for (const cm of commMatches) {
            const commId = cm.replace(/'/g, "");
            jstmt.run(
              `community_${commId}`,
              "code",
              filePath,
              lineNumber,
              "gitnexus_inferred",
              "medium",
            );
          }
        }
      }
    }
  }

const processesFile = join(tempDir, "processes.json");
  if (existsSync(processesFile)) {
    const raw = parseGitNexusJson(readFileSync(processesFile, "utf-8"));
    const data = parseMarkdownTable(raw);
    const stmt = db.prepare(`
INSERT OR REPLACE INTO gitnexus_entity
(id, gitnexus_id, gitnexus_label, heuristic_label, gitnexus_type, gitnexus_step_count, data_sources)
VALUES (?, ?, ?, ?, ?, ?, ?)`);

    const stmt2 = db.prepare(
      `SELECT heuristic_label FROM gitnexus_entity WHERE gitnexus_id = ? AND gitnexus_type = 'community' LIMIT 1`,
    );

    for (const item of data) {
      let originalLabel = item.label;
      let heuristicLabel = item.label;
      if (item.communities) {
        const normalized = item.communities
          .replace(/\\"/g, '"')
          .replace(/\\'/g, "'");
        const commMatches = normalized.match(/'([^']+)'/g);
        if (commMatches && commMatches.length > 0) {
          const firstComm = commMatches[0].replace(/'/g, "");
          const row = stmt2.get(firstComm);
          if (row) {
            originalLabel = row.heuristic_label || originalLabel;
            heuristicLabel = row.heuristic_label || item.label;
          }
        }
      }
      stmt.run(
        `process_${item.id}`,
        item.id,
        originalLabel,
        heuristicLabel,
        "process",
        parseInt(item.step_count) || 0,
        '["gitnexus"]',
      );
      inserted.processes++;

      if (item.entry_point) {
        const ep = parseGitNexusEntryPoint(item.entry_point);
        if (ep) {
          const lineNumber = lineNumberFromProcessRow(item, ep.lineNumber);
          const jstmt = db.prepare(`
            INSERT OR IGNORE INTO jump_targets (feature_id, target_type, file_path, line_number, source, confidence)
            VALUES (?, ?, ?, ?, ?, ?)`);
          jstmt.run(
            `process_${item.id}`,
            ep.targetType,
            ep.filePath,
            lineNumber,
            "gitnexus",
            "high",
          );
        }
      }
    }
  }

  const stepsFile = join(tempDir, "process_steps.json");
  if (existsSync(stepsFile)) {
    db.exec("DELETE FROM process_steps");
    const rawFile = readFileSync(stepsFile, "utf-8");
    let stepData = [];
    try {
      const parsed = JSON.parse(rawFile);
      if (parsed && Array.isArray(parsed.rows)) stepData = parsed.rows;
    } catch {
      stepData = [];
    }
    if (stepData.length === 0) {
      const rawSteps = parseGitNexusJson(rawFile);
      stepData = parseMarkdownTable(rawSteps);
    }
    const stStmt = db.prepare(`
      INSERT INTO process_steps (feature_id, step_index, symbol_id, file_path, line_number)
      VALUES (?, ?, ?, ?, ?)`);
    for (const row of stepData) {
      if (!row.process_id) continue;
      const fid = `process_${row.process_id}`;
      const si = parseInt(String(row.step || "").trim(), 10);
      if (!Number.isFinite(si)) continue;
      const rawLn = row.line_number;
      let ln = null;
      if (
        rawLn !== undefined &&
        rawLn !== null &&
        String(rawLn).trim() !== ""
      ) {
        const p = parseInt(String(rawLn).trim(), 10);
        ln = Number.isFinite(p) ? p : null;
      }
      stStmt.run(fid, si, row.symbol_id || null, row.file_path || null, ln);
      inserted.process_steps++;
    }
  }

  db.close();
  return { status: "success", inserted };
}

function initLabelTable() {
  const db = getDb();
  db.exec(`
INSERT OR IGNORE INTO label_annotations (label, community_count)
SELECT heuristic_label, COUNT(*) as cnt
FROM gitnexus_entity WHERE gitnexus_type='community' AND heuristic_label IS NOT NULL
GROUP BY heuristic_label
`);
  db.close();
  return { status: "success", message: "Label table initialized" };
}

/**
 * Process 在 GitNexus 里 gitnexus_label 常为流程名(A→B)，与 Community 的类名(如 Clustering)不一致。
 * 统计：精确匹配该 Label 的 Process ∪ 与同 Label 下任一 Community 在 jump_targets 上共享文件路径的 Process（去重）。
*/
function countProcessesForLabelUnion(db, labelName) {
  const r = db
    .prepare(
      `
SELECT COUNT(*) AS c FROM (
  SELECT id FROM gitnexus_entity WHERE heuristic_label = ? AND gitnexus_type = 'process'
  UNION
  SELECT DISTINCT fproc.id
  FROM gitnexus_entity fcomm
  INNER JOIN jump_targets jcomm ON jcomm.feature_id = fcomm.id
  INNER JOIN jump_targets jproc ON jproc.file_path = jcomm.file_path
  INNER JOIN gitnexus_entity fproc ON fproc.id = jproc.feature_id AND fproc.gitnexus_type = 'process'
  WHERE fcomm.heuristic_label = ? AND fcomm.gitnexus_type = 'community'
)
`,
    )
    .get(labelName, labelName);
  return r ? r.c : 0;
}

function listLabels() {
  const db = getDb();
  const stmt = db.prepare(`
SELECT
  la.label,
  la.llm_feature_name,
  (SELECT COUNT(*) FROM gitnexus_entity f WHERE f.heuristic_label = la.label AND f.gitnexus_type = 'community') AS community_count,
  (
    SELECT COUNT(*) FROM (
      SELECT id FROM gitnexus_entity f WHERE f.heuristic_label = la.label AND f.gitnexus_type = 'process'
      UNION
      SELECT DISTINCT fproc.id
      FROM gitnexus_entity fcomm
      INNER JOIN jump_targets jcomm ON jcomm.feature_id = fcomm.id
      INNER JOIN jump_targets jproc ON jproc.file_path = jcomm.file_path
      INNER JOIN gitnexus_entity fproc ON fproc.id = jproc.feature_id AND fproc.gitnexus_type = 'process'
      WHERE fcomm.heuristic_label = la.label AND fcomm.gitnexus_type = 'community'
    )
  ) AS process_count
FROM label_annotations la
ORDER BY community_count DESC, process_count DESC
`);
  const results = stmt.all();
  db.close();
  return { status: "success", results, count: results.length };
}

function listAllCommunities() {
  const db = getDb();
  const stmt = db.prepare(`
SELECT heuristic_label as label, COUNT(*) as community_count, SUM(gitnexus_symbol_count) as symbol_count
FROM gitnexus_entity
WHERE gitnexus_type = 'community' AND heuristic_label IS NOT NULL
GROUP BY heuristic_label
ORDER BY community_count DESC
LIMIT 100
`);
  const results = stmt.all();
  db.close();
  return { status: "success", results, count: results.length };
}

function getNextLabel() {
  const db = getDb();
  const stmt = db.prepare(
    "SELECT * FROM label_annotations WHERE llm_feature_name IS NULL ORDER BY community_count DESC LIMIT 1",
  );
  const row = stmt.get();
  db.close();
  if (!row) return { status: "done", message: "All labels annotated" };
  return { status: "success", label: row };
}

function getLabel(name) {
  const db = getDb();
  const stmt = db.prepare("SELECT * FROM label_annotations WHERE label = ?");
  const row = stmt.get(name);
  if (!row) {
    db.close();
    return { status: "error", message: `Label not found: ${name}` };
  }
  const nComm = db
    .prepare(
      `SELECT COUNT(*) AS c FROM gitnexus_entity WHERE heuristic_label = ? AND gitnexus_type = 'community'`,
    )
    .get(name);
  row.n_communities = nComm.c;
  row.n_processes = countProcessesForLabelUnion(db, name);
  db.close();
  const procSnap = listProcessesForLabel(name);
  const processes =
    procSnap.status === "success" ? procSnap.processes || [] : [];
  const unannotated_processes = processes
    .filter(
      (p) =>
        p.llm_feature_name == null || String(p.llm_feature_name).trim() === "",
    )
    .map((p) => ({
      id: p.id,
      gitnexus_id: p.gitnexus_id,
      gitnexus_step_count: p.gitnexus_step_count,
      association: p.association,
    }));
  row.unannotated_processes = unannotated_processes;
  row.unannotated_process_count = unannotated_processes.length;
  return { status: "success", label: row };
}

/**
 * Label(Feature) 聚合其下全部 Community 与 Process：合并二者在 jump_targets 中的条目（去重）。
 */
function listModulesForLabel(labelName) {
  if (!labelName) return { status: "error", message: "Label name required" };
  const db = getDb();
const rows = db
    .prepare(
      `
SELECT j.file_path, j.line_number, j.target_type, j.confidence, j.feature_id,
f.gitnexus_type AS feature_type
FROM jump_targets j
INNER JOIN gitnexus_entity f ON f.id = j.feature_id
WHERE f.heuristic_label = ?
ORDER BY f.gitnexus_type ASC, (j.line_number IS NULL), j.line_number ASC
`,
    )
    .all(labelName);
  const seen = new Set();
  const targets = [];
  for (const r of rows) {
    const key = `${r.file_path}::${r.line_number || 0}`;
    if (seen.has(key)) continue;
    seen.add(key);
    targets.push(r);
  }
let communities = [];
  let processes = [];
  if (targets.length === 0) {
    communities = db
      .prepare(
        `
SELECT id, gitnexus_id, gitnexus_symbol_count
FROM gitnexus_entity
WHERE heuristic_label = ? AND gitnexus_type = 'community'
ORDER BY gitnexus_symbol_count DESC
`,
      )
      .all(labelName);
    processes = db
      .prepare(
        `
SELECT id, gitnexus_id, gitnexus_step_count
FROM gitnexus_entity
WHERE heuristic_label = ? AND gitnexus_type = 'process'
ORDER BY gitnexus_step_count DESC
`,
      )
      .all(labelName);
  }
  db.close();
  return {
    status: "success",
    label: labelName,
    targets,
    communities,
    processes,
    count: targets.length,
  };
}

/** 某 Label 下 Process：精确匹配 + 与同 Label 下 Community 共享 jump_targets 文件的流程（去重） */
function listProcessesForLabel(labelName) {
  if (!labelName) return { status: "error", message: "Label name required" };
  const db = getDb();
  const exactRows = db
    .prepare(
      `
SELECT id, gitnexus_id, gitnexus_label, gitnexus_step_count,
llm_feature_name, llm_feature_description, llm_core_logic_summary
FROM gitnexus_entity
WHERE heuristic_label = ? AND gitnexus_type = 'process'
ORDER BY gitnexus_step_count DESC, id ASC
`,
    )
    .all(labelName);

const linkedRows = db
    .prepare(
      `
SELECT DISTINCT fproc.id, fproc.gitnexus_id, fproc.gitnexus_label, fproc.gitnexus_step_count,
fproc.llm_feature_name, fproc.llm_feature_description, fproc.llm_core_logic_summary
FROM gitnexus_entity fcomm
INNER JOIN jump_targets jcomm ON jcomm.feature_id = fcomm.id
INNER JOIN jump_targets jproc ON jproc.file_path = jcomm.file_path
INNER JOIN gitnexus_entity fproc ON fproc.id = jproc.feature_id AND fproc.gitnexus_type = 'process'
WHERE fcomm.heuristic_label = ? AND fcomm.gitnexus_type = 'community'
ORDER BY fproc.gitnexus_step_count DESC, fproc.id ASC
`,
    )
    .all(labelName);

  const byId = new Map();
  for (const p of exactRows) {
    byId.set(p.id, { ...p, association: "exact" });
  }
  for (const p of linkedRows) {
    if (!byId.has(p.id)) {
      byId.set(p.id, { ...p, association: "shared_file" });
    }
  }

  const merged = Array.from(byId.values());
  merged.sort(
    (a, b) =>
      (b.gitnexus_step_count || 0) - (a.gitnexus_step_count || 0) ||
      String(a.id).localeCompare(String(b.id)),
  );

  const jstmt = db.prepare(
    `SELECT file_path, line_number, target_type, confidence, feature_id FROM jump_targets WHERE feature_id = ? ORDER BY (line_number IS NULL), line_number ASC`,
  );
  const sstmt = db.prepare(
    `SELECT step_index AS step, symbol_id, file_path, line_number FROM process_steps WHERE feature_id = ? ORDER BY step_index ASC`,
  );
  const processes = [];
  for (const p of merged) {
    const jump_targets = jstmt.all(p.id);
    const steps = sstmt.all(p.id);
    processes.push({
      id: p.id,
      gitnexus_id: p.gitnexus_id,
      gitnexus_label: p.gitnexus_label,
      gitnexus_step_count: p.gitnexus_step_count,
      llm_feature_name: p.llm_feature_name,
      llm_feature_description: p.llm_feature_description,
      llm_core_logic_summary: p.llm_core_logic_summary,
      association: p.association || "exact",
      jump_targets,
      steps,
    });
  }
  db.close();
  return {
    status: "success",
    label: labelName,
    processes,
    count: processes.length,
  };
}

function saveLabelAnnotation(label, annotation) {
  const db = getDb();
  const a = annotation;
  db.prepare(
    `
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
  `,
  ).run(
    a.feature_name,
    a.feature_description,
    a.core_logic_summary,
    a.category,
    a.use_cases,
    a.complexity || 3,
    a.model || "deepseek-chat",
    label,
  );

  db.close();
  return { status: "success", message: `Annotated ${label}` };
}

/** 写入单条 Process（gitnexus_entity）的 LLM 字段；与 Label 级 save-label 独立 */
function saveProcessAnnotation(entityId, annotation) {
  const db = getDb();
  const row = db
    .prepare("SELECT id, gitnexus_type FROM gitnexus_entity WHERE id = ?")
    .get(entityId);
  if (!row) {
    db.close();
    return {
      status: "error",
      message: `gitnexus_entity not found: ${entityId}`,
    };
  }
  if (row.gitnexus_type !== "process") {
    db.close();
    return {
      status: "error",
      message: `save-process 仅用于 process 行，当前为: ${row.gitnexus_type}`,
    };
  }
  const a = annotation || {};
  const name = a.feature_name ?? a.featureName ?? null;
  const desc = a.feature_description ?? a.featureDescription ?? null;
  const core = a.core_logic_summary ?? a.core_logic ?? null;
  const complexity = a.complexity != null ? a.complexity : null;
  db.prepare(
    `UPDATE gitnexus_entity SET
      llm_feature_name = ?,
      llm_feature_description = ?,
      llm_core_logic_summary = ?,
      llm_complexity = COALESCE(?, llm_complexity),
      last_updated = CURRENT_TIMESTAMP
    WHERE id = ?`,
  ).run(name, desc, core, complexity, entityId);
  db.close();
  return {
    status: "success",
    message: `Annotated process ${entityId}`,
    id: entityId,
  };
}

/** 下一条待 LLM 标注的 Process（llm_feature_name 为空）；可选按 gitnexus_label 过滤 */
function getNextUnannotatedProcess(labelFilter) {
const db = getDb();
  const hasLabel = labelFilter && String(labelFilter).trim() !== "";
  const row = hasLabel
    ? db
      .prepare(
        `SELECT * FROM gitnexus_entity
WHERE gitnexus_type = 'process'
AND (llm_feature_name IS NULL OR TRIM(llm_feature_name) = '')
AND heuristic_label = ?
ORDER BY gitnexus_step_count DESC, id ASC
LIMIT 1`,
      )
      .get(labelFilter)
    : db
      .prepare(
        `SELECT * FROM gitnexus_entity
WHERE gitnexus_type = 'process'
AND (llm_feature_name IS NULL OR TRIM(llm_feature_name) = '')
ORDER BY COALESCE(heuristic_label,''), gitnexus_step_count DESC, id ASC
LIMIT 1`,
      )
      .get();
  if (!row) {
    db.close();
    return {
      status: "done",
      message: hasLabel
        ? `该 Label 下没有待标注的 Process: ${labelFilter}`
        : "全部 Process 已写入 llm_feature_name",
    };
  }
  const featureId = row.id;
  const jumpTargets = db
    .prepare(
      "SELECT * FROM jump_targets WHERE feature_id = ? ORDER BY (line_number IS NULL), line_number ASC, id ASC",
    )
    .all(featureId);
  const steps = db
    .prepare(
      `SELECT step_index AS step, symbol_id, file_path, line_number FROM process_steps WHERE feature_id = ? ORDER BY step_index ASC`,
    )
    .all(featureId);
  db.close();
  return {
    status: "success",
    entity: row,
    jump_targets: jumpTargets,
    steps,
    save_hint: `node feature-tool.js save-process ${featureId} '{"feature_name":"…","feature_description":"…","core_logic_summary":"…","complexity":3}'`,
  };
}

function searchFeatures(query) {
  const db = getDb();
  const results = [];

  const stmt1 = db.prepare(`
    SELECT label, llm_feature_name, llm_feature_description, llm_core_logic_summary, llm_use_cases, community_count
    FROM label_annotations
    WHERE label LIKE ? OR llm_feature_name LIKE ? OR llm_feature_description LIKE ?
  `);
  const rows1 = stmt1.all(`%${query}%`, `%${query}%`, `%${query}%`);
  for (const row of rows1) {
    results.push({
      type: "label",
      label: row.label,
      feature_name: row.llm_feature_name,
      feature_description: row.llm_feature_description,
      core_logic: row.llm_core_logic_summary,
      use_cases: row.llm_use_cases,
      community_count: row.community_count,
    });
  }

  db.close();
  return { status: "success", results, count: results.length };
}

function getFeature(featureId) {
  const db = getDb();
  const stmt = db.prepare("SELECT * FROM gitnexus_entity WHERE id = ?");
  const entity = stmt.get(featureId);
  if (!entity)
    return {
      status: "error",
      message: `gitnexus_entity not found: ${featureId}`,
    };

  const stmt2 = db.prepare(
    "SELECT * FROM jump_targets WHERE feature_id = ? ORDER BY (line_number IS NULL), line_number ASC, id ASC",
  );
  const jumpTargets = stmt2.all(featureId);

  let steps = [];
  if (entity.gitnexus_type === "process") {
    steps = db
      .prepare(
        `SELECT step_index AS step, symbol_id, file_path, line_number FROM process_steps WHERE feature_id = ? ORDER BY step_index ASC`,
      )
      .all(featureId);
  }

  db.close();
  return { status: "success", entity, jump_targets: jumpTargets, steps };
}

function showStatus() {
  const db = getDb();
  const byType = {};
  const stmt = db.prepare(
    "SELECT gitnexus_type, COUNT(*) AS c FROM gitnexus_entity GROUP BY gitnexus_type",
  );
  for (const row of stmt.all()) {
    byType[row.gitnexus_type] = row.c;
  }

  const stmt2 = db.prepare(
    "SELECT COUNT(*) FROM label_annotations WHERE llm_feature_name IS NOT NULL",
  );
  const annotated = stmt2.get()["COUNT(*)"];

  const stmt3 = db.prepare("SELECT COUNT(*) FROM gitnexus_entity");
  const total = stmt3.get()["COUNT(*)"];

  const procTotal = db
    .prepare(
      `SELECT COUNT(*) AS c FROM gitnexus_entity WHERE gitnexus_type='process'`,
    )
    .get().c;
  const procAnn = db
    .prepare(
      `SELECT COUNT(*) AS c FROM gitnexus_entity WHERE gitnexus_type='process'
       AND llm_feature_name IS NOT NULL AND TRIM(llm_feature_name) != ''`,
    )
    .get().c;

  db.close();
  return {
    status: "success",
    gitnexus_entity: byType,
    annotated,
    total,
    annotation_progress: `${annotated}/${total}`,
    process_llm: {
      annotated: procAnn,
      total: procTotal,
      pending: procTotal - procAnn,
    },
    db_path: DB_PATH,
  };
}

/** 清空 GitNexus 同步写入的数据（保留 label_annotations、config） */
function clearSyncedFeatures() {
  const db = getDb();
  db.exec("DELETE FROM jump_targets");
  db.exec("DELETE FROM process_steps");
  db.exec("DELETE FROM gitnexus_entity");
  db.exec("DELETE FROM symbols_cache");
  db.close();
  return {
    status: "success",
    message:
      "Cleared jump_targets, process_steps, gitnexus_entity, symbols_cache",
  };
}


/** 导出 communities 为 JSON，供 OpenCode/LLM 分析使用 */
function exportForEnrichment() {
  const db = getDb();
  const communities = db.prepare(`
    SELECT id, gitnexus_id, heuristic_label as label, gitnexus_symbol_count as symbolCount
    FROM gitnexus_entity
    WHERE gitnexus_type = 'community'
    ORDER BY gitnexus_symbol_count DESC
    LIMIT 50
  `).all();

  const result = [];
  for (const comm of communities) {
    const targets = db.prepare(`
      SELECT file_path, line_number FROM jump_targets
      WHERE feature_id = ? ORDER BY line_number LIMIT 10
    `).all(comm.id);

    result.push({
      id: comm.id,
      original_label: comm.label,
      symbolCount: comm.symbolCount,
      sampleFiles: targets.map(t => `${t.file_path}:${t.line_number}`),
    });
  }

  db.close();
  return { status: "success", communities: result, count: result.length };
}

/** 批量更新 heuristic_label（从 OpenCode/LLM 结果导入） */
function importEnrichment(jsonData) {
  const data = typeof jsonData === 'string' ? JSON.parse(jsonData) : jsonData;
  const db = getDb();
  const stmt = db.prepare(`UPDATE gitnexus_entity SET heuristic_label = ? WHERE id = ?`);
  let updated = 0;

  for (const item of data) {
    if (item.id && item.new_label) {
      stmt.run(item.new_label, item.id);
      updated++;
    }
  }

  db.close();
  return { status: "success", message: `Updated ${updated} communities` };
}

function syncAll(repoPath, options = {}) {
  const repoName = repoPath.split("/").pop() || "default";
  setRepo(repoName);
  initDatabase(repoName);
  if (options.clean) clearSyncedFeatures();
  exportGitNexus(repoPath);
  parseData(repoName);
  return {
    status: "success",
    message: `sync ${repoName} complete`,
    repo: repoName,
  };
}

/** 删除旧库文件后建表；schema 唯一来源，与 Neovim / sync 一致 */
function freshInitDatabase() {
  if (existsSync(DB_PATH)) unlinkSync(DB_PATH);
  return initDatabase();
}

function main() {
  let args = process.argv.slice(2);
  let repoArg = process.cwd().split("/").pop();
  const filtered = [];
  let skipNext = false;
  for (let i = 0; i < args.length; i++) {
    if (skipNext) {
      skipNext = false;
      continue;
    }
    if (args[i] === "sync" && args[i + 1]) {
      repoArg = args[i + 1].split("/").pop();
    } else if ((args[i] === "--repo" || args[i] === "-r") && args[i + 1]) {
      repoArg = args[i + 1];
      skipNext = true;
      continue;
    }
    filtered.push(args[i]);
  }
  args = filtered;
  setRepo(repoArg);
if (args.length < 1) {
  console.log(`
Feature Navigation Tool (fn)
============================
Usage: fn [-r <repo>] <command> [args...]

Options:
-r, --repo <name>  指定仓库名 (可从任意目录运行)

Commands (alias):
  init, i       重建空库
  sync, s [repo]    同步数据 (默认当前目录)
  sync --clean, s --clean  清空后全量同步
  label, ls, l [name]  列出/查看 labels
  label --init     初始化 label 表
  label --next     获取下一个待标注 label
  search, sr <query>  搜索 features
  status, st      查看状态
  processes, p <label>  查看某 label 下的流程
  modules, m <label>  查看跳转目标
  process-next, n [label]  下一条待标注 process
  get <id>       查看详情
  communities    所有社区列表

Examples:
  fn sync              # 同步当前目录
  fn s --clean         # 强制全量同步
  fn ls                # 列出所有 features
  fn ls Auth           # 查看 Auth 详情
  fn sr 认证           # 搜索认证相关
  fn st                # 查看状态
  fn enrich            # 导出 JSON 供 LLM 分析
  fn import-enrich <json>  # 导入 LLM 分析结果

Workflow:
  fn enrich > /tmp/communities.json  # 导出
  # 用 OpenCode/LLM 分析后
  fn import-enrich '[{"id":"comm_0","new_label":"Auth"}...]'

Install: cd ~/.agents/skills/feature-nav/scripts && npm link
  `);
  process.exit(1);
}

  const cmd = args[0];
  const aliases = {
    ls: "label",
    l: "label",
    s: "sync",
    i: "init",
    sr: "search",
    st: "status",
    p: "processes",
    m: "modules",
    n: "process-next",
  };
  const effectiveCmd = aliases[cmd] || cmd;
  let result;

  try {
    switch (effectiveCmd) {
      case "init":
        result = freshInitDatabase();
        break;
      case "sync": {
        const clean = args[1] === "--clean";
        const repo = clean
          ? args[2] || process.cwd()
          : args[1] || process.cwd();
        result = syncAll(repo, { clean });
        break;
      }
      case "label":
        if (args.length === 1) result = listLabels();
        else if (args[1] === "--init") result = initLabelTable();
        else if (args[1] === "--next") result = getNextLabel();
        else result = getLabel(args[1]);
        break;
      case "communities":
        result = listAllCommunities();
        break;
      case "save-label":
        result = saveLabelAnnotation(
          args[1],
          args[2] ? JSON.parse(args[2]) : {},
        );
        break;
      case "save-process":
        result = saveProcessAnnotation(
          args[1] || "",
          args[2] ? JSON.parse(args[2]) : {},
        );
        break;
      case "process-next":
        result = getNextUnannotatedProcess(args[1] || null);
        break;
      case "search":
        result = searchFeatures(args[1] || "");
        break;
      case "get":
        result = getFeature(args[1] || "");
        break;
      case "modules":
        result = listModulesForLabel(args[1] || "");
        break;
      case "processes":
        result = listProcessesForLabel(args[1] || "");
        break;
      case "status":
        result = showStatus();
        break;
      case "enrich":
        result = exportForEnrichment();
        break;
      case "import-enrich":
        result = importEnrichment(args[1] || "[]");
        break;
      default:
        result = { status: "error", message: `Unknown command: ${cmd}` };
    }
    console.log(JSON.stringify(result, null, 2));
  } catch (e) {
    console.log(JSON.stringify({ status: "error", message: e.message }));
    process.exit(1);
  }
}

main();
