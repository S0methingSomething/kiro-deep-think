# Kiro Deep Thinker Agent

A reasoning-first Kiro CLI agent that uses sequential thinking for extensive research, planning, and iterative code improvement.

## Features

- Sequential thinking with branching and revision
- Interweaved research and code iteration
- Production-ready task manager with full history
- BM25 + MMR semantic search
- Smart context retrieval
- Scales 5-35 thoughts by complexity

## Installation

bash
curl -fsSL https://raw.githubusercontent.com/S0methingSomething/
kiro-deep-thinker/main/install.sh | bash

Or manually:
bash
git clone https://github.com/S0methingSomething/kiro-deep-thinker
cd kiro-deep-thinker
./install.sh

## Usage

bash
kiro-cli chat --agent deep-thinker

## Requirements

- Kiro CLI installed and authenticated
- Python 3 (for advanced search features)
- jq (for task manager)
