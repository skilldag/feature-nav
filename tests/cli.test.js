#!/usr/bin/env node
const { execSync } = require("child_process");
const path = require("path");

const TOOL = path.join(__dirname, "../feature-tool.js");

function run(cmd) {
  const fullCmd = `node ${TOOL} ${cmd}`;
  console.log(`$ ${fullCmd}`);
  try {
    const out = execSync(fullCmd, { encoding: "utf-8" });
    console.log(out);
    return JSON.parse(out);
  } catch (e) {
    console.error("ERROR:", e.message);
    return null;
  }
}

console.log("=== CLI Tests ===\n");

console.log("Test 1: status");
const st = run("st");
console.log("status OK:", st?.status === "success");

console.log("\nTest 2: ls");
const ls = run("ls");
console.log("ls OK:", ls?.status === "success");

console.log("\n=== Tests Complete ===");
