{# 几列组合起来唯一（用来检查"粒度"）：返回重复的组合，有一行就算失败 #}
{% test unique_combination(model, columns) %}
select {{ columns | join(', ') }}, count(*) as n
from {{ model }}
group by {{ columns | join(', ') }}
having count(*) > 1
{% endtest %}
