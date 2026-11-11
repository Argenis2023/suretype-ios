# SureType para iPhone

Teclado personal estilo SureType (el de las BlackBerry): 2 letras por tecla y un predictor que adivina la palabra. Está pensado para compilarse gratis en GitHub y para instalarse en tu iPhone desde Windows, sin Mac y sin pagar la cuenta de desarrollador.

## Cómo funciona el teclado

- **Teclas:** QW · ER · TY · UI · OP / AS · DF · GH · JK · LÑ / ZX · CV · BN · M. Pulsas cada tecla una vez por letra y el teclado escribe la palabra más probable.
- **Rotar:** la tecla con las flechas circulares cambia a la siguiente candidata. Espacio acepta la palabra. La barra de arriba muestra las candidatas y también se pueden tocar.
- **Diccionario:** español e inglés (unas 45.000 palabras cada uno), ordenadas por frecuencia. El botón ES/EN de la barra cambia de idioma.
- **Aprende:** las palabras que eliges suben de prioridad. Las palabras nuevas se aprenden cuando las deletreas con pulsación larga. Todo queda guardado solo en el teléfono.
- **Autocorrección:** si pulsas una tecla vecina por error, o dos teclas intercambiadas, o una tecla de más, las palabras que sí existen aparecen al final de la lista y las alcanzas con la tecla de rotar.
- **Tildes y ñ:** mantén pulsada una tecla y desliza el dedo para elegir la letra exacta (a, á, s / u, ú, ü, i, í / l, ñ ...). Esa letra queda fija dentro de la palabra.
- **Números y símbolos:** tecla `123`, con una segunda página `#+=`. El punto, mantenido, ofrece `, ? ! ¿ ¡ '`.
- **Mayúsculas:** una pulsación para la siguiente letra, doble pulsación para bloquear. Se activan solas al empezar una frase.
- **Borrar palabras aprendidas:** mantén pulsado el botón ES/EN durante 1,5 segundos.

No pide "Acceso total", no usa internet y no envía nada a ningún lado.

## Paso 1: subir el proyecto a GitHub

1. Crea una cuenta en github.com si no tienes y crea un repositorio nuevo llamado `suretype-ios`. Hazlo **público**: así los minutos de compilación en Mac son gratis e ilimitados. El repositorio no contiene datos personales.
2. Sube esta carpeta completa. Con Git para Windows, en PowerShell dentro de la carpeta:

```powershell
git init
git add .
git commit -m "SureType inicial"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/suretype-ios.git
git push -u origin main
```

Si prefieres la web, arrastra el contenido de la carpeta a la página del repositorio ("Add file" > "Upload files"). Si la carpeta oculta `.github` no se sube, créala a mano: "Add file" > "Create new file", escribe `.github/workflows/build.yml` como nombre y pega el contenido de ese archivo.

## Paso 2: conseguir la .ipa

1. En el repositorio abre la pestaña **Actions**. Al subir el código arranca solo el flujo "Compilar IPA" (si no, entra en él y pulsa "Run workflow").
2. Espera unos 5 a 10 minutos hasta que aparezca el check verde.
3. Abre esa ejecución, baja hasta **Artifacts** y descarga `SureType-ipa`. Es un zip que contiene `SureType.ipa`.

Si la ejecución sale en rojo: abre el paso que falló, copia las últimas 60 líneas del registro y pásamelas para corregirlo. Este código no se pudo compilar antes de entregarlo (no hay Mac a mano), así que es posible que la primera compilación pida un ajuste.

## Paso 3: instalar en el iPhone desde Windows

1. Instala **iTunes** y **iCloud** descargándolos de apple.com (las versiones de la Microsoft Store no sirven para esto).
2. Instala **Sideloadly** (sideloadly.io).
3. Conecta el iPhone por cable, desbloquéalo y toca "Confiar" en la pantalla del teléfono.
4. Abre Sideloadly, arrastra `SureType.ipa`, escribe tu Apple ID y pulsa **Start**. La primera vez pedirá la contraseña (con la cuenta gratis basta).
5. En el iPhone: Ajustes > General > VPN y administración de dispositivos > toca tu Apple ID > **Confiar**.
6. En iOS 16 o superior: Ajustes > Privacidad y seguridad > **Modo de desarrollador** > activar, y reinicia el teléfono.
7. Activa el teclado: Ajustes > General > Teclado > Teclados > Añadir teclado nuevo > **SureType**. Después, en cualquier campo de texto, mantén pulsado el globo (o el icono de emoji) y elige SureType.

La app "SureType" que aparece en la pantalla de inicio solo trae las instrucciones y una zona de prueba. El teclado en sí vive dentro de ella.

## Cada 7 días

Con una cuenta Apple gratuita la firma dura 7 días. Cuando el teclado deje de abrir, vuelve a instalar la misma `.ipa` con Sideloadly (los pasos 3 y 4). Si te molesta, SideStore o AltStore pueden renovar la firma automáticamente. Con la cuenta gratuita, la app y el teclado ocupan 2 de los 10 identificadores de app que Apple permite por semana.

## Cambiar o ampliar el diccionario

Edita `tools/build_dictionaries.py` (listas `ES_EXTRA` y `EN_EXTRA` para agregar palabras con una frecuencia), ejecuta `python tools/build_dictionaries.py --preview` y vuelve a subir los cambios. Con eso se regeneran `Keyboard/Resources/dict_es.txt` y `dict_en.txt`. Si cambias la distribución de teclas hay que cambiarla igual en `KEY_LETTERS` (Python) y en `KeyMap` (`Keyboard/SureTypeEngine.swift`).

## Limitaciones conocidas

- iOS usa su propio teclado en campos de contraseña y en campos numéricos o de teléfono. No se puede cambiar.
- No hay emojis ni dictado dentro del teclado. El micrófono de abajo a la derecha es el del sistema.
- Las palabras mal aprendidas solo se pueden quitar borrándolas todas (pulsación larga en ES/EN).
- La app contenedora no puede ver las palabras aprendidas, porque con una cuenta gratuita no existe memoria compartida entre la app y el teclado.

## Créditos

Las listas de frecuencia vienen de [hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords), basadas en OpenSubtitles, bajo licencia CC BY-SA 4.0. Los archivos `dict_es.txt` y `dict_en.txt` son una versión filtrada de esas listas y heredan esa licencia.
