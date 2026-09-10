# Запуск Puppeteer / Chromium

## Расположение

### Chromium
```
/usr/local/bin/chromium → /opt/chrome-linux/chrome
```

Также есть bundled Chrome от Puppeteer:
```
/home/agentuser/.cache/puppeteer/chrome/linux-146.0.7680.153/chrome-linux64/chrome
```

**НЕ использовать** `/usr/bin/chromium-browser` — это обёртка для snap, которая не работает.

### Puppeteer (node_modules)

| Путь | Проект |
|------|--------|
| `/home/agentuser/node_modules/puppeteer` | Глобальный для agentuser (рекомендуется) |
| `/work/hotel/node_modules/puppeteer` | hotel |
| `/work/projectf/projectf/node_modules/puppeteer` | projectf |
| `/work/shop/chat/node_modules/puppeteer` | shop |

### Chrome-профили с сохранёнными сессиями

| Профиль | Сессия |
|---------|--------|
| `/work/projectf/chrome-regru-profile/` | registrar.example (user@example.com) |

---

## Запуск скрипта от root

Puppeteer/Chromium не работают от root напрямую. Запускать от пользователя agentuser:

```bash
runuser -u agentuser -- env -i \
  HOME=/home/agentuser \
  PATH="/usr/local/bin:/usr/bin:/bin" \
  SHELL=/bin/bash \
  NODE_PATH=/home/agentuser/node_modules \
  node /path/to/script.js 2>&1
```

### Шаблон скрипта

```javascript
const puppeteer = require('puppeteer');

(async () => {
  const browser = await puppeteer.launch({
    headless: 'new',
    executablePath: '/usr/local/bin/chromium',
    userDataDir: '/work/projectf/chrome-regru-profile',
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--remote-debugging-port=9222'  // ← обязательно (см. правило ниже)
    ]
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 900 });

  // ... работа со страницей ...

  await browser.close();
})();
```

---

## ⚠️ ВСЕГДА запускать Chromium с `--remote-debugging-port`

**Правило:** любой запуск Chromium (через Puppeteer ИЛИ напрямую через WSLg / GUI / руками) — **обязан** включать `--remote-debugging-port=<PORT>`.

```bash
# Headed Chromium через WSLg для пользователя:
chromium --no-sandbox --remote-debugging-port=9222 https://example.com

# Puppeteer launch — добавить в args:
args: ['--no-sandbox', '--disable-setuid-sandbox', '--remote-debugging-port=9222']
```

**Зачем:**
1. **Можно подключиться к уже открытому окну** через `puppeteer.connect({ browserWSEndpoint: ... })` — без перезапуска и потери session/auth/cookies. Если пользователь логинится в окне руками, скрипт продолжает с тем же state.
2. **Скриншоты живой сессии** через CDP без X11/screen-grab костылей. WSLg `:0` не пускает root делать `import -window root`, а через DevTools-протокол — без проблем.
3. **Диагностика залогиненных страниц** — можно дёрнуть `localStorage`, `cookies`, `document.cookie` через `page.evaluate` чтобы понять реальное состояние пользователя.
4. **Без флага** Chromium не открывает DevTools websocket → подключиться нельзя → надо убить процесс и перезапустить (с потерей сессии).

**Стандартные порты:**
- `9222` — основной по умолчанию
- `9223–9229` — для нескольких параллельных Chromium-инстансов

**Подключение из скрипта:**
```javascript
// Получить browserWSEndpoint
const fetch = require('node-fetch');
const { webSocketDebuggerUrl } = await (await fetch('http://127.0.0.1:9222/json/version')).json();

const browser = await puppeteer.connect({ browserWSEndpoint: webSocketDebuggerUrl });
const pages = await browser.pages();
const page = pages.find(p => p.url().includes('ezkl.store')) || pages[0];

// ... работа со страницей пользователя без её закрытия ...

await browser.disconnect();  // ← НЕ browser.close() — чтобы не закрыть user-окно
```

**Урок:** на сессии 2026-05-01 запускал Chromium для пользователя через WSLg **без** `--remote-debugging-port`. Пользователь залогинился в открытом окне, попросил подключиться и посмотреть. Подключиться не смог — пришлось бы убить окно и перезапускать (потеря auth-state). Пришлось делать костыли через `import -window root`, которые в WSLg не работают для root. **Если бы порт был установлен с самого начала — задача решилась бы за 30 секунд через `puppeteer.connect`.**

---

## Частые проблемы

### 1. "The browser is already running for ..."

**Причина:** Chrome-профиль залочен (предыдущий процесс не завершился корректно).

**Решение:**
```bash
# Убить все chrome-процессы
pkill -f chrome

# Удалить lock-файлы
rm -f /path/to/profile/SingletonLock
rm -f /path/to/profile/DevToolsActivePort

# Если не помогает — скопировать профиль
cp -r /path/to/profile /tmp/profile-copy
rm -f /tmp/profile-copy/SingletonLock /tmp/profile-copy/DevToolsActivePort
# Использовать /tmp/profile-copy в userDataDir
```

