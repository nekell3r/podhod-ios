# Локальный выпуск iOS

При выпуске обновления по умолчанию обязательна публикация IPA в существующем источнике Feather. Только локальная сборка выполняется, когда пользователь явно просит об этом. Настроенная публикация входит в задачу выпуска и не требует отдельного повторного подтверждения. Выпуск завершён после проверки публичного IPA, его SHA-256 и новой версии в `source.json`; в результате нужны публичные ссылки на IPA и источник Feather.

## Автоматический выпуск из main

Push в `nekell3r/podhod-ios/main` запускает `.github/workflows/release-main.yml` на GitHub-hosted macOS/Xcode. Workflow запускает Python и Swift-тесты, собирает unsigned IPA для iPhone и атомарно обновляет существующий источник Feather. Повторный запуск уже опубликованного commit проверяет receipt без пересборки; старый workflow не может заменить более новый выпуск. Подпись и установка остаются в Feather.

Marketing version берётся из `Podhod.xcodeproj/project.pbxproj`: `major.minor.(base_patch + github.run_number)`, build — `1000 + github.run_number`. При базе `1.7.0` первый запуск публикует `1.7.1 (1001)`. CI не коммитит номера обратно. Для следующего major/minor меняй базу в обеих конфигурациях проекта; не понижай номер относительно источника. Не пересоздавай workflow с новой последовательностью run numbers без проверки выпущенных версий. Ручной выпуск также должен иметь более высокие version и build.

Переменные репозитория: `PODHOD_RELEASE_HOST` (SSH-host без username), `PODHOD_RELEASE_BASE_URL` (HTTPS-каталог существующего источника) и `PODHOD_API_HOST` (hostname API). Secrets: `PODHOD_RELEASE_SSH_KEY` и `PODHOD_RELEASE_KNOWN_HOSTS`. Для iOS нужен отдельный ограниченный ключ, не ключ backend и не административный ключ. Данные аккаунта и сертификаты подписи в CI не передаются.

На сервере `scripts/publish_ci.py` устанавливается как `/usr/local/libexec/podhod-ipa/publish_ci.py`, рядом — проверенный `scripts/package_release.py`. Конфигурация `/etc/podhod-ipa-publish.json` принадлежит root, mode 600: `published_directory`, `state_directory`, `base_url`. Ключ в `authorized_keys` имеет `restrict,command="/usr/bin/python3 /usr/local/libexec/podhod-ipa/publish_ci.py receive"`. Из CI допустимы только `status` или архив через stdin; shell, SCP, forwarding и PTY запрещены. Серверные скрипты и конфигурация обновляются отдельно административным каналом, не из загружаемого архива.

Приёмник ограничивает размер архива, проверяет набор файлов, SHA-256, Bundle ID, архитектуру, назначение и версию, затем вызывает общую atomic promotion. Private pending journal позволяет восстановить receipt после обрыва SSH; прежние версии сохраняются. Workflow проверяет итоговый receipt. После первого запуска проверь также публичные source.json, размер IPA и SHA-256. Успешный CI не подтверждает установку, интерфейс и уведомления на физическом iPhone.

## Ручная сборка без публикации

```sh
python3 scripts/release_local.py 1.5 6
```

Нужны Xcode и Python 3. Скрипт запускает Swift и Python-тесты, собирает Release для `generic/platform=iOS` без подписи и упаковывает IPA, Files ZIP, иконку, manifest и SHA-256. Simulator не используется. Артефакты находятся в `.build/releases/<version>-<build>/`; исходники, изменившиеся во время проверок, останавливают выпуск.

Версия и build передаются Xcode явно. Bundle ID закреплён как `dev.podhod.training`. Изменённый IPA требует новой marketing version и увеличенного build. Идентичный файл можно передать повторно; прежние файлы и версии feed сохраняются.

## Настройки и отправка

Скопируй `.env.local.example` в `.env.local`, заполни собственные адреса и SSH-алиас. Файл исключён из Git. Он не загружается автоматически:

```sh
set -a
. ./.env.local
set +a
python3 scripts/release_local.py 1.5 6 --publish
```

Публикация требует `PODHOD_RELEASE_BASE_URL`, `PODHOD_RELEASE_SSH_HOST` и `PODHOD_RELEASE_DIRECTORY`. Передача идёт через уже настроенный SSH, без создания ключей. На сервере Python проверяет hashes, сохраняет артефакты неизменно и атомарно обновляет source.json. При ошибке staging прежний feed остаётся доступным. Это не обновляет backend, БД или Keycloak.

Для уже собранного IPA достаточно упаковки:

```sh
python3 scripts/package_release.py /path/to/unsigned.ipa https://api.example.com/releases /path/to/release
```

Для отдельной promotion скопируй файлы из `files` manifest, сам `*.release.json` и `package_release.py` в уникальный staging на своём сервере, затем запусти `package_release.py publish STAGING PUBLIC_DIRECTORY`. Сборку повторять не требуется.

Если IPA уже проверен, используй именно этот файл: повторная сборка может изменить hash при прежней версии. Для упаковки с другим `base_url` выбери отдельный локальный output directory, чтобы не менять неизменяемый manifest прежней упаковки. После promotion проверь публичные `source.json` и IPA: последнюю версию, Bundle ID, размер и SHA-256 по проверенному manifest. Сохраняй предыдущие версии источника.

## Установка и сохранение данных

Добавь URL собственного source.json в Feather. Подпиши сборку подходящим сертификатом и установи поверх приложения. Для сохранения контейнера и Keychain нужны прежний Bundle ID, совместимая подпись и App Identifier Prefix. Не удаляй приложение перед обновлением. Локальные данные не копируются в IPA и не очищаются релизными скриптами.

При изменении формата хранилища нужны резервная копия и тесты миграции. Старую сборку нельзя слепо ставить поверх более нового формата данных. Реальные пароли, токены, сертификаты и provisioning profiles не хранятся в Git.
