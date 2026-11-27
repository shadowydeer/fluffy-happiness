extends RefCounted
## Russian: objectives, the HUD, the gadget belt, the crew and the demon.
## Tables are read by RuTranslation.gd (the syntax of PATTERNS is described there).
## Key names stay as printed on the key caps ([E], [F], SHIFT); the mouse and the
## space bar get their usual Russian names (ЛКМ, ПКМ, ПРОБЕЛ).

const EXACT := {
	# --- Objectives ------------------------------------------------------------------
	"Enter the cursed house & locate the demon": "ПРОНИКНИ В ДОМ И НАЙДИ ДЕМОНА",
	"Subdue the demon! [2: Holy Taser]": "СКРУТИТЬ ДЕМОНА! [2: Тазер]",
	"Bind with Duct Tape [3] & haul to the van": "ЗАМОТАЙ СКОТЧЕМ [3] И ТАЩИ В ФУРГОН!",
	"Close the van's rear doors [F] to extract!": "ЗАКРОЙ ДВЕРИ ФУРГОНА [F]!",
	"CONTRACT COMPLETE!": "КОНТРАКТ ВЫПОЛНЕН!",
	"[N] next contract": "[N] следующий контракт",
	"Open van doors [F] first": "Сначала открой двери фургона [F]",
	"DEMON CONTAINED  -  the seal is holding": "ДЕМОН ПОД ЗАМКОМ  —  печать держит",
	"something new is awake in there": "там проснулось что-то новенькое",
	"take two": "дубль два",
	"The ritual room. Something in here is breathing.": "Ритуальная комната. Здесь кто-то дышит.",

	# --- HUD captions ----------------------------------------------------------------
	"BANK": "БАНК",
	"DEMON": "ДЕМОН",
	"STUN": "СТАН",
	"BIND": "ПУТЫ",
	"HEALTH": "ЗДОРОВЬЕ",
	"STAMINA": "ДЫХАЛКА",
	"SALT": "СОЛЬ",
	"SECOND WIND  READY": "ВТОРОЕ ДЫХАНИЕ  ГОТОВО",
	"SECOND WIND  USED": "ВТОРОЕ ДЫХАНИЕ  ИСТРАЧЕНО",
	"SECOND WIND": "ВТОРОЕ ДЫХАНИЕ",
	"READY": "ГОТОВО",
	"USED": "ИСТРАЧЕНО",

	# --- Demon states and archetypes -------------------------------------------------
	"LURKING": "ТАИТСЯ",
	"STALKING": "КРАДЁТСЯ",
	"ENRAGED": "В ЯРОСТИ",
	"POLTERGEIST": "ПОЛТЕРГЕЙСТ",
	"STUNNED": "ОГЛУШЁН",
	"CAPTURED": "ПОЙМАН",
	"POSSESSING": "ВСЕЛИЛСЯ",
	"SCUTTLER": "ПОЛЗУН",
	"BRUTE": "ГРОМИЛА",
	"THE SCUTTLER": "ПОЛЗУН",
	"THE BRUTE": "ГРОМИЛА",
	"THE POLTERGEIST": "ПОЛТЕРГЕЙСТ",
	"Small, fast and never where you aimed.": "Мелкий, шустрый и вечно не там, куда ты целился.",
	"The horned one. Hits like the van and weighs about as much.": "Тот, что с рогами. Бьёт как фургон и весит примерно столько же.",
	"Half here. Kills the lights, throws the furniture and rides the crew.": "Здесь только наполовину. Гасит свет, швыряет мебель и катается на бригаде.",
	"The Stage 4 demon, exactly as it was.": "Демон образца четвёртого этапа. Каким был, таким и остался.",

	# --- Demon body parts (crosshair prompt, lasso) ----------------------------------
	"HIPS": "ТАЗ",
	"TORSO": "ТОРС",
	"HEAD": "ГОЛОВА",
	"ARM": "РУКА",
	"WRIST": "ЗАПЯСТЬЕ",
	"LEG": "НОГА",
	"ANKLE": "ЛОДЫЖКА",
	"LIMB": "КОНЕЧНОСТЬ",

	# --- Player conditions -----------------------------------------------------------
	"FLATLINING...": "СЕРДЦЕ ВСТАЛО...",
	"AUTO-INJECTOR FIRING": "АВТОИНЪЕКТОР СРАБАТЫВАЕТ",
	"SECOND WIND!": "ВТОРОЕ ДЫХАНИЕ!",
	"SECOND WIND USED — NO MORE REVIVES": "ВТОРОЕ ДЫХАНИЕ ИСТРАЧЕНО — ТРЕТЬЕГО НЕ ВЫДАЮТ",
	"POSSESSION STRUGGLE": "ДЕМОН ЛЕЗЕТ В ГОЛОВУ",
	"MASH [SPACE]!": "ДОЛБИ [ПРОБЕЛ]!",
	"mash [SPACE]": "долби [ПРОБЕЛ]",
	"or press [R]": "или жми [R]",
	"DOWN": "В НОКАУТЕ",
	"DOWNED": "ТЫ В НОКАУТЕ",
	"crawl to a crewmate  -  they hold [E] to revive you": "ползи к напарнику  —  он поднимет тебя, зажав [E]",
	"YOU ARE POSSESSED": "В ТЕБЕ ДЕМОН",
	"get to the salt circle  -  or get tased": "беги в круг соли  —  или лови разряд тазера",
	"A CREWMATE": "НАПАРНИК",
	"CREWMATE": "НАПАРНИК",
	"DOWN  -  hold [E]": "В НОКАУТЕ  —  зажми [E]",
	"DOWN  -  HOLD [E]": "В НОКАУТЕ  —  ЗАЖМИ [E]",
	"POSSESSED": "ОДЕРЖИМ",
	"YOU THREW IT OFF!": "ДЕМОН СБРОШЕН!",
	"THE VESSEL": "СОСУД",
	"the current": "помог разряд",
	"the salt": "помогла соль",
	"the salt grenade": "помогла соляная граната",
	"a salt grenade": "помогла соляная граната",

	# --- Controls hint ---------------------------------------------------------------
	"WASD move": "WASD ходьба",
	"SHIFT sprint": "SHIFT бег",
	"SPACE jump": "ПРОБЕЛ прыжок",
	"CTRL crouch": "CTRL присесть",
	"F use": "F действие",
	"Q shove": "Q толчок",
	"V camera": "V камера",
	"T torch": "T фонарь",
	"ESC menu": "ESC меню",
	"1 lasso": "1 лассо",
	"2 taser": "2 тазер",
	"3 duct tape": "3 скотч",
	"4 salt grenade": "4 соляная граната",
	"4 salt": "4 соль",
	"0 / wheel: hands": "0 / колесо: руки",
	"E always grabs by hand (hold on a downed crewmate to revive)": "E всегда хватает рукой (зажми на упавшем напарнике, чтобы поднять)",
	"LMB / E": "ЛКМ / E",
	"LMB": "ЛКМ",
	"RMB": "ПКМ",
	"SPACE": "ПРОБЕЛ",

	# --- Test keys -------------------------------------------------------------------
	"test keys": "тестовые клавиши",
	"hide test keys": "скрыть тестовые клавиши",
	"stun / wake the demon": "оглушить / разбудить демона",
	"cycle AI: lurking > enraged > poltergeist throw": "ИИ по кругу: таится > в ярости > бросок полтергейста",
	"cycle bind level 0-3": "уровень пут по кругу 0-3",
	"summon the demon in front of you": "призвать демона прямо перед собой",
	"next demon archetype": "следующий архетип демона",
	"+$1000 test cash": "+$1000 тестовых денег",
	"DEBUG": "ОТЛАДКА",
	"demon woken (stun 0)": "демон разбужен (стан 0)",
	"demon stunned (stun 100)": "демон оглушён (стан 100)",
	"demon is stunned - press K to wake it first": "демон оглушён — сначала разбуди его клавишей K",
	"the demon is sealed in the van": "демон запечатан в фургоне",
	"demon summoned": "демон призван",

	# --- Gadget belt -----------------------------------------------------------------
	"GADGET": "ГАДЖЕТ",
	"HANDS": "РУКИ",
	"HOLY LASSO": "СВЯТОЕ ЛАССО",
	"HOLY TASER": "СВЯТОЙ ТАЗЕР",
	"DUCT TAPE": "СКОТЧ",
	"SALT GRENADE": "СОЛЯНАЯ ГРАНАТА",
	"[LMB / E] Grab": "[ЛКМ / E] Взять",
	"[RMB] Throw": "[ПКМ] Бросить",
	"[RMB] Shove": "[ПКМ] Толкнуть",
	"[Q] Shove": "[Q] Толкнуть",
	"[1] Lasso": "[1] Лассо",
	"[2] Taser": "[2] Тазер",
	"[3] Duct tape": "[3] Скотч",
	"[4] Salt grenade": "[4] Соляная граната",
	"[E] Hand grab": "[E] Взять рукой",
	"release to drop": "отпусти, чтобы бросить",
	"Use": "Использовать",

	# --- Holy Lasso ------------------------------------------------------------------
	"[LMB] Hold: reel in": "[ЛКМ] Держать: подтянуть",
	"tap: let go": "клик: отпустить",
	"[RMB] Anchor to wall": "[ПКМ] Заякорить за стену",
	"[R] Detach": "[R] Отцепить",
	"[R] Release rope": "[R] Отпустить верёвку",
	"[LMB] Shoot lasso (demon, props, crewmates)": "[ЛКМ] Метнуть лассо (демон, вещи, напарники)",
	"ATTACHED": "ЗАЦЕПЛЕНО",
	"ANCHORED": "НА ЯКОРЕ",
	"Rope is anchored  -  [R] to release it": "Верёвка на якоре  —  [R], чтобы отпустить",
	"[LMB] reel in": "[ЛКМ] подтянуть",
	"[RMB] pin to a wall or post": "[ПКМ] привязать к стене или столбу",
	"Lasso dropped": "Лассо отпущено",
	"The demon tore the lasso out of your hands!": "Демон вырвал лассо у тебя из рук!",
	"Aim at a wall, post or floor within 3.5 m to anchor": "Целься в стену, столб или пол не дальше 3.5 м, чтобы заякорить",
	"ROPE ANCHORED  -  hands free": "ВЕРЁВКА НА ЯКОРЕ  —  руки свободны",
	"ROPE ANCHORED": "ВЕРЁВКА НА ЯКОРЕ",
	"THE ROPE SNAPPED!": "ВЕРЁВКА ЛОПНУЛА!",

	# --- Holy Taser ------------------------------------------------------------------
	"TASER OVERHEATED": "ТАЗЕР ПЕРЕГРЕЛСЯ",
	"TASER OVERHEATED!": "ТАЗЕР ПЕРЕГРЕЛСЯ!",
	"venting": "остывает",
	"battery drains - let it rest": "батарея садится — дай ей передохнуть",
	"OVERHEAT": "ПЕРЕГРЕВ",
	"IT SLIPS THE CURRENT  -  rope it [1] to hold it still": "ОНО УХОДИТ ОТ РАЗРЯДА  —  накинь лассо [1], чтобы не дёргалось",

	# --- Duct Tape -------------------------------------------------------------------
	"3 wraps = gift-wrapped": "3 витка = подарочная упаковка",
	"No demon to tape": "Мотать некого: демона рядом нет",
	"Fully bound  -  haul it to the van": "Замотан по полной  —  тащи в фургон",
	"Stun it [2] or anchor it with the lasso [1] first": "Сначала оглуши [2] или заякорь лассо [1]",
	"GIFT-WRAPPED!": "ПОДАРОЧНАЯ УПАКОВКА!",
	"keep wrapping": "мотай дальше",
	"IT WRENCHED FREE!  -  tape it [3] before you haul it": "ОНО ВЫРВАЛОСЬ!  —  сначала замотай [3], потом тащи",

	# --- Demon notices ---------------------------------------------------------------
	"IT ANSWERS WITH THE FURNITURE!": "ОНО ОТВЕЧАЕТ МЕБЕЛЬЮ!",
	"THE LAMPS BLOW OUT  -  headlamps on [T]": "ЛАМПЫ ГАСНУТ  —  включай фонарь [T]",
}

