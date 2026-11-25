# Zapret для Apex Legends

Обход DPI-блокировок в Apex Legends на Windows. Есть профиль Rust и общий профиль для Discord и YouTube.

[![Скачать Zapret для Windows (ZIP)](https://img.shields.io/badge/%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C%20%D0%B4%D0%BB%D1%8F%20Windows-ZIP-1767C0?style=for-the-badge)](https://github.com/zozick7/zapret-apex/releases/latest/download/zapret-apex.zip)

## Как запустить

1. Скачай и распакуй ZIP в отдельную папку.
2. Запусти `service.bat` и подтверди запрос Windows.
3. Нажми **1** и выбери **Apex Legends**. Если Zapret выключен, нажми **2**. После этого он будет запускаться вместе с Windows.

Для Rust выбери **Rust**. Если нужны только Discord и YouTube, выбери **Discord и YouTube**.

## Меню

| Пункт | Что делает |
| --- | --- |
| **1. Выбрать профиль** | Переключает игровые профили и профиль Discord и YouTube. Если Zapret включён, новый профиль применяется сразу. |
| **2. Включить / Выключить** | Запускает или останавливает Zapret. Вместе с ним включается или выключается автозапуск с Windows. |
| **3. Проверить сеть** | Проверяет Discord и YouTube. Если картинки Discord не грузятся, пробует подобрать рабочие адреса. Для Apex ищет свежий список ретрансляторов в файлах игры. Для Rust проверяет серверы карт. |
| **4. Обновить** | Проверяет обновления на GitHub и ставит новую версию, если она есть. После обновления работающий профиль запускается снова. |
| **5. Не пускает в матч** | Открой лобби Apex с включённым профилем Apex Legends. Выбери этот пункт и запусти поиск матча. Примерно через 40 секунд рядом с `service.bat` появится `Apex Network Report.txt`. |
| **5. Проверить карту Rust** | В профиле Rust. Вставь прямую ссылку на файл карты из консоли F1. Zapret проверит, начинается ли загрузка. |
| **6. Автоподбор IP Apex** | Включает или выключает автоподбор. При входе в матч пробует временно добавить адрес сервера, если тот не отвечает. Когда автоподбор включён, он сам запускается при входе в Windows. |
| **0. Выход** | Закрывает меню. Zapret продолжает работать, если он включён. |

## Проверка файлов

В архиве оригинальный `winws.exe` из Zapret v72.9 для Windows x64. Меню и скрипты лежат в этом репозитории.

Открой папку со скачанным ZIP в Проводнике. В адресной строке набери `powershell` и нажми Enter.

~~~powershell
Get-FileHash .\zapret-apex.zip -Algorithm SHA256
~~~

Сверь `Hash` с суммой из `SHA256SUMS.txt` в том же [релизе](https://github.com/zozick7/zapret-apex/releases). Там же есть журнал сборки.

<details>
<summary>Проверить winws.exe</summary>

Тем же способом открой PowerShell в распакованной папке `Zapret-Apex`.

~~~powershell
Get-FileHash .\bin\winws.exe -Algorithm SHA256
~~~

Сверь `Hash` со значением в строке `windows-x86_64/winws.exe` в [контрольных суммах bol-van](https://github.com/bol-van/zapret/releases/download/v72.9/sha256sum.txt).

</details>

Zozick · [Flowseal](https://github.com/Flowseal/zapret-discord-youtube) · [zapret](https://github.com/bol-van/zapret) · [WinDivert](https://github.com/basil00/WinDivert) · [Cygwin](https://cygwin.com/git/newlib-cygwin.git) · [Лицензия](LICENSE.txt)
