-- 参考数据：各交易所的交易时段（UTC，周一到周五）。
-- 用途：判断一只股票"现在是不是在交易时段"。只有在交易时段里，价格长时间不更新才算"陈旧"。
-- 和 instruments 一样是静态参考数据，可以反复运行。数值和 simulator/market.py 里的 SESSIONS_UTC 一致。
-- 运行：psql marketsim -v ON_ERROR_STOP=1 -f sql/04_exchange_sessions.sql

create schema if not exists clean;

create table if not exists clean.exchange_sessions (
    exchange  text primary key,
    open_utc  time not null,
    close_utc time not null
);

insert into clean.exchange_sessions (exchange, open_utc, close_utc) values
    ('XTKS', '00:00', '06:00'),   -- 东京
    ('XAMS', '08:00', '16:30'),   -- 阿姆斯特丹
    ('XETR', '08:00', '16:30'),   -- 法兰克福
    ('XPAR', '08:00', '16:30'),   -- 巴黎
    ('XLON', '08:00', '16:30'),   -- 伦敦
    ('XNYS', '14:30', '21:00')    -- 纽约
on conflict (exchange) do update
    set open_utc = excluded.open_utc, close_utc = excluded.close_utc;
