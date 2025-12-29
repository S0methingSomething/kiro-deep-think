#!/usr/bin/env python3
"""
Task Manager LLM Context Extension
BM25 + Embeddings + MMR for smart task retrieval
"""
import argparse
import json
import math
import os
import re
import sqlite3
from datetime import datetime
from pathlib import Path

WORD_RE = re.compile(r"[A-Za-z0-9_]{2,}")

def iso_to_epoch(s: str | None) -> float:
    if not s:
        return 0.0
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except:
        return 0.0

def tokenize(text: str) -> set[str]:
    return set(t.lower() for t in WORD_RE.findall(text or ""))

def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)

def task_to_doc(t: dict) -> dict:
    updates = t.get("updates") or []
    updates_text = "\n".join((u.get("content") or u.get("note") or "") for u in updates[-10:])
    blockers_text = "\n".join(b.get("desc", "") for b in (t.get("blockers") or []) if b.get("status") == "open")
    dod_text = "\n".join(t.get("definition_of_done") or [])
    subtasks_text = "\n".join(s.get("title", "") for s in (t.get("subtasks") or []))                                        
    full_text = f"{t.get('title', '')} {t.get('details', '')} {updates_text} {blockers_text} {dod_text} {subtasks_text}"

    timestamps = [iso_to_epoch(t.get("created")), iso_to_epoch(t.get("started"))]
    timestamps += [iso_to_epoch(u.get("time")) for u in updates if u.get("time")]
    last_touch = max(timestamps) if timestamps else 0

    open_blockers = sum(1 for b in (t.get("blockers") or []) if b.get("status") == "open")

    return {
        "id": t["id"],
        "status": t.get("status", "pending"),
        "priority": t.get("priority", "medium"),
        "progress": t.get("progress") or 0,
        "next_action": t.get("next_action"),
        "if_blocked_then": t.get("if_blocked_then"),
        "title": t.get("title", ""),
        "details": t.get("details", ""),
        "full_text": full_text,
        "last_touch": last_touch,
        "open_blockers": open_blockers,
        "raw": t,
        "tokens": tokenize(full_text),
    }

