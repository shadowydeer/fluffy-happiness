extends RefCounted
## Russian: the contract summary card, the payout lines and head office's incident reports.
## Tables are read by RuTranslation.gd (the syntax of PATTERNS is described there).

const EXACT := {
	# --- Summary card ----------------------------------------------------------------
	"EXTRACTION REPORT": "ОТЧЁТ О ВЫВОЗЕ",
	"INCIDENT REPORT": "АКТ О ПРОИСШЕСТВИИ",
	"TOTAL PAYOUT": "ИТОГО К ВЫПЛАТЕ",
	"NEXT CONTRACT": "СЛЕДУЮЩИЙ КОНТРАКТ",
	"RETRY CONTRACT": "ПЕРЕИГРАТЬ КОНТРАКТ",
	"KEEP EXPLORING": "ОСМОТРЕТЬСЯ",
	"WAITING FOR HOST...": "ЖДЁМ ХОСТА...",
	"[ENTER] next contract": "[ENTER] следующий контракт",
	"[ENTER] retry contract": "[ENTER] переиграть контракт",
	"[ESC] keep exploring": "[ESC] осмотреться",
	"the host decides whether to go again": "переигрывать или нет — решает хост",
	"the host starts the next contract": "следующий контракт запускает хост",
	"DEMON EXTRACTED": "ДЕМОН ВЫВЕЗЕН",
	"CREW DOWN": "БРИГАДА ПОЛЕГЛА",
	"DEMON AT LARGE": "ДЕМОН НА СВОБОДЕ",

	# --- Payout lines ----------------------------------------------------------------
	"Base capture bounty": "Базовая награда за поимку",
	"Speed bonus": "Бонус за скорость",
	"Gift-wrapped!": "Подарочная упаковка!",
	"Property": "Имущество",
	"INTACT PROPERTY BONUS": "БОНУС ЗА ЦЕЛОЕ ИМУЩЕСТВО",

	# --- Incident report: what happened ----------------------------------------------
	"Crew found resting face-down on site. Unpaid.": "Бригада обнаружена на объекте: отдыхает лицом в пол. Отдых не оплачивается.",
	"Entire team horizontal at time of inspection.": "На момент проверки весь личный состав пребывал в горизонтальном положении.",
	"Demon reports the exorcists 'gave up first'.": "Со слов демона, экзорцисты «сдались первыми». Показания записаны верно.",
	"All personnel temporarily reclassified as furniture.": "Весь персонал временно переведён в категорию «мебель».",
	"Demon at large, untaped, and now aware of our methods.": "Демон на свободе, не замотан и теперь в курсе наших методов.",
	"One auto-injector expended. It was the only one.": "Израсходован один автоинъектор. Он же был последним.",

	# --- Incident report: head office's remarks --------------------------------------
	"The client has asked for the demon's contact details instead.": "Клиент попросил лучше оставить ему контакты демона.",
	"Hazmat suits are a deductible item. So is the demon.": "Стоимость защитных костюмов вычитается из зарплаты. Стоимость демона — тоже.",
	"Head office reminds staff that the tape goes ON the demon.": "Главный офис напоминает сотрудникам: скотч клеится НА демона.",
	"Please stop letting it throw the good chairs.": "Убедительная просьба: перестаньте давать ему швыряться хорошими стульями.",
	"A strongly worded sigil has been added to your file.": "В ваше личное дело внесена сигила в крайне резких выражениях.",
}

const PATTERNS := {
	"CONTRACT #%04d COMPLETE": "КОНТРАКТ №%04d ВЫПОЛНЕН",
	"CONTRACT #%04d FAILED": "КОНТРАКТ №%04d ПРОВАЛЕН",
	"TIME %02d:%02d": "ВРЕМЯ %02d:%02d",
	"Binding bonus (%d/3)": "Бонус за обмотку (%d/3)",
	"HOUSE TRASHED  (%d props wrecked - the landlord will be in touch)": "ДОМ РАЗГРОМЛЕН  (в хлам: {0} {0|вещь|вещи|вещей} — хозяин с вами свяжется)",
	"PROPERTY CARE  (%d scuffed)": "БЕРЕЖНОЕ ОБРАЩЕНИЕ  (поцарапано: %d)",
	"ROUGHED UP  (%d props knocked about)": "ДОМ ПОТРЁПАН  (помято: {0} {0|вещь|вещи|вещей})",
	"Demon last seen wearing %d wrap(s) of company tape. Tape not recovered.": "В последний раз демона видели в {0} {0|витке|витках|витках} казённого скотча. Скотч на склад не возвращён.",
	"%d household item(s) used as ammunition against staff.": "Предметов быта, израсходованных на персонал в качестве боеприпасов: %d.",
	"%d exorcists down at once. Nobody left to do the reviving.": "В нокауте одновременно {0} {0|экзорцист|экзорциста|экзорцистов}. Поднимать их было уже некому.",
}