const PATTERNS := {
	# --- Objectives ------------------------------------------------------------------
	"CONTRACT #%04d // %s": "КОНТРАКТ №%04d // %s",
	"DONE: %s": "ГОТОВО: %s",
	"> %s": "> %s",
	"DEMON // %s": "ДЕМОН // %s",
	"[F] %s": "[F] %s",

	# --- HUD -------------------------------------------------------------------------
	"%d HP": "%d ОЗ",
	"%.1f s": "%s с",
	"[R] in %.0f s": "[R] через %s с",
	"%s IS GETTING YOU UP...": "%s ПОДНИМАЕТ ТЕБЯ...",
	"PINNED BY %s": "%s ДЕРЖИТ ТЕБЯ НА ПРИВЯЗИ",
	"ROPED BY %s": "%s ДЕРЖИТ ТЕБЯ НА ЛАССО",
	"REVIVING %s...": "ПОДНИМАЕМ: %s...",
	"CO-OP DRAG x%d": "ТАЩИМ ВМЕСТЕ x%d",
	"%s LEFT THE SITE": "%s БОЛЬШЕ НЕ НА ОБЪЕКТЕ",

	# --- Crosshair prompts -----------------------------------------------------------
	"DRAGGING DEMON (%s)": "ТАЩИШЬ ДЕМОНА ЗА {0:acc}",
	"[%s] DRAG DEMON (%s)": "[{0}] ТАЩИТЬ ДЕМОНА ЗА {1:acc}",
	"[%s] GRAB DEMON (%s)": "[{0}] СХВАТИТЬ ДЕМОНА ЗА {1:acc}",
	"[%s] Grab %s": "[{0}] Взять {1:acc}",

	# --- Crew ------------------------------------------------------------------------
	"%s IS BACK UP  -  revived by %s": "{0} СНОВА В СТРОЮ  —  спасибо, {1}",
	"%s TASED %s  -  no harm done": "{0} БЬЁТ ТОКОМ СВОИХ ({1})  —  обошлось",

	# --- Possession ------------------------------------------------------------------
	"EXORCISE %s! Tase or drag to Salt Circle!": "ДРУГ ОДЕРЖИМ! БЕЙ ТАЗЕРОМ ИЛИ ТАЩИ В КРУГ СОЛИ!",
	"%s IS POSSESSED!": "В %s ВСЕЛИЛСЯ ДЕМОН!",
	"THE DEMON CLIMBS BACK OUT OF %s": "ДЕМОН ВЫЛЕЗАЕТ ОБРАТНО  —  %s СНОВА БЕЗ ПАССАЖИРА",
	"%s IS CLEAN  -  %s drove it out. It is down: tape it!": "{0}: ДЕМОН ИЗГНАН  —  {1}. Он в отключке: мотай скотчем!",
	"IT GOT INSIDE YOUR HEAD  -  %d HP, gear dropped: re-equip!": "ОНО ПОБЫВАЛО У ТЕБЯ В ГОЛОВЕ  —  минус %d ОЗ, снаряга на полу: бери заново!",

	# --- Holy Lasso ------------------------------------------------------------------
	"%s slipped your rope": "Лассо соскочило с цели: %s",
	"LASSO ON THE DEMON (%s)": "ЛАССО НА ДЕМОНЕ: {0}",
	"LASSO ON %s": "ЛАССО ДЕРЖИТ {0:acc}",
	"LASSO ON %s  -  [LMB] reel in   [RMB] pin to a wall or post": "ЛАССО ДЕРЖИТ {0}  —  [ЛКМ] подтянуть   [ПКМ] привязать к стене или столбу",
	"%s HAS A ROPE ON YOU  -  mash [SPACE], or [R] after 2 s": "%s ДЕРЖИТ ТЕБЯ НА ЛАССО  —  долби [ПРОБЕЛ] или жми [R] через 2 с",
	"%s IS PINNED  -  [R] lets them go": "%s НА ПРИВЯЗИ  —  [R], чтобы отпустить",
	"PINNED BY %s  -  mash [SPACE], or [R] after 2 s": "%s ДЕРЖИТ ТЕБЯ НА ПРИВЯЗИ  —  долби [ПРОБЕЛ] или жми [R] через 2 с",
	"Aim at a wall, post or floor within %.1f m to anchor": "Целься в стену, столб или пол не дальше %s м, чтобы заякорить",

	# --- Holy Taser ------------------------------------------------------------------
	"[LMB] Hold to shock (%.1f m)": "[ЛКМ] Держать: бить током (%s м)",

	# --- Duct Tape -------------------------------------------------------------------
	"[LMB] Hold to wrap a stunned demon (%.1f m)": "[ЛКМ] Держать: мотать оглушённого демона (%s м)",
	"BINDING DEMON... %d/%d": "МОТАЕМ ДЕМОНА... %d/%d",
	"Get within %.1f m of the demon to tape it": "Подойди к демону на %s м, чтобы замотать",
	"BIND %d/%d": "ПУТЫ %d/%d",
	"IT TORE THE TAPE OFF!  bind %d/3  -  tape it properly before you haul": "ОНО СОРВАЛО СКОТЧ!  путы %d/3  —  замотай как следует, потом тащи",

	# --- Test keys -------------------------------------------------------------------
	"no loose props within %d m to throw": "в радиусе %d м нечем швыряться",
	"demon state: %s": "состояние демона: %s",
	"bind level %d / 3": "уровень пут %d / 3",
}