def ensure_schema(conn: sqlite3.Connection):
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS tasks_meta(
            id TEXT PRIMARY KEY,
            status TEXT,
            priority TEXT,
            last_touch REAL,
            open_blockers INTEGER,
            next_action TEXT,
            raw_json TEXT
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS tasks_fts USING fts5(
            id UNINDEXED,                                                 title,
            details,                                                      full_text,
            tokenize = 'porter'                                       );
    """)                                                      
def rebuild_index(conn: sqlite3.Connection, tasks: list[dict]):
    ensure_schema(conn)                                           conn.execute("DELETE FROM tasks_meta")
    conn.execute("DELETE FROM tasks_fts")

    for t in tasks:                                                   d = task_to_doc(t)
        conn.execute(                                                     "INSERT INTO tasks_meta VALUES(?,?,?,?,?,?,?)",
            (d["id"], d["status"], d["priority"], d["last_touch"], d["open_blockers"], d["next_action"] or "", json.dumps(d["raw"]))                                                              )
        conn.execute(                                                     "INSERT INTO tasks_fts(id, title, details, full_text) VALUES(?,?,?,?)",                                                     (d["id"], d["title"], d["details"], d["full_text"])
        )
    conn.commit()

def bm25_search(conn: sqlite3.Connection, query: str, limit: int = 50) -> dict[str, float]:
    if not query.strip():
        return {}

    # Escape special FTS5 characters
    safe_query = re.sub(r'[^\w\s]', ' ', query)
    terms = safe_query.split()
    if not terms:
        return {}

    fts_query = " OR ".join(terms)

    try:
        cur = conn.execute(
            "SELECT id, bm25(tasks_fts, 10.0, 5.0, 1.0) AS score FROM tasks_fts WHERE tasks_fts MATCH ? ORDER BY score LIMIT ?",
            (fts_query, limit)
        )
        return {row[0]: -row[1] for row in cur.fetchall()}  # bm25 returns negative, flip it                                    except:
        return {}

def compute_actionability(d: dict) -> float:                      score = 1.0                                               
    # Status
    if d["status"] == "in-progress":
        score += 2.0
    elif d["status"] == "blocked":
        score -= 1.0

    # Has next action                                             if d.get("next_action"):
        score += 1.5

    # Priority
    score += {"high": 1.5, "medium": 0.5, "low": 0.0}.get(d["priority"], 0.0)
                                                                  # Blockers demote
    if d["open_blockers"] > 0:
        score -= 1.5
                                                                  # Progress bonus (partially done = momentum)                  progress = d.get("progress") or 0
    if 10 < progress < 90:
        score += 0.5

    return max(0.1, score)                                    
def compute_recency(d: dict) -> float:
    if not d["last_touch"]:
        return 0.1

    import time
    days_ago = (time.time() - d["last_touch"]) / 86400            return math.exp(-days_ago / 14)  # Decay over ~2 weeks

def mmr_select(candidates: list[dict], k: int, lam: float = 0.7) -> list[dict]:
    """Maximal Marginal Relevance: balance relevance with diversity"""
    if not candidates:                                                return []
                                                                  selected = []
    remaining = candidates[:]                                 
    while remaining and len(selected) < k:
        best_item = None
        best_score = float('-inf')

        for item in remaining:
            relevance = item["_score"]

            # Max similarity to already selected
            max_sim = 0.0
            for sel in selected:
                sim = jaccard(item["tokens"], sel["tokens"])
                max_sim = max(max_sim, sim)

            # MMR score
            mmr = lam * relevance - (1 - lam) * max_sim

            if mmr > best_score:
                best_score = mmr
                best_item = item

        if best_item:
            selected.append(best_item)
            remaining.remove(best_item)

    return selected

def llm_context(task_file: str, index_db: str, query: str = "", k: int = 8, mode: str = "execute") -> dict:
    with open(task_file, "r") as f:
        root = json.load(f)

    tasks = root.get("tasks") or []
    active = [t for t in tasks if t.get("status") not in ("done", "canceled")]

    # Mode pre-filters
    if mode == "unblock":
        active = [t for t in active if any(b.get("status") == "open" for b in (t.get("blockers") or []))]                       elif mode == "wip":
        active = [t for t in active if t.get("status") == "in-progress"]                                                    
    if not active:
        return {"project": root.get("project", ""), "mode": mode, "query": query, "tasks": []}

    # Build/refresh index
    conn = sqlite3.connect(index_db)
    rebuild_index(conn, active)

    # Get BM25 scores if query provided
    bm25_scores = bm25_search(conn, query, limit=50)

    # Score all tasks
    docs = [task_to_doc(t) for t in active]

    for d in docs:
        # Relevance: BM25 if query, else 1.0
        if query.strip():
            relevance = bm25_scores.get(d["id"], 0.0)
            if relevance == 0:
                # Fallback: simple text match
                if query.lower() in d["full_text"].lower():
                    relevance = 0.5
        else:
            relevance = 1.0

        actionability = compute_actionability(d)
        recency = compute_recency(d)                          
        # Composite score
        if mode == "recent":
            d["_score"] = recency
        elif mode == "plan":
            d["_score"] = actionability * 0.8 + recency * 0.2
        else:  # execute                                                  d["_score"] = (relevance * 0.4 + actionability * 0.4 + recency * 0.2) if query else (actionability * 0.6 + recency * 0.4)

    # Filter zero-relevance if query provided
    if query.strip():
        docs = [d for d in docs if d["_score"] > 0]

    # Sort and apply MMR
    docs.sort(key=lambda x: x["_score"], reverse=True)
    selected = mmr_select(docs[:30], k=k, lam=0.75)

    conn.close()
                                                                  return {
        "project": root.get("project", ""),
        "description": root.get("description", ""),
        "mode": mode,                                                 "query": query,
        "tasks": [
            {
                "id": d["id"],
                "title": d["title"],
                "priority": d["priority"],                                    "status": d["status"],
                "progress": d["progress"],
                "score": round(d["_score"], 2),
                "next_action": d.get("next_action"),
                "if_blocked_then": d.get("if_blocked_then"),                  "open_blockers": d["open_blockers"],
                "recent_updates": (d["raw"].get("updates") or [])[-3:],                                                                 }
            for d in selected
        ]
    }

def main():
    parser = argparse.ArgumentParser(description="Smart LLM context retrieval")
    parser.add_argument("--task-file", required=True, help="Path to tasks JSON")
    parser.add_argument("--index-db", required=True, help="Path to SQLite index")                                               parser.add_argument("--query", default="", help="Search query")
    parser.add_argument("--k", type=int, default=8, help="Number of tasks to return")
    parser.add_argument("--mode", choices=["execute", "plan", "unblock", "recent", "wip"], default="execute")
    args = parser.parse_args()

    result = llm_context(args.task_file, args.index_db, args.query, args.k, args.mode)
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
