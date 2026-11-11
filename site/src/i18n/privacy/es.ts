export default {
  title: "Política de privacidad · Native Screen",
  desc: "Qué hace Native Screen con tus grabaciones y tus datos: todo se queda en tu ordenador, sin cuenta, sin analíticas y sin subidas.",
  back: "Volver al inicio",
  updated: "Última actualización: {date}",
  h1: "Política de privacidad",
  note: "Esta traducción es solo informativa. Si difiere de la <a href=\"/privacy/\">versión en inglés</a>, prevalece la versión en inglés.",
  lede: "Native Screen graba y edita en tu ordenador. No hay cuenta, ni servidor nuestro, ni analíticas, ni anuncios. La app nunca sube tus grabaciones.",
  scope: "Esta política se aplica a las apps de Native Screen para macOS y Windows (incluida la versión de Microsoft Store) y a este sitio web. La app es gratuita y de código abierto, así que todo lo que sigue puede comprobarse en el <a href=\"{repo}\">código fuente</a>.",

  stayH: "Lo que se queda en tu ordenador",
  stayP: "Todo lo que creas con Native Screen se guarda en tu ordenador y la app nunca lo envía a ninguna parte:",
  stayList: [
    "grabaciones de pantalla, ventana y área, vídeo de la cámara, audio del micrófono y del sistema;",
    "las posiciones del ratón, los clics y las pulsaciones de teclas registrados con cada toma, usados para los zooms automáticos, el cursor suave y la visualización de atajos de teclado, y el nombre de la ventana o app que grabaste;",
    "los dibujos hechos en pantalla durante la grabación, las notas del orador y los perfiles de grabación;",
    "proyectos, ediciones, preajustes, subtítulos y transcripciones;",
    "vídeos, GIF, imágenes y archivos de subtítulos exportados;",
    "tus ajustes.",
  ],
  onDevice: "Los subtítulos, las transcripciones, la detección de datos sensibles (correos, claves, caras), el seguimiento facial y la eliminación del fondo de la cámara se ejecutan en tu ordenador. En macOS usan los frameworks integrados de Apple, y el reconocimiento de voz está configurado para ejecutarse solo en el dispositivo, así que no se envía audio a Apple. En Windows, los subtítulos usan un modelo Whisper y la eliminación del fondo un modelo MODNet. Cada uno se descarga una vez y después se ejecuta en local.",
  keys: "Las pulsaciones de teclas solo se registran mientras hay una grabación en curso. Se guardan dentro de ese proyecto y en ningún otro sitio, y puedes borrarlas borrando el proyecto.",

  permH: "Permisos que pide la app",
  permP: "Cada permiso se usa solo para la función indicada a su lado.",
  permCols: ["Permiso", "Para qué"],
  perms: [
    ["Grabación de pantalla", "Para grabar una pantalla, una ventana o un área que elijas."],
    ["Micrófono", "Para grabar tu voz y tus locuciones, cuando activas el micrófono."],
    ["Cámara", "Para grabar tu cámara, cuando la activas."],
    ["Accesibilidad (macOS)", "Para listar y seleccionar ventanas, y para seguir clics y pulsaciones de teclas durante una grabación."],
    ["Reconocimiento de voz (macOS)", "Para crear subtítulos con el reconocedor de Apple en el dispositivo."],
    ["Entrada de teclado y ratón (Windows)", "Solo durante una grabación: los clics generan zooms automáticos y efectos de clic, y las teclas se muestran como atajos."],
    ["Plena confianza (Windows)", "Native Screen es una app de escritorio. Necesita acceso completo para usar la captura de pantalla, la captura del audio del sistema, la codificación de vídeo por hardware y la GPU de Windows, a las que las apps empaquetadas no pueden acceder de otra forma."],
    ["Internet", "Solo para las descargas y comprobaciones de actualizaciones que se indican abajo."],
  ],

  leaveH: "Lo que sale de tu ordenador",
  leaveP: "La app solo se conecta a internet en estos casos. Ninguno incluye tus grabaciones, tus proyectos ni nada de lo que hayas escrito.",
  leaveCols: ["Cuándo", "Adónde", "Qué se envía"],
  leave: [
    ["La primera vez que usas los subtítulos o la eliminación del fondo de la cámara en Windows", "Hugging Face (huggingface.co)", "Una solicitud para descargar el archivo del modelo. Hugging Face ve tu dirección IP, como en cualquier descarga. La app de macOS no descarga ningún modelo."],
    ["Al buscar y descargar actualizaciones (macOS, y Windows fuera de Microsoft Store)", "GitHub", "Una solicitud de la última versión y, si la hay, el archivo de actualización. GitHub ve tu dirección IP y las cabeceras habituales de la solicitud. No incluye nada sobre ti ni sobre tus grabaciones. Puedes desactivar la comprobación automática en Ajustes."],
    ["Versión de Microsoft Store", "Microsoft", "La Store instala y actualiza la app, que no tiene actualizador propio. Microsoft puede recopilar datos de diagnóstico según su propia <a href=\"https://privacy.microsoft.com/privacystatement\">declaración de privacidad</a>."],
  ],

  agentsH: "Agentes de IA",
  agentsP: "Si activas <strong>Ajustes &gt; Agentes de IA</strong> (desactivado de forma predeterminada), agentes de IA como Claude, Codex o Cursor pueden controlar Native Screen mediante una conexión local que solo pueden abrir los programas que se ejecutan con tu cuenta de usuario en este ordenador. Un agente puede hacer lo mismo que tú en la app: iniciar una grabación (la barra de grabación y su cuenta atrás siempre se muestran), abrir y editar proyectos, leer los datos y fotogramas de los proyectos, exportar vídeos e imágenes a archivos y darle a la app un archivo de vídeo o imagen de tu ordenador para importarlo. La app no envía nada por internet para esto, pero el agente puede enviar lo que lee a su proveedor de IA según las condiciones de ese proveedor. Desactiva el ajuste para cortar todo acceso de los agentes.",

  notH: "Lo que no hacemos",
  notList: [
    "Sin cuenta ni inicio de sesión.",
    "Sin analíticas, seguimiento de uso ni publicidad.",
    "La app no envía informes de errores.",
    "No vendemos ni compartimos datos personales. No tenemos ninguno que compartir.",
  ],

  webH: "Este sitio web",
  webP: "nativescreen.app es un sitio estático alojado en GitHub Pages. No tiene analíticas ni usa cookies. Las fuentes se cargan desde Google Fonts, así que GitHub y Google reciben tu dirección IP y datos de tu navegador al servir la página. Tus elecciones de tema e idioma se guardan en el almacenamiento local de tu navegador y nunca salen de tu dispositivo.",

  kidsH: "Menores",
  kidsP: "Native Screen no recopila información personal de nadie, incluidos los menores de 13 años.",

  choiceH: "Tus opciones",
  choiceP: "Tus datos están en tu ordenador, así que tú los controlas. Borra un proyecto para eliminar sus grabaciones y sus datos de entrada. Desinstalar elimina la app. Los proyectos, las exportaciones y los modelos descargados se quedan en tu ordenador hasta que los borres.",

  changesH: "Cambios",
  changesP: "Si esta política cambia, la nueva versión se publicará en esta página con una nueva fecha. El historial de cada cambio es público en el <a href=\"{repo}/commits/master/site/src/i18n/privacy/en.ts\">repositorio</a>.",

  contactH: "Contacto",
  contactP: "Preguntas sobre privacidad: escribe a <a href=\"mailto:maitrungduc1410@gmail.com\">maitrungduc1410@gmail.com</a> o abre una incidencia en <a href=\"{repo}/issues\">GitHub</a>.",
};
