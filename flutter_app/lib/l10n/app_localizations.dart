import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

  static List<LocalizationsDelegate> get localizationsDelegates {
    return [
      delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ];
  }

  static const supportedLocales = [Locale('en'), Locale('ru')];

  bool get isRu => locale.languageCode == 'ru';

  String localeName(String code) {
    switch (code) {
      case 'en': return 'English';
      case 'ru': return 'Русский';
      default: return code;
    }
  }

  String get account => isRu ? 'Аккаунт' : 'Account';
  String get chats => isRu ? 'Чаты' : 'Chats';
  String get communities => isRu ? 'Сообщества' : 'Communities';
  String get calls => isRu ? 'Звонки' : 'Calls';
  String get settings => isRu ? 'Настройки' : 'Settings';
  String get theme => isRu ? 'Тема' : 'Theme';
  String get language => isRu ? 'Язык' : 'Language';
  String get switchAccount => isRu ? 'Сменить аккаунт' : 'Switch account';
  String get displayName => isRu ? 'Отображаемое имя' : 'Display name';
  String get bio => isRu ? 'О себе' : 'Bio';
  String get custom => isRu ? 'Пользовательская' : 'Custom';
  String get editMessage => isRu ? 'Редактировать сообщение' : 'Edit message';
  String get typeMessage => isRu ? 'Сообщение...' : 'Type a message...';
  String get send => isRu ? 'Отправить' : 'Send';
  String get cancel => isRu ? 'Отмена' : 'Cancel';
  String get save => isRu ? 'Сохранить' : 'Save';
  String get delete => isRu ? 'Удалить' : 'Delete';
  String get edit => isRu ? 'Редактировать' : 'Edit';
  String get reply => isRu ? 'Ответить' : 'Reply';
  String get replyToYourself => isRu ? 'Ответ себе' : 'Reply to yourself';
  String get replyToMessage => isRu ? 'Ответ на сообщение' : 'Reply to message';
  String get replyTo => isRu ? 'Ответ' : 'Reply to';
  String get messageDeleted => isRu ? 'Сообщение удалено' : 'Message deleted';
  String get noMessagesYet => isRu ? 'Пока нет сообщений' : 'No messages yet';
  String get online => isRu ? 'В сети' : 'Online';
  String get offline => isRu ? 'Не в сети' : 'Offline';
  String get typing => isRu ? 'печатает...' : 'typing...';
  String get newChat => isRu ? 'Новый чат' : 'New chat';
  String get newGroup => isRu ? 'Новая группа' : 'New group';
  String get search => isRu ? 'Поиск' : 'Search';
  String get loading => isRu ? 'Загрузка...' : 'Loading...';
  String get error => isRu ? 'Ошибка' : 'Error';
  String get retry => isRu ? 'Повторить' : 'Retry';
  String get copy => isRu ? 'Копировать' : 'Copy';
  String get deleteForever => isRu ? 'Удалить навсегда' : 'Delete forever';
  String get logout => isRu ? 'Выйти' : 'Log out';
  String get logOutConfirm => isRu ? 'Вы уверены, что хотите выйти?' : 'Are you sure you want to log out?';
  String get confirm => isRu ? 'Подтвердить' : 'Confirm';
  String get information => isRu ? 'Информация' : 'Information';
  String get mute => isRu ? 'Выключить звук' : 'Mute';
  String get unmute => isRu ? 'Включить звук' : 'Unmute';
  String get joined => isRu ? 'Присоединился' : 'Joined';
  String get copyDebugLogs => isRu ? 'Копировать логи' : 'Copy debug logs';
  String get logsCopied => isRu ? 'Логи скопированы' : 'Logs copied to clipboard';
  String get entries => isRu ? 'записей' : 'entries';
  String get failedToSend => isRu ? 'Не удалось отправить' : 'Failed to send';
  String get fileTooLarge => isRu ? 'Файл слишком большой (макс. 10МБ)' : 'File too large (max 10MB)';
  String get uploadFailed => isRu ? 'Ошибка загрузки' : 'Upload failed';
  String get messageTooLong => isRu ? 'Сообщение слишком длинное' : 'Message too long';
  String get editMessageHint => isRu ? 'Редактировать сообщение...' : 'Edit message...';
  String get editingMessage => isRu ? 'Редактирование сообщения' : 'Editing message';
  String get recording => isRu ? 'Запись...' : 'Recording...';
  String get startRecording => isRu ? 'Начать запись' : 'Start recording';
  String get stopRecording => isRu ? 'Остановить запись' : 'Stop recording';
  String get pickFromGallery => isRu ? 'Галерея' : 'Gallery';
  String get takePhoto => isRu ? 'Камера' : 'Camera';
  String get attachFile => isRu ? 'Файл' : 'File';
  String get attachMedia => isRu ? 'Прикрепить' : 'Attach';
  String get username => isRu ? 'Имя пользователя' : 'Username';
  String get password => isRu ? 'Пароль' : 'Password';
  String get login => isRu ? 'Войти' : 'Login';
  String get register => isRu ? 'Регистрация' : 'Register';
  String get noAccount => isRu ? 'Нет аккаунта?' : "Don't have an account?";
  String get haveAccount => isRu ? 'Уже есть аккаунт?' : 'Already have an account?';
  String get authError => isRu ? 'Ошибка входа' : 'Authentication error';
  String get usernameRequired => isRu ? 'Имя пользователя (мин. 3 символа)' : 'Username (min 3 characters)';
  String get passwordRequired => isRu ? 'Пароль (мин. 6 символов)' : 'Password (min 6 characters)';
  String get invalidCredentials => isRu ? 'Неверное имя пользователя или пароль' : 'Invalid username or password';
  String minChars(int n) => isRu ? 'Минимум $n символа' : 'Minimum $n characters';
  String maxChars(int n) => isRu ? 'Максимум $n символов' : 'Maximum $n characters';
  String get onlyLetters => isRu ? 'Только буквы, цифры и _' : 'Only letters, numbers and _';

  String get failedToLoadMessages => isRu ? 'Не удалось загрузить сообщения' : 'Failed to load messages';
  String get deleteChat => isRu ? 'Удалить чат' : 'Delete chat';
  String get deleteChatConfirm => isRu ? 'Удалить этот чат?' : 'Delete this chat?';
  String get deleteChatLocalOnly => isRu ? 'Чат будет удалён только у вас. Это действие нельзя отменить.' : 'The chat will be deleted only for you. This action cannot be undone.';
  String get deleteGroup => isRu ? 'Удалить группу' : 'Delete group';
  String get leaveGroup => isRu ? 'Покинуть группу' : 'Leave group';
  String get addMember => isRu ? 'Добавить участника' : 'Add member';
  String get members => isRu ? 'участников' : 'members';
  String get groups => isRu ? 'Группы' : 'Groups';
  String get contacts => isRu ? 'Контакты' : 'Contacts';
  String get noChats => isRu ? 'Нет чатов' : 'No chats';
  String get searchUsers => isRu ? 'Поиск пользователей' : 'Search users';
  String get createGroup => isRu ? 'Создать группу' : 'Create group';
  String get groupName => isRu ? 'Название группы' : 'Group name';
  String get groupCreated => isRu ? 'Группа создана' : 'Group created';
  String get enterGroupName => isRu ? 'Введите название группы' : 'Enter group name';
  String get failedToCreateGroup => isRu ? 'Не удалось создать группу' : 'Failed to create group';
  String get pressAgainToExit => isRu ? 'Нажмите еще раз для выхода' : 'Press again to exit';
  String get userNotFound => isRu ? 'Пользователь не найден' : 'User not found';
  String get addAccount => isRu ? 'Добавить аккаунт' : 'Add account';
  String get currentAccount => isRu ? 'Текущий аккаунт' : 'Current account';
  String get switchTo => isRu ? 'Переключиться' : 'Switch to';
  String get avatar => isRu ? 'Аватар' : 'Avatar';
  String get removePhoto => isRu ? 'Удалить фото' : 'Remove photo';
  String get changePhoto => isRu ? 'Изменить фото' : 'Change photo';
  String get takePicture => isRu ? 'Сделать снимок' : 'Take picture';
  String get chooseFromGallery => isRu ? 'Выбрать из галереи' : 'Choose from gallery';
  String get camera => isRu ? 'Камера' : 'Camera';
  String get gallery => isRu ? 'Галерея' : 'Gallery';
  String get appLanguage => isRu ? 'Язык приложения' : 'App language';
  String get searchMessages => isRu ? 'Поиск сообщений' : 'Search messages';
  String get noChatsYet => isRu ? 'Нет чатов' : 'No chats yet';
  String get noCommunitiesYet => isRu ? 'Нет сообществ' : 'No communities yet';
  String get noMessagesFound => isRu ? 'Сообщения не найдены' : 'No messages found';
  String get usersNotFound => isRu ? 'Пользователи не найдены' : 'Users not found';
  String get photo => isRu ? 'Фото' : 'Photo';
  String get videoLabel => isRu ? 'Видео' : 'Video';
  String get recordVideo => isRu ? 'Записать видео' : 'Record video';
  String get file => isRu ? 'Файл' : 'File';
  String get chat => isRu ? 'Чат' : 'Chat';
  String get group => isRu ? 'Группа' : 'Group';
  String get user => isRu ? 'Пользователь' : 'User';
  String get unknown => isRu ? 'Неизвестно' : 'Unknown';

  // Wallpaper & Theme
  String get wallpaper => isRu ? 'Обои' : 'Wallpaper';
  String get wallpaperTheme => isRu ? 'Обои и тема' : 'Wallpaper & Theme';
  String get changeBackgroundImage => isRu ? 'Изменить фоновое изображение' : 'Change Background Image';
  String get chooseBackgroundImage => isRu ? 'Выбрать фоновое изображение' : 'Choose Background Image';
  String get adaptiveSchemeColors => isRu ? 'Адаптивная цветовая схема' : 'Adaptive Scheme Colors';
  String get paletteStyle => isRu ? 'Стиль палитры' : 'Palette Style';
  String autoStyle(String name) => isRu ? 'Авто: $name' : 'Auto: $name';
  String get customColors => isRu ? 'Пользовательские цвета' : 'Custom Colors';
  String get wallpaperSettings => isRu ? 'Настройки обоев' : 'Wallpaper Settings';
  String get openWallpaperSettings => isRu ? 'Открыть настройки обоев' : 'Open Wallpaper Settings';
  String get pickColor => isRu ? 'Выбор цвета' : 'Pick Color';
  String get apply => isRu ? 'Применить' : 'Apply';
  String get hue => isRu ? 'Оттенок' : 'Hue';
  String get saturation => isRu ? 'Насыщенность' : 'Saturation';
  String get lightness => isRu ? 'Светлота' : 'Lightness';
  String get brightnessLabel => isRu ? 'Яркость' : 'Brightness';
  String get presets => isRu ? 'Пресеты' : 'Presets';
  String get wallpaperAdaptive => isRu ? 'Обои и адаптивная тема' : 'Wallpaper & Adaptive Theme';
  String get setWallpaperExtract => isRu ? 'Установите обои и автоматически извлеките цвета' : 'Set wallpaper and extract colors automatically';
  String get styleAtmosphere => isRu ? 'Атмосфера' : 'Atmosphere';
  String get styleContrast => isRu ? 'Контраст' : 'Contrast';
  String get styleMono => isRu ? 'Моно' : 'Mono';
  String get styleVibrant => isRu ? 'Яркий' : 'Vibrant';
  String get styleAuto => isRu ? 'Авто' : 'Auto';
  String get createCustomTheme => isRu ? 'Создать свою тему' : 'Create Custom Theme';
  String get importTheme => isRu ? 'Импорт темы' : 'Import Theme';
  String get selectColor => isRu ? 'Выберите цвет' : 'Select Color';
  String get hex => isRu ? 'Шестн.' : 'Hex';
  String get enter6Chars => isRu ? 'Введите 6 символов' : 'Enter 6 chars';
  String get invalidHex => isRu ? 'Неверный код' : 'Invalid';
  String get wallpaperPreview => isRu ? 'Превью обоев' : 'Wallpaper preview';
  String get previewMsg1 => isRu ? 'Привет! Видел новый дизайн?' : 'Hey! Have you seen the new design?';
  String get previewMsg2 => isRu ? 'Да! Чистые плоские слои, без глючных эффектов.' : "Yes! Pure flat layers, no messy glass effects.";
  String get previewMsg3 => isRu ? 'Контраст теперь полностью читаемый.' : 'Contrast looks completely readable now.';

  // Upload / errors
  String get starting => isRu ? 'Начинаем...' : 'Starting...';
  String get sending => isRu ? 'Отправляем...' : 'Sending...';
  String uploadProgress(String percent, String size) => isRu ? '$percent% из $size МБ' : '$percent% of $size MB';
  String get errorPickingVideo => isRu ? 'Ошибка выбора видео' : 'Error picking video';
  String get cameraPermissionRequired => isRu ? 'Требуется разрешение камеры' : 'Camera permission is required';
  String get errorRecordingVideo => isRu ? 'Ошибка записи видео' : 'Error recording video';
  String get errorPickingGallery => isRu ? 'Ошибка выбора из галереи' : 'Error picking from gallery';
  String get errorTakingPhoto => isRu ? 'Ошибка съёмки фото' : 'Error taking photo';
  String get storagePermissionRequired => isRu ? 'Требуется разрешение на доступ к галерее' : 'Storage permission is required to access gallery';
  String get errorSelectingFile => isRu ? 'Ошибка выбора файла' : 'Error selecting file';

  String get media => isRu ? 'Медиа' : 'Media';
  String get files => isRu ? 'Файлы' : 'Files';
  String get music => isRu ? 'Музыка' : 'Music';
  String get noMedia => isRu ? 'Нет медиафайлов' : 'No media';
  String get selected => isRu ? 'выбрано' : 'selected';
  String get e2eeLabel => isRu ? '🔒 E2EE' : '🔒 E2EE';
  String get failedToStartRecording => isRu ? 'Не удалось начать запись' : 'Failed to start recording';

  String get rename => isRu ? 'Переименовать' : 'Rename';
  String get renameGroup => isRu ? 'Переименовать группу' : 'Rename group';
  String get transferOwnership => isRu ? 'Передать владение' : 'Transfer ownership';
  String get makeAdmin => isRu ? 'Сделать администратором' : 'Make admin';
  String get removeAdmin => isRu ? 'Убрать администратора' : 'Remove admin';
  String get leave => isRu ? 'Покинуть' : 'Leave';
  String get remove => isRu ? 'Удалить' : 'Remove';
  String get addParticipant => isRu ? 'Добавить участника' : 'Add participant';
  String membersCount(int n) => isRu ? '$n участников' : '$n members';
  String get newCommunity => isRu ? 'Новое сообщество' : 'New Community';
  String get communityName => isRu ? 'Название сообщества...' : 'Community name...';
  String get addMembersHint => isRu ? 'Добавить участников...' : 'Add members...';
  String get createCommunity => isRu ? 'Создать сообщество' : 'Create Community';
  String get deleteMessage => isRu ? 'Удалить сообщение?' : 'Delete message?';
  String get deleteGroupConfirm => isRu ? 'Вы уверены, что хотите удалить эту группу?' : 'Are you sure you want to delete this group?';
  String get leaveGroupConfirm => isRu ? 'Покинуть группу?' : 'Leave group?';
  String get removeParticipant => isRu ? 'Удалить участника?' : 'Remove participant?';
  String get transferOwnershipConfirm => isRu ? 'Передать владение?' : 'Transfer ownership?';
  String get transferOwnershipBody => isRu ? 'Сделать нового владельца?' : 'Make the new owner?';
  String get videoNotSupported => isRu ? 'Видео не поддерживается' : 'Video not supported';
  String get deleteMessageConfirm => isRu ? 'Удалить сообщение?' : 'Delete message?';
  String get microphonePermissionDenied => isRu ? 'Доступ к микрофону запрещён' : 'Microphone permission denied';
  String get startRecordingHint => isRu ? 'Начать запись' : 'Start recording';
  String get stopRecordingHint => isRu ? 'Остановить запись' : 'Stop recording';
  String get voiceMessageFailed => isRu ? 'Не удалось отправить голосовое сообщение' : 'Failed to send voice message';
  String get editedLabel => isRu ? 'ред.' : 'edited';
  String get messageNotFound => isRu ? '[сообщение не найдено]' : '[message not found]';
  String get monthsJan => isRu ? 'янв' : 'Jan';
  String get monthsFeb => isRu ? 'фев' : 'Feb';
  String get monthsMar => isRu ? 'мар' : 'Mar';
  String get monthsApr => isRu ? 'апр' : 'Apr';
  String get monthsMay => isRu ? 'мая' : 'May';
  String get monthsJun => isRu ? 'июн' : 'Jun';
  String get monthsJul => isRu ? 'июл' : 'Jul';
  String get monthsAug => isRu ? 'авг' : 'Aug';
  String get monthsSep => isRu ? 'сен' : 'Sep';
  String get monthsOct => isRu ? 'окт' : 'Oct';
  String get monthsNov => isRu ? 'ноя' : 'Nov';
  String get monthsDec => isRu ? 'дек' : 'Dec';
  String get today => isRu ? 'Сегодня' : 'Today';
  String get yesterday => isRu ? 'Вчера' : 'Yesterday';
  String formatDate(int timestamp) {
    if (timestamp == 0) return unknown;
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final months = [
      monthsJan, monthsFeb, monthsMar, monthsApr, monthsMay, monthsJun,
      monthsJul, monthsAug, monthsSep, monthsOct, monthsNov, monthsDec,
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  String get quickReaction => isRu ? 'Быстрая реакция' : 'Quick reaction';
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => ['en', 'ru'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) => SynchronousFuture(AppLocalizations(locale));

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
