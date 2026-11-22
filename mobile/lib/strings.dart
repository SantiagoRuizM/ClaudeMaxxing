// The app's own texts, in the phone's language (Spanish or English). What comes from the PC is already in the
// language chosen in ClaudeMaxxing there.
import 'dart:ui';

final bool _es = PlatformDispatcher.instance.locale.languageCode == 'es';

String t(String es, String en) => _es ? es : en;

class S {
  static String get addPc => t('Agregar PC', 'Add PC');
  static String get scanTitle => t('Escanea el QR de Celular', 'Scan the QR in Phone');
  static String get scanHelp => t(
      'En el PC: ClaudeMaxxing › Celular › Mostrar el QR. El celular tiene que estar en la misma wifi que el PC, o los dos en Tailscale.',
      'On the PC: ClaudeMaxxing › Phone › Show the QR. The phone has to be on the same Wi-Fi as the PC, or both on Tailscale.');
  static String get deviceName => t('Nombre de este celular', 'Name of this phone');
  static String get defaultDeviceName => t('Mi celular', 'My phone');
  static String get pairing => t('Emparejando…', 'Pairing…');
  static String get notAQr => t('Ese QR no es de ClaudeMaxxing.', 'That QR is not from ClaudeMaxxing.');
  static String get codeRefused => t('El PC rechazó el código: muestra un QR nuevo.', 'The PC refused the code: show a new QR.');
  static String unreachable(String why) => t('No se pudo llegar al PC: $why', 'Could not reach the PC: $why');
  static String get welcome => t('Tu ClaudeMaxxing en el celular', 'Your ClaudeMaxxing on the phone');
  static String get welcomeHelp => t(
      'Ve el panel y las sesiones abiertas en tu PC, desliza para pasar de una a otra y escríbeles.',
      'See the panel and the sessions open on your PC, swipe between them and write to them.');
  static String get panel => t('Panel', 'Panel');
  static String get forget => t('Olvidar este PC', 'Forget this PC');
  static String get offline => t('Sin conexión con el PC', 'Not connected to the PC');
  static String get retrying => t('Reintentando…', 'Retrying…');
  static String get revoked => t('Este celular ya no está emparejado: escanea el QR otra vez.', 'This phone is no longer paired: scan the QR again.');
  static String get session5h => t('SESIÓN DE 5 H', '5-HOUR SESSION');
  static String get week => t('SEMANA', 'WEEK');
  static String get sessions => t('SESIONES', 'SESSIONS');
  static String get noSessions => t('Ninguna sesión abierta en el PC.', 'No session open on the PC.');
  static String get thinking => t('Trabajando', 'Working');
  static String get speaking => t('Hablando', 'Speaking');
  static String get idle => t('Esperándote', 'Waiting for you');
  static String get writeHint => t('Escribe a la sesión…', 'Write to the session…');
  static String get cannotWrite => t('Esta sesión no recibe mensajes: ábrela de nuevo desde el menú del PC.',
      'This session does not take messages: open it again from the PC\'s menu.');
  static String get sent => t('Enviado', 'Sent');
  static String get emptyChat => t('Todavía no hay mensajes.', 'No messages yet.');
  static String get fromPhoneNote => t('Llega como mensaje de otra sesión: los permisos se aprueban en el PC.',
      'It arrives as a message from another session: permissions are approved on the PC.');

