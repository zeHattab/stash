# tools/

Вспомогательные проверки проекта. Нужны для разработки; для СБОРКИ ничего из
внешнего не требуется — рабочий `Stash.xcodeproj/project.pbxproj` и каталог строк
лежат в репозитории и правятся вручную.

## check_project.py
Проверяет `project.pbxproj`: синтаксис (plutil), отсутствие повторных определений
объектов и то, что **каждый** `.swift` из `App/`, `StashCore/`, `StashCoreTests/`,
`AutoFill/` зарегистрирован как файл-ссылка. Последнее ловит самую опасную ошибку
ручного редактирования — забытый файл не попадает в сборку.

```
python3 tools/check_project.py
```

## check_strings.py
Находит русские пользовательские литералы в `App/**/*.swift` и сообщает, для каких
нет перевода `en` в `App/Resources/Localizable.xcstrings`. Строки с интерполяцией
пропускаются (у них в каталоге формат-ключи `%@/%lld`, их извлекает Xcode).

```
python3 tools/check_strings.py
```

## Правила ручного редактирования pbxproj
Для нового файла добавляем в четырёх местах, с новым ID вида `FF…`:
1. `PBXFileReference` (путь к файлу);
2. `PBXBuildFile` (ссылка на fileRef);
3. дочерний элемент нужной `PBXGroup` (App / StashCore / StashCoreTests);
4. запись в соответствующей `PBXSourcesBuildPhase`.
Затем `python3 tools/check_project.py`.

Оба скрипта запускаются в CI (`.github/workflows/ci.yml`) до сборки.
