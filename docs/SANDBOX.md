# Песочница и запуск без неё (root / агенты)

## Что такое песочница
Claude Code выполняет Bash-команды в песочнице: урезан доступ к файловой системе и сети, а
долгоживущие/фоновые процессы прибиваются или подвешиваются (в этой системе — сигналом 16).
Это защита от случайного вреда. Но нашим инструментам (драйв AnyDesk, ssh/socks-туннели, setsid,
длинные процессы, деплой) она мешает — они «режутся», и, например, клики к AnyDesk не доходят.

## Оператор (root): команда БЕЗ песочницы
Harness запускает Bash от root. Чтобы КОНКРЕТНАЯ команда шла без песочницы — ставь у Bash-инструмента
параметр `dangerouslyDisableSandbox: true`. Когда обязательно:
- `anydesk_projecta.sh up` / сервис AnyDesk, `rustdesk --service`;
- ssh / reverse-ssh / socks-туннели, `setsid`, `sleep`, деплой на кассу/сервер;
- вообще любое «долгое» — иначе сигнал 16 его убьёт/подвесит.
Пример (концепт): вызвать Bash с `dangerouslyDisableSandbox=true` и внутри — `/work/remote_tools/anydesk_projecta.sh up`.

## Агент (claude REPL): root НЕЛЬЗЯ
`claude --dangerously-skip-permissions` ОТКАЗЫВАется стартовать от root/sudo
(«cannot be used with root/sudo privileges for security reasons»). Поэтому автономные агенты
запускаются ОТ agentuser (у него claude-auth). Единого CLI-флага «выключить песочницу глобально» у claude
нет. Чтобы у АГЕНТА команды шли без песочницы — два пути:
1. Агент САМ ставит `dangerouslyDisableSandbox: true` на свои Bash-вызовы (у его Bash-тула этот
   параметр есть). Пропиши это прямо в таск-файле: «каждый Bash-вызов с dangerouslyDisableSandbox=true».
2. Инструмент, которому нужен root, делай user-aware (ветка `if [ "$(id -un)" = agentuser ]`), чтобы он
   работал от agentuser напрямую без `runuser`/root — см. `claude/GOTCHAS.md`.

## Итого одной строкой
- «root без песочницы» = команда оператора/harness с `dangerouslyDisableSandbox: true`.
- Агент root'ом быть не может → он agentuser + per-call `dangerouslyDisableSandbox` (или user-aware инструмент).