### 2. "Cannot find module 'puppeteer'"

**Причина:** Node.js не видит puppeteer.

**Решение:** добавить `NODE_PATH`:
```bash
NODE_PATH=/home/agentuser/node_modules node script.js
```

### 3. "Command '/usr/bin/chromium-browser' requires the chromium snap"

**Причина:** Используется snap-обёртка вместо реального бинарника.

**Решение:** использовать `executablePath: '/usr/local/bin/chromium'`

### 4. "EACCES: permission denied" на скриншоты

**Причина:** Скрипт запущен от agentuser, а директория скриншотов принадлежит root.

**Решение:**
```bash
chmod -R a+rw /path/to/screenshots/
```

### 5. Сессия registrar.example истекла

**Решение:** залогиниться заново через headful-режим:
```bash
# Запустить с видимым окном (нужен X/Wayland)
# Или использовать скрипт regru_login.js из /work/projectf/
```

### 6. `Navigation timeout of 30000 ms exceeded` (особенно на mobile-главной с фоновыми запросами)

**Причина:** `waitUntil: 'networkidle2'` (или `'networkidle0'`) ждёт, пока сеть «успокоится» — не больше 2 (или 0) параллельных запросов в течение 500мс. На страницах с бесконечным фоном (websocket / SSE / long-poll чатов / live-цены / трекеры / лениво подгружаемые большие картинки hero) это условие **никогда не наступает**, и `page.goto` падает по default-таймауту 30 сек.

Наблюдалось на `ezkl.store` mobile-главной (375×812) — сетевая активность не утихает, `networkidle2` гарантированно таймаутит. На PC-viewport (1280×900) проходит чаще, но тоже не надёжно.

**Решение — `domcontentloaded` + явный sleep:**

```javascript
// Было (падает):
await page.goto(url, { waitUntil: 'networkidle2' });

// Стало (надёжно):
await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
await new Promise(r => setTimeout(r, 1500));   // дать прорисоваться целевой фиче
// или: await page.waitForSelector('.target-selector', { timeout: 10000 });
```

**Когда какой `waitUntil`:**

