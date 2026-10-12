# Local run and test commands for market-sim. Run from the project root (the SQL files use relative paths).
#
# First time:   make install        install runtime dependencies
# Testing:      make install-dev    install runtime + test dependencies
#            make up             create database and tables + start all processes (in the background), then open http://localhost:8000
# Check state:   make status / make logs / make check
# Stop:     make down
# Start over: make reset
#
# Prerequisite: PostgreSQL is installed and running locally (psql and createdb work).
# Common overrides (append VARIABLE=value to the command):
#   make up PY=/path/to/python3         use a specific Python
#   make up DB=mydb                     use another database name (default marketsim)
#   make up SIM_ARGS="--interval-min 5 --interval-max 10"    a faster simulator: a few minutes fill several days of data

SHELL := /bin/bash
.DEFAULT_GOAL := help

PY       ?= python3
DB       ?= marketsim
PORT     ?= 8000
INTERVAL ?= 5
SIM_ARGS ?= --interval-min 100 --interval-max 200
RUN      := .run

# All Python processes and psql share one database connection string; logs are unbuffered so make logs shows them live
export DATABASE_URL ?= dbname=$(DB)
export PYTHONUNBUFFERED := 1
export PGOPTIONS := -c client_min_messages=warning
PSQL = psql "$(DATABASE_URL)" -v ON_ERROR_STOP=1 -q

.PHONY: help install install-dev db schema up down status logs check test backfill reset psql sim ingest processor api

help: ## list all commands
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-10s %s\n", $$1, $$2}'

install: ## install Python dependencies
	$(PY) -m pip install -r requirements.txt

install-dev: ## install runtime and test dependencies
	$(PY) -m pip install -r requirements-dev.txt

# ---------------- create database and tables ----------------
db: ## create the database (skipped if it exists)
	@psql -lqt | cut -d'|' -f1 | grep -qw "$(DB)" || { createdb "$(DB)" && echo "  已创建数据库 $(DB)"; }

schema: db ## create tables and functions, load reference data (safe to repeat, existing data is untouched)
	@$(PY) ingest/ingest.py --init
	@$(PSQL) -f sql/clean/install.sql
	@$(PSQL) -f sql/gold/install.sql
	@echo "  表和函数已就绪"

# ---------------- start / stop with one command ----------------
# start <name> <command>: start in the background, record the pid in .run/<name>.pid, log to .run/<name>.log; skipped if already running
define start
@mkdir -p $(RUN); \
if [ -f $(RUN)/$(1).pid ] && kill -0 $$(cat $(RUN)/$(1).pid) 2>/dev/null; then echo "  $(1) 已在运行"; \
else nohup $(2) > $(RUN)/$(1).log 2>&1 < /dev/null & echo $$! > $(RUN)/$(1).pid; echo "  启动 $(1)"; fi
endef

up: schema ## start everything: simulator + ingest + processor + API (in the background)
	$(call start,sim,$(PY) -m simulator $(SIM_ARGS))
	@for i in $$(seq 1 20); do nc -z 127.0.0.1 1337 2>/dev/null && break; sleep 0.5; done
	$(call start,ingest,$(PY) ingest/ingest.py)
	$(call start,processor,$(PY) pipeline/processor.py --interval $(INTERVAL))
	$(call start,api,$(PY) -m uvicorn api.main:app --port $(PORT))
	@echo ""
	@echo "  看板： http://localhost:$(PORT)      接口文档： http://localhost:$(PORT)/docs"
	@echo "  第一个整点快照出来之前（模拟时间大约要走一两个小时）页面会显示 Waiting。"
	@echo "  make status 看状态 · make logs 看日志 · make down 停止"

down: ## stop all processes (API and processor first, then ingest, then the simulator; ingest writes the rows in hand first)
	@for n in api processor ingest sim; do \
	  if [ -f $(RUN)/$$n.pid ]; then p=$$(cat $(RUN)/$$n.pid); \
	    if kill -0 $$p 2>/dev/null; then kill $$p; \
	      for i in $$(seq 1 25); do kill -0 $$p 2>/dev/null || break; sleep 0.2; done; echo "  已停止 $$n"; fi; \
	    rm -f $(RUN)/$$n.pid; fi; \
	done

status: ## whether each process is running, and how far the data has been processed
	@for n in sim ingest processor api; do \
	  if [ -f $(RUN)/$$n.pid ] && kill -0 $$(cat $(RUN)/$$n.pid) 2>/dev/null; then echo "  $$n  运行中 (pid $$(cat $(RUN)/$$n.pid))"; else echo "  $$n  未运行"; fi; \
	done
	@$(PSQL) -Atc "select '  raw 行数 ' || coalesce(max(raw_id), 0) from raw.events" 2>/dev/null || true
	@$(PSQL) -Atc "select '  clean 处理到 raw_id ' || last_raw_id from clean.process_state" 2>/dev/null || true
	@$(PSQL) -Atc "select '  gold  处理到 raw_id ' || last_raw_id || '，watermark ' || coalesce(nullif(watermark::text, '-infinity'), '（还没有数据）') from gold.process_state" 2>/dev/null || true

logs: ## follow the logs of all processes live (Ctrl-C to exit)
	@tail -n 5 -f $(RUN)/*.log

check: ## smoke test: does each endpoint respond (run make up first)
	@for ep in status meta kpis pnl-curve contributors stocks; do \
	  code=$$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$(PORT)/api/$$ep"); \
	  printf '  /api/%-14s %s\n' $$ep $$code; \
	done
	@curl -s "http://localhost:$(PORT)/api/status"; echo

test: ## run the Python tests
	$(PY) -m pytest -q tests

# ---------------- maintenance ----------------
backfill: ## recompute the clean and gold layers from scratch (use after rules or formulas change; run make down first)
	@for n in processor ingest; do \
	  if [ -f $(RUN)/$$n.pid ] && kill -0 $$(cat $(RUN)/$$n.pid) 2>/dev/null; then echo "  请先 make down（$$n 还在运行）"; exit 1; fi; \
	done
	$(PSQL) -f sql/clean/backfill.sql
	$(PSQL) -f sql/gold/backfill.sql

reset: ## delete all data in the database and start over (asks for confirmation; add YES=1 to skip)
	@[ "$(YES)" = "1" ] || { read -p "  这会删除数据库 $(DB) 的全部数据。输入 yes 继续：" a; [ "$$a" = yes ] || { echo "  已取消"; exit 1; }; }
	@dropdb --if-exists "$(DB)" && rm -rf $(RUN) && echo "  已删除数据库 $(DB)"

psql: ## open the psql command line
	@psql "$(DATABASE_URL)"

# ---------------- run one process in the foreground (for debugging: one terminal each) ----------------
sim: ## run the simulator in the foreground
	$(PY) -m simulator $(SIM_ARGS)

ingest: ## run ingest in the foreground
	$(PY) ingest/ingest.py

processor: ## run the processor in the foreground
	$(PY) pipeline/processor.py --interval $(INTERVAL)

api: ## run the API and dashboard in the foreground
	$(PY) -m uvicorn api.main:app --port $(PORT)
