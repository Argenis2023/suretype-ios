# SureType para iPhone

Teclado personal estilo SureType (el de las BlackBerry): 2 letras por tecla y un predictor que adivina la palabra. Está pensado para compilarse gratis en GitHub y para instalarse en tu iPhone desde Windows, sin Mac y sin pagar la cuenta de desarrollador.

## Cómo funciona el teclado

Teclado QWERTY normal con corrector ortográfico. No predice palabras: tú escribes y el teclado solo avisa si algo está mal.

- **Corrector:** usa el corrector del propio iOS (UITextChecker), español e inglés. Si una palabra está mal escrita, aparece en rojo en la barra de arriba con hasta tres correcciones. Al tocar una, reemplaza la palabra. Si la palabra en rojo es correcta (un nombre), tócala para guardarla.
- **Doble espacio:** dos toques rápidos al espacio ponen punto y espacio.
- **Mayúsculas:** se activan solas al empezar un texto, después de punto, signo de interrogación o exclamación, y tras un salto de línea. Una pulsación para la siguiente letra, doble pulsación para bloquear.
- **Tildes y ñ:** mantén pulsada una vocal, la n o la c y desliza para elegir (á, é, í, ó, ú, ü, ñ, ç). La ñ también tiene su propia tecla.
- **Números y símbolos:** tecla `123`, con una segunda página `#+=`. El punto, mantenido, ofrece `? ! ¿ ¡ '`.
- **Idioma:** el botón ES/EN cambia el idioma del corrector. Mantenerlo 1,5 segundos borra las palabras guardadas.

No pide "Acceso total", no usa internet y no envía nada a ningún lado. La versión anterior de 2 letras por tecla (estilo SureType) quedó guardada en la etiqueta `suretype-2-letras` del repositorio.

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

## Limitaciones conocidas

- iOS usa su propio teclado en campos de contraseña y en campos numéricos o de teléfono. No se puede cambiar.
- No hay emojis ni dictado dentro del teclado. El micrófono de abajo a la derecha es el del sistema.
- Las palabras guardadas como correctas solo se pueden quitar borrándolas todas (pulsación larga en ES/EN).
- El corrector depende de los diccionarios de iOS. La app muestra cuáles hay disponibles en tu teléfono.
- La app contenedora no puede ver las palabras aprendidas, porque con una cuenta gratuita no existe memoria compartida entre la app y el teclado.
