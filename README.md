# SureType para iPhone

Teclado personal estilo SureType (el de las BlackBerry): 2 letras por tecla y un predictor que adivina la palabra. Está pensado para compilarse gratis en GitHub y para instalarse en tu iPhone desde Windows, sin Mac y sin pagar la cuenta de desarrollador.

## Cómo funciona el teclado

Teclado estilo SureType (2 letras por tecla: QW · ER · TY · UI · OP / AS · DF · GH · JK · LÑ / ZX · CV · BN · M). Pulsas cada tecla una vez por letra y el teclado adivina la palabra que estás escribiendo. No propone la palabra siguiente.

- **Rápido:** las teclas responden al tocar, no al soltar, con el clic del sistema, y manejan los toques directamente (puedes pulsar la siguiente tecla antes de soltar la anterior). La palabra en curso se ve subrayada en el campo y se actualiza al instante con cada tecla. Los diccionarios son archivos binarios que se cargan en milisegundos al abrir el teclado, y si escribes antes de que terminen de cargar no se congela nada: ves tus letras y la barra se completa sola.
- **Contexto:** la palabra anterior ayuda a elegir (por ejemplo entre "su" y "si").
- **Candidatas:** la barra muestra la mejor opción resaltada y otras al lado. La tecla de flechas circulares rota entre ellas. Espacio acepta la resaltada.
- **Diccionario:** español e inglés (unas 45.000 palabras cada uno), por frecuencia. El botón ES/EN cambia de idioma.
- **Aprende:** como el SureType real, la última palabra que elegiste para una combinación de teclas pasa a ser la primera opción la próxima vez (corriges una vez y queda corregido). Las palabras que usas suben de prioridad y las nuevas (nombres) se aprenden si las deletreas con pulsación larga, letra por letra.
- **Autocorrección:** si pulsas una tecla vecina por error, o dos teclas intercambiadas, las palabras que sí existen aparecen al final de la lista.
- **Tildes y ñ:** mantén pulsada una tecla y desliza para elegir la letra exacta (a, á, s / u, ú, ü, i, í / l, ñ ...).
- **Doble espacio:** dos toques rápidos al espacio ponen punto y espacio, y la siguiente letra sale en mayúscula.
- **Mayúsculas:** se activan solas al empezar un texto, después de punto, signo de interrogación o exclamación, y tras un salto de línea. Una pulsación para la siguiente letra, doble pulsación para bloquear.
- **Números y símbolos:** tecla `123`, con una segunda página `#+=`. El punto, mantenido, ofrece `, ? ! ¿ ¡ '`.
- **Borrar palabras aprendidas:** mantén pulsado el botón ES/EN durante 1,5 segundos.

No pide "Acceso total", no usa internet y no envía nada a ningún lado. Una versión anterior con predicción de la siguiente palabra está en la etiqueta `suretype-2-letras`, y una con corrector ortográfico del sistema en el commit "Teclas SureType de 2 letras".

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

Edita `tools/build_dictionaries.py` (listas `ES_EXTRA` y `EN_EXTRA` para agregar palabras con una frecuencia), ejecuta `python tools/build_dictionaries.py` y luego `python tools/bigrams_to_bin.py`, y vuelve a subir los cambios. Con eso se regeneran los archivos binarios `Keyboard/Resources/dict_XX.bin` y `bigram_XX.bin`, que son lo que carga el teclado. Si cambias la distribución de teclas hay que cambiarla igual en `KEY_LETTERS` (Python) y en `KeyMap` (`Keyboard/SureTypeEngine.swift`).

## Banco de pruebas del motor

En Actions, el flujo "Banco de pruebas del motor" (ejecución manual) compila el motor de predicción solo y mide cuánto tarda cada pulsación y cuántas veces acierta la primera candidata con 2.000 palabras de prueba por idioma.

## Limitaciones conocidas

- iOS usa su propio teclado en campos de contraseña y en campos numéricos o de teléfono. No se puede cambiar.
- No hay emojis ni dictado dentro del teclado. El micrófono de abajo a la derecha es el del sistema.
- Las palabras mal aprendidas solo se pueden quitar borrándolas todas (pulsación larga en ES/EN).
- La app contenedora no puede ver las palabras aprendidas, porque con una cuenta gratuita no existe memoria compartida entre la app y el teclado.

## Créditos

Las listas de frecuencia vienen de [hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords), basadas en OpenSubtitles, bajo licencia CC BY-SA 4.0. Los archivos `dict_es.bin` y `dict_en.bin` son una versión filtrada de esas listas y heredan esa licencia.
