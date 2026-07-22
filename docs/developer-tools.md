# Developer Tools

Этот проект разрабатывается и тестируется в следующем окружении.

## Operating System

* Arch Linux (основная среда разработки)

## Shell

* Bash

## Version Control

* Git — управление версиями
* GitHub CLI (`gh`) — работа с GitHub из терминала

## Code Quality

### shellcheck

Статический анализатор Bash-скриптов.

Используется для поиска:

* потенциальных ошибок;
* неинициализированных переменных;
* небезопасных конструкций;
* проблем переносимости.

Запуск:

```bash
shellcheck main.sh lib/*.sh
```

### shfmt

Форматирование shell-скриптов в едином стиле.

Запуск:

```bash
shfmt -w .
```

или

```bash
find . -name "*.sh" -print0 | xargs -0 shfmt -w
```

## Git

Основные команды:

```bash
git status
git add .
git commit
git push
```