  static String get attach => t('Adjuntar', 'Attach');
  static String get camera => t('Cámara', 'Camera');
  static String get gallery => t('Galería', 'Gallery');
  static String get document => t('Documento', 'Document');
  static String get audio => t('Audio', 'Audio');
  static String get caption => t('Añade un comentario', 'Add a caption');
  static String get cancel => t('Cancelar', 'Cancel');
  static String get delete => t('Borrar', 'Delete');
  static String get play => t('Reproducir', 'Play');
  static String get pause => t('Pausar', 'Pause');
  static String get voiceNotes => t('Audios', 'Voice notes');
  static String get noVoiceNotes => t(
      'Aquí quedan los audios de la voz de tus sesiones. Se guardan en el celular apenas el PC los dice, para escucharlos cuando quieras.',
      'The voice notes of your sessions land here. They are saved on the phone as soon as the PC says them, to play whenever you want.');
  static String get deleteVoiceNote => t('¿Borrar este audio del celular?', 'Delete this voice note from the phone?');
  static String get yes => t('Sí', 'Yes');
  static String get chatStyle => t('Estilo del chat', 'Chat style');
  static String get textSize => t('Tamaño del texto', 'Text size');
  static String get smallerText => t('Letra más pequeña', 'Smaller text');
  static String get largerText => t('Letra más grande', 'Larger text');
  static String get pinchHint => t('También puedes pellizcar el chat para agrandar o reducir la letra.', 'You can also pinch the chat to make the text larger or smaller.');
  static String get colors => t('Colores', 'Colors');
  static String get today => t('Hoy', 'Today');
  static String get yesterday => t('Ayer', 'Yesterday');
  static String toolRuns(int n) => t('$n herramientas', '$n tools');
  static String get previewTheirs => t('Listo: los **tests** pasan. ¿Sigo con la siguiente tarea?', 'Done: the **tests** pass. Shall I go on with the next task?');
  static String get previewMine => t('Sí, dale', 'Yes, go ahead');
  static String get send => t('Enviar', 'Send');
  static String get attachmentTooLarge => t('El archivo supera el límite de 25 MB.', 'The file exceeds the 25 MB limit.');
  static String attachmentError(Object error) => t('No se pudo adjuntar el archivo: $error', 'Could not attach the file: $error');
  static String get uploading => t('Enviando archivo…', 'Uploading file…');
  static String get dictate => t('Dictar mensaje', 'Dictate message');
  static String get stopDictation => t('Detener dictado', 'Stop dictation');
  static String get dictationError => t('El dictado no está disponible o se interrumpió.', 'Dictation is unavailable or was interrupted.');
  static String notificationTitle(String pc) => 'ClaudeMaxxing · $pc';
  static String get notificationChannel => t('Sesiones del PC', 'PC sessions');
  static String notificationState(String state) => switch (state) {
    'thinking' => t('trabajando', 'working'),
    'speaking' => t('hablando', 'speaking'),
    _ => t('esperando', 'waiting'),
  };
  static String get callTitle => t('Llamada', 'Call');
  static String get callSession => t('Llamar a esta sesión', 'Call this session');
  static String get backToCall => t('Volver a la llamada', 'Back to the call');
  static String get callChannel => t('Llamada con una sesión', 'Call with a session');
  static String get callFailed => t('No se pudo llamar: la app necesita permiso de micrófono.', 'Could not call: the app needs the microphone permission.');
  static String get callNoVoice => t('No se pudo llamar: revisa la voz (texto a voz) de Android en tu idioma.', "Could not call: check Android's text-to-speech voice for your language.");
  static String get callStarting => t('Conectando…', 'Connecting…');
  static String get callEnded => t('Llamada terminada', 'Call ended');
  static String get callSpeaking => t('Hablando…', 'Speaking…');
  static String get callListening => t('Te escucho…', 'Listening…');
  static String get callSending => t('Enviando…', 'Sending…');
  static String get callPaused => t('En pausa por otra llamada', 'Paused by another call');
  static String get callWorking => t('Trabajando. Te aviso al terminar.', "Working. I'll tell you when it's done.");
  static String get callReady => t('Toca para hablar', 'Tap to talk');
  static String get callDecide => t('Espera tu respuesta', 'Waiting for your answer');
  static String get callHowToAccept => t('Dos toques para aceptar, tres para responder.', 'Two taps to accept, three to answer.');
  static String get callGestures => t('Audífonos: dos toques aceptan (o hablas, si no hay propuesta), tres para hablar.', 'Headphones: two taps accept (or talk, with no proposal), three to talk.');
  static String get callHeardNothing => t('No te oí. Toca tres veces cuando quieras hablar.', "I didn't hear you. Tap three times when you want to talk.");
  static String get callHearingFailed => t('Falló el dictado y no envié nada. Toca tres veces para repetirlo.', 'Dictation failed and I sent nothing. Tap three times to say it again.');
  static String get callAccepted => t('Aceptada. Te aviso al terminar.', "Accepted. I'll tell you when it's done.");
  static String get callResent => t('Enviado.', 'Sent.');
  static String get callNotSent => t('Sin conexión: no se envió. Dos toques para reintentar.', 'No connection: not sent. Two taps to retry.');
  static String get callOffline => t('Perdí la conexión con el PC. Sigo intentando.', "I lost the PC. I'll keep trying.");
  static String get callBack => t('Volvió la conexión con el PC.', 'The PC is back.');
  static String get callResumed => t('Sigo aquí. Toca tres veces para hablar.', "I'm still here. Tap three times to talk.");
  static String get callSessionClosed => t('La sesión se cerró o cambió. Cuelgo.', 'The session closed or changed. Hanging up.');
  static String get callStillWaiting => t('Sigue sin terminar. Si espera un permiso, ese se aprueba en el PC.', 'Not done yet. If it is waiting for a permission, that is approved on the PC.');
  static String get accept => t('Aceptar', 'Accept');
  static String get talk => t('Hablar', 'Talk');
  static String get doneTalking => t('Ya terminé', "I'm done");
  static String get hangUp => t('Colgar', 'Hang up');
  static String get you => t('Tú', 'You');
  static String get youHeadset => t('Tú · micrófono de los audífonos', 'You · headphones microphone');
  static String callWith(String name) => t('En llamada con $name', 'On a call with $name');
  static String callHello(String name) => t('Con $name. Te escucho.', 'With $name. Go ahead.');
  static String callSent(String text) => t('Te oí: $text. Enviado.', 'I heard: $text. Sent.');
  static String callRefused(String why) => t('No se envió. $why', 'Not sent. $why');
}
