# market-sim 的本地运行和测试命令。在项目根目录运行（SQL 文件里有相对路径）。
#
# 第一次：   make install        安装 Python 依赖
#            make up             建库建表 + 启动全部进程（后台），然后打开 http://localhost:8000
# 看状态：   make status / make logs / make check
# 停止：     make down
# 从头来过： make reset
#
# 前提：本机已经装好并启动了 PostgreSQL（能运行 psql、createdb）。
# 常用的覆盖方式（命令后面加 变量=值）：
#   make up PY=/path/to/python3         用指定的 Python
#   make up DB=mydb                     用另一个数据库名（默认 marketsim）
#   make up SIM_ARGS="--interval-min 5 --interval-max 10"    模拟器发得更快，几分钟就能铺满几天的数据

SHELL := /bin/bash
.DEFAULT_GOAL := help

PY       ?= python3
DB       ?= marketsim
PORT     ?= 8000
INTERVAL ?= 5
SIM_ARGS ?= --interval-min 100 --interval-max 200
RUN      := .run

# 所有 Python 进程和 psql 共用同一个数据库连接串；日志不缓冲，make logs 才能实时看到
export DATABASE_URL ?= dbname=$(DB)
export PYTHONUNBUFFERED := 1
export PGOPTIONS := -c client_min_messages=warning
PSQL = psql "$(DATABASE_URL)" -v ON_ERROR_STOP=1 -q

.PHONY: help install db schema up down status logs check test backfill reset psql sim ingest processor api

help: ## 列出所有命令
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-10s %s\n", $$1, $$2}'

install: ## 安装 Python 依赖
	$(PY) -m pip install -r requirements.txt

# ---------------- 建库、建表 ----------------
db: ## 创建数据库（已经存在就跳过）
	@psql -lqt | cut -d'|' -f1 | grep -qw "$(DB)" || { createdb "$(DB)" && echo "  已创建数据库 $(DB)"; }

schema: db ## 建表、建函数、载入参考数据（可以反复运行，不会动已有的数据）
	@$(PY) ingest/ingest.py --init
	@$(PSQL) -f sql/01_instruments.sql
	@$(PSQL) -f sql/02_clean.sql
	@$(PSQL) -f sql/04_exchange_sessions.sql
	@$(PSQL) -f sql/05_gold.sql
	@$(PSQL) -f sql/07_quality.sql
	@echo "  表和函数已就绪"

# ---------------- 一条命令启动 / 停止 ----------------
# start <名字> <命令>：后台启动并把进程号记在 .run/<名字>.pid，日志写到 .run/<名字>.log；已经在运行就跳过
define start
@mkdir -p $(RUN); \
if [ -f $(RUN)/$(1).pid ] && kill -0 $$(cat $(RUN)/$(1).pid) 2>/dev/null; then echo "  $(1) 已在运行"; \
else nohup $(2) > $(RUN)/$(1).log 2>&1 < /dev/null & echo $$! > $(RUN)/$(1).pid; echo "  启动 $(1)"; fi
endef

up: schema ## 一条命令启动：模拟器 + ingest + processor + API（后台运行）
	$(call start,sim,$(PY) -m simulator $(SIM_ARGS))
	@for i in $$(seq 1 20); do nc -z 127.0.0.1 1337 2>/dev/null && break; sleep 0.5; done
	$(call start,ingest,$(PY) ingest/ingest.py)
	$(call start,processor,$(PY) pipeline/processor.py --interval $(INTERVAL))
	$(call start,api,$(PY) -m uvicorn api.main:app --port $(PORT))
	@echo ""
	@echo "  看板： http://localhost:$(PORT)      接口文档： http://localhost:$(PORT)/docs"
	@echo "  第一个整点快照出来之前（模拟时间大约要走一两个小时）页面会显示 Waiting。"
	@echo "  make status 看状态 · make logs 看日志 · make down 停止"

down: ## 停止所有进程（先停 API 和 processor，再停 ingest，最后停模拟器；ingest 会先把手里的行写完）
	@for n in api processor ingest sim; do \
	  if [ -f $(RUN)/$$n.pid ]; then p=$$(cat $(RUN)/$$n.pid); \
	    if kill -0 $$p 2>/dev/null; then kill $$p; \
	      for i in $$(seq 1 25); do kill -0 $$p 2>/dev/null || break; sleep 0.2; done; echo "  已停止 $$n"; fi; \
	    rm -f $(RUN)/$$n.pid; fi; \
	done

status: ## 每个进程是否在运行，以及数据处理到哪里
	@for n in sim ingest processor api; do \
	  if [ -f $(RUN)/$$n.pid ] && kill -0 $$(cat $(RUN)/$$n.pid) 2>/dev/null; then echo "  $$n  运行中 (pid $$(cat $(RUN)/$$n.pid))"; else echo "  $$n  未运行"; fi; \
	done
	@$(PSQL) -Atc "select '  raw 行数 ' || coalesce(max(raw_id), 0) from raw.events" 2>/dev/null || true
	@$(PSQL) -Atc "select '  clean 处理到 raw_id ' || last_raw_id from clean.process_state" 2>/dev/null || true
	@$(PSQL) -Atc "select '  gold  处理到 raw_id ' || last_raw_id || '，as_of ' || coalesce(as_of::text, '（还没有数据）') from gold.process_state" 2>/dev/null || true

logs: ## 实时查看所有进程的日志（Ctrl-C 退出）
	@tail -n 5 -f $(RUN)/*.log

check: ## 冒烟测试：各个接口能不能返回（需要先 make up）
	@for ep in status meta kpis pnl-curve contributors stocks alerts; do \
	  code=$$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$(PORT)/api/$$ep"); \
	  printf '  /api/%-14s %s\n' $$ep $$code; \
	done
	@curl -s "http://localhost:$(PORT)/api/status"; echo

test: ## 运行 Python 测试
	$(PY) -m pytest -q tests

# ---------------- 维护 ----------------
backfill: ## 清洗层和 gold 层从头重算（规则或公式改了之后用；要先 make down）
	@for n in processor ingest; do \
	  if [ -f $(RUN)/$$n.pid ] && kill -0 $$(cat $(RUN)/$$n.pid) 2>/dev/null; then echo "  请先 make down（$$n 还在运行）"; exit 1; fi; \
	done
	$(PSQL) -f sql/03_backfill.sql
	$(PSQL) -f sql/06_backfill_gold.sql

reset: down ## 删除数据库里的全部数据，从头开始（会先让你确认；加 YES=1 跳过确认）
	@[ "$(YES)" = "1" ] || { read -p "  这会删除数据库 $(DB) 的全部数据。输入 yes 继续：" a; [ "$$a" = yes ] || { echo "  已取消"; exit 1; }; }
	@dropdb --if-exists "$(DB)" && rm -rf $(RUN) && echo "  已删除数据库 $(DB)"

psql: ## 打开 psql 命令行
	@psql "$(DATABASE_URL)"

# ---------------- 单独前台运行（调试用：每个开一个终端）----------------
sim: ## 前台运行模拟器
	$(PY) -m simulator $(SIM_ARGS)

ingest: ## 前台运行 ingest
	$(PY) ingest/ingest.py

processor: ## 前台运行 processor
	$(PY) pipeline/processor.py --interval $(INTERVAL)

api: ## 前台运行 API 和看板
	$(PY) -m uvicorn api.main:app --port $(PORT)