| Режим | Когда «загружено» | Когда использовать |
|---|---|---|
| `domcontentloaded` | HTML распарсен | **default-выбор для нашей е-com**; страница с long-poll'ом / live-обновлениями; mobile-главная ezkl.store |
| `load` | + картинки/CSS подгружены | если важно убедиться что картинки видимы (например тест hero-баннера) |
| `networkidle2` | + ≤2 параллельных запросов 500мс | статические страницы без фоновой активности (login-формы, простые landing'и) |
| `networkidle0` | + 0 запросов 500мс | редко — только полностью изолированные страницы |

**Общее правило:** для тестов на `ezkl.store` (и любого e-com с realtime-фичами) — **`domcontentloaded` + 60s timeout + явный `setTimeout` или `waitForSelector` на нужный элемент**. `networkidle*` не использовать без причины.

---

## Подход: headless vs GUI (ВАЖНО!)

Многие сайты (Resend, Palych, и др.) **блокируют headless-браузеры**. Определяют бота и отдают ошибку или капчу.

### Когда что использовать:

| Ситуация | Подход |
|----------|--------|
| Сайт без защиты от ботов (свой сайт, API) | **Headless** — быстро и просто |
| Сайт с защитой (Resend, Palych, любой SaaS) | **GUI через remote debugging** — пользователь проходит защиту вручную, скрипт подключается |
| Нужен SOCKS-прокси | Добавить `--proxy-server=socks5://127.0.0.1:1080` |

### Подход 1: Headless (автоматика)

Для сайтов без защиты. Всё делает скрипт:

```javascript
const browser = await puppeteer.launch({
  headless: 'new',
  executablePath: '/usr/local/bin/chromium',
  args: ['--no-sandbox', '--disable-setuid-sandbox']
});
```

### Подход 2: GUI + remote debugging (полуавтоматика)

Для сайтов с капчей / детекцией ботов. Схема:

**Шаг 1 — запустить GUI Chromium:**
```bash
setsid runuser -u agentuser -- env -i \
  HOME=/home/agentuser \
  PATH="/usr/local/bin:/usr/bin:/bin" \
  DISPLAY=:0 \
  /usr/local/bin/chromium --no-sandbox --disable-setuid-sandbox \
  --remote-debugging-port=9222 "https://example.com" &>/dev/null &
```

**Шаг 2 — пользователь логинится / проходит капчу в GUI**

**Шаг 3 — скрипт подключается и автоматизирует:**
```javascript
const browser = await puppeteer.connect({
  browserWSEndpoint: (await (await fetch('http://127.0.0.1:9222/json/version')).json()).webSocketDebuggerUrl
});
const pages = await browser.pages();
const page = pages.find(p => p.url().includes('example.com'));
// ... работаем со страницей ...
browser.disconnect(); // НЕ browser.close() — чтобы не закрыть GUI
```

**Важно:** при работе через remote debugging:
- `page.type()` может зависать — использовать `page.keyboard.type()` после `page.focus()`
- `element.click()` через JS (evaluate) может не работать на React — использовать `page.mouse.click(x, y)` с координатами
- При отключении: `browser.disconnect()`, а НЕ `browser.close()`

### Подход 3: GUI + SOCKS-прокси

Когда сайт блокирует по IP (например, при регистрации):

```javascript
const browser = await puppeteer.launch({
  headless: false,
  executablePath: '/usr/local/bin/chromium',
  args: [
    '--no-sandbox', '--disable-setuid-sandbox',
    '--proxy-server=socks5://127.0.0.1:1080'
  ]
});
```

### Реальные примеры (что работало, а что нет):

| Сервис | Headless | GUI | GUI + прокси | Примечание |
|--------|----------|-----|-------------|------------|
| Resend (signup) | **НЕТ** — "Something went wrong" | **ДА** | **ДА** | Детекция ботов |
| Palych (login) | **НЕТ** — капча + 2FA | **ДА** (ручная капча) | — | Скрипты: `/work/shop2/palych_*.cjs` |
| Свой сайт (example-site.test) | **ДА** | **ДА** | — | Нет защиты |
| Tuta (login) | **ДА** | **ДА** | — | Нет капчи |
| registrar.example | **ДА** (с сохранённым профилем) | **ДА** | — | Скрипты: `/work/projectf/` |

---

## Скриншоты

Скриншоты сохраняются в директорию, указанную в скрипте:
```javascript
await page.screenshot({ path: '/work/projectf/screenshots/step1.png', fullPage: true });
```

Чтение скриншота — через Claude Code (Read tool), он умеет показывать PNG.

### 🔴 Всегда снимать в JPEG, а не PNG — экономия context'а

**Правило:** для интерактивных сессий, где агент/пользователь делают много скринов и Read'ит их в чате — **снимать сразу в JPEG с quality 70-75**, не в PNG.

```javascript
// Так — НЕ делать:
await page.screenshot({ path: 'shot.png', fullPage: false });   // 200-800 KB на скрин

// Так — правильно:
await page.screenshot({ path: 'shot.jpg', type: 'jpeg', quality: 70, fullPage: false });   // 30-100 KB
```

**Зачем:**

1. **API имеет hard-лимит 2000px по длинной стороне** на изображение в multi-image conversation. При полноразмерных PNG из mobile-fullPage (375×4000+) Read tool бракует ввод с
   > "An image in the conversation exceeds the dimension limit for many-image requests (2000px). Start a new session with fewer images."

   JPEG с quality 70 при том же разрешении весит 5-10× меньше — больше скринов помещается в один turn до выхода на лимит.

2. **Context-окно агента**: каждый Read скриншота тратит токены пропорционально размеру. В долгой сессии (10-30 скринов с интерактивного guiding'а в админке/чекауте) PNG-я съест весь budget — JPEG растягивает сессию **в 5-10 раз**.

3. **UI-скрины** (админ-панель, чекаут, формы) — это flat-colors + текст. **Визуальная разница между PNG и JPEG q70 неотличима на глаз.** Артефакты JPEG заметны только на градиентах и фото — для UI-тестов это безопасно.

**Когда оставлять PNG:**
- Дизайн-ревью где важна пиксель-точность (hero-баннер, fine типографика, эффекты).
- Forensic-снимки для архива (один-два, не пачка из 20).
- Если нужно потом обрабатывать (crop, diff) — JPEG-артефакты накопятся при re-encode.

**Дополнительно для fullPage** (см. HOW_TO_RUN.md §5.5 п.6):
- `fullPage: true` на mobile (375×N где N — высота прокрутки 3000-5000px) превышает 2000px-лимит даже в JPEG.
- Перед Read'ом обязательно прогнать через resize в `thumbs/`:
  ```bash
  mkdir -p screens/thumbs
  for f in screens/*.jpg; do
      convert "$f" -resize 'x2000>' "screens/thumbs/$(basename $f)"
  done
  ```
- Альтернатива — `fullPage: false` (только viewport) + явный scroll если нужны нижние секции.

---

## Примеры рабочих скриптов

| Файл | Что делает |
|------|-----------|
| `/work/projectf/regru_change_dns.js` | Смена A-записей DNS на registrar.example |
| `/work/projectf/regru_add_dns2.js` | Добавление A-записи DNS |
| `/work/projectf/regru_login.js` | Логин в registrar.example (сохранение сессии) |
| `/work/projectf/regru_cleanup2.js` | Удаление вредоносов через ispmanager |
| `/work/shop/resend_register.cjs` | Регистрация в Resend (GUI + SOCKS) |
| `/work/shop/resend_go.cjs` | Разведка страницы Resend (GUI + SOCKS) |
| `/work/shop2/palych_login_fill.cjs` | Логин в Palych (GUI + remote debugging) |
| `/work/shop2/palych_now.cjs` | Обзор аккаунта Palych (remote debugging) |
