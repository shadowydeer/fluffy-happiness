extends RefCounted
## Russian: title screen, co-op lobby, pause menu, settings and the field shop.
## Tables are read by RuTranslation.gd (the syntax of PATTERNS is described there).

const EXACT := {
	# --- Title screen ----------------------------------------------------------------
	"ECTO-LOGISTICS": "ЭКТО-ЛОГИСТИКА",
	"FIELD TERMINAL": "ПОЛЕВОЙ ТЕРМИНАЛ",
	"Break in. Bind the demon. Shove it in the van.": "Вломись. Свяжи демона. Запихни в фургон.",
	"PLAY SOLO": "ИГРАТЬ СОЛО",
	"HOST CO-OP": "СОЗДАТЬ КООП",
	"JOIN CO-OP": "ВОЙТИ В КООП",
	"QUIT": "ВЫХОД",
	"EXIT": "ВЫХОД",
	"SOLO: one exorcist, no backup.": "СОЛО: один экзорцист, прикрытия нет.",
	"CO-OP: 2-4 players, LAN or direct IP. No bots, ever.": "КООП: 2–4 игрока, локальная сеть или прямой IP. Ботов нет и не будет.",

	# --- Lobby -----------------------------------------------------------------------
	"LOCAL IP": "ЛОКАЛЬНЫЙ IP",
	"HOST IP ADDRESS": "IP-АДРЕС ХОСТА",
	"PORT": "ПОРТ",
	"PLAYER NAME": "ИМЯ ИГРОКА",
	"HAZMAT SUIT COLOUR": "ЦВЕТ ЗАЩИТНОГО КОСТЮМА",
	"ORANGE": "ОРАНЖ",
	"TEAL": "БИРЮЗА",
	"OLIVE": "ОЛИВА",
	"PURPLE": "ФИОЛЕТ",
	"EXORCIST": "ЭКЗОРЦИСТ",
	"HOST": "ХОСТ",
	"YOU": "ТЫ",
	"HOST, YOU": "ХОСТ, ТЫ",
	"- open seat -": "- свободное место -",
	"START CONTRACT": "НАЧАТЬ КОНТРАКТ",
	"OPEN LOBBY": "ОТКРЫТЬ ЛОББИ",
	"CONNECT": "ПОДКЛЮЧИТЬСЯ",
	"CONNECTING...": "ПОДКЛЮЧЕНИЕ...",
	"CONNECTED": "ПОДКЛЮЧЕНО",
	"BACK": "НАЗАД",
	"Enter the host's address and press CONNECT.": "Введи адрес хоста и жми «ПОДКЛЮЧИТЬСЯ».",
	"CONNECTED  -  waiting for the host to start the contract": "ПОДКЛЮЧЕНО  —  ждём, пока хост начнёт контракт",
	"Could not reach the host.": "Хост не отвечает.",
	"The host closed the session.": "Хост закрыл сессию.",
	"Check the address and port, and that the host's lobby is open.": "Проверь адрес и порт — и открыто ли у хоста лобби.",

	# --- Pause menu ------------------------------------------------------------------
	"PAUSED": "ПАУЗА",
	"RESUME": "ПРОДОЛЖИТЬ",
	"MAIN MENU": "ГЛАВНОЕ МЕНЮ",
	"QUIT TO DESKTOP": "ВЫЙТИ ИЗ ИГРЫ",
	"END SESSION & MAIN MENU": "ЗАВЕРШИТЬ СЕССИЮ И В МЕНЮ",
	"DISCONNECT & MAIN MENU": "ОТКЛЮЧИТЬСЯ И В МЕНЮ",
	"[ESC] resume": "[ESC] продолжить",
	"SOLO CONTRACT  -  the site is frozen while this is open": "СОЛО-КОНТРАКТ  —  пока меню открыто, объект стоит на паузе",
	"CO-OP  -  the contract carries on without you": "КООП  —  контракт идёт и без тебя",

	# --- Settings --------------------------------------------------------------------
	"AUDIO": "ЗВУК",
	"VOLUME": "ГРОМКОСТЬ",
	"MASTER": "ОБЩАЯ",
	"SFX": "ЭФФЕКТЫ",
	"AMBIENT": "ОКРУЖЕНИЕ",
	"LANGUAGE": "ЯЗЫК",
	"SETTINGS": "НАСТРОЙКИ",

	# --- Field shop ------------------------------------------------------------------
	"FIELD SHOP": "ПОЛЕВОЙ МАГАЗИН",
	"Field Shop": "Полевой магазин",
	"OPEN FIELD SHOP": "ОТКРЫТЬ ПОЛЕВОЙ МАГАЗИН",
	"OVERCLOCKED TASER": "РАЗОГНАННЫЙ ТАЗЕР",
	"REINFORCED HOLY LASSO": "УСИЛЕННОЕ СВЯТОЕ ЛАССО",
	"TURBO DUCT TAPE": "ТУРБОСКОТЧ",
	"SALT GRENADE PACK": "НАБОР СОЛЯНЫХ ГРАНАТ",
	"ADRENALINE AUTO-INJECTOR": "АДРЕНАЛИНОВЫЙ АВТОИНЪЕКТОР",
	"BUY": "КУПИТЬ",
	"MAXED": "МАКСИМУМ",
	"CLOSE": "ЗАКРЫТЬ",
	"OWNED": "КУПЛЕНО",
	"SOLD OUT": "РАСПРОДАНО",
	"NOT ENOUGH CASH": "НЕ ХВАТАЕТ ДЕНЕГ",
	"TEST CASH": "ТЕСТОВЫЕ ДЕНЬГИ",

	# --- Built-in text box menu ------------------------------------------------------
	"Cut": "Вырезать",
	"Copy": "Копировать",
	"Paste": "Вставить",
	"Select All": "Выделить всё",
	"Clear": "Очистить",
	"Undo": "Отменить",
	"Redo": "Повторить",
}

const PATTERNS := {
	"(%s)": "(%s)",
	"Could not open port %d (%s). Pick another port.": "Порт %d не открылся (%s). Выбери другой.",
	"LOBBY OPEN on port %d  -  waiting for players": "ЛОББИ ОТКРЫТО, порт %d  —  ждём игроков",
	"Could not start a connection to %s:%d (%s).": "Не удалось начать подключение к %s:%d (%s).",
	"CONNECTING to %s:%d ...": "ПОДКЛЮЧЕНИЕ к %s:%d ...",
	"CONNECTED PLAYERS  %d / %d": "ИГРОКИ В ЛОББИ  %d / %d",
	"HOSTING %d PLAYER(S)  -  the contract carries on; leaving ends it for everyone": "ТЫ ХОСТ, ИГРОКОВ: %d  —  контракт идёт; уйдёшь — он закончится для всех",
}
