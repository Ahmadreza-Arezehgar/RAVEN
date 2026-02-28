// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'RAVEN';

  @override
  String get appSubtitle => 'Malla + Internet';

  @override
  String get signIn => 'Iniciar sesión';

  @override
  String get signUp => 'Registrarse';

  @override
  String get username => 'Nombre de usuario';

  @override
  String get password => 'Contraseña';

  @override
  String get confirmPassword => 'Confirmar contraseña';

  @override
  String get firstName => 'Nombre';

  @override
  String get lastName => 'Apellido';

  @override
  String get birthYear => 'Año de nacimiento';

  @override
  String get welcomeMessage => 'Bienvenido a RAVEN';

  @override
  String get dontHaveAccount => '¿No tienes cuenta?';

  @override
  String get alreadyHaveAccount => '¿Ya tienes cuenta?';

  @override
  String get errorUsername => 'Por favor ingresa nombre de usuario';

  @override
  String get errorPassword => 'Por favor ingresa contraseña';

  @override
  String get errorPasswordMatch => 'Las contraseñas no coinciden';

  @override
  String get errorFirstName => 'Por favor ingresa nombre';

  @override
  String get errorLastName => 'Por favor ingresa apellido';

  @override
  String get errorBirthYear => 'Por favor ingresa año de nacimiento';

  @override
  String get invalidCredentials => 'Usuario o contraseña inválidos';

  @override
  String get usernameTaken => 'Nombre de usuario ya existe';

  @override
  String get signUpSuccess => '¡Cuenta creada exitosamente!';

  @override
  String get signInSuccess => '¡Bienvenido de nuevo!';

  @override
  String get friendsTab => 'Amigos';

  @override
  String get nearbyTab => 'Cerca';

  @override
  String get home => 'Inicio';

  @override
  String get notifications => 'Notificaciones';

  @override
  String get enterRoom => 'Entrar';

  @override
  String get roomLabel => 'Sala';

  @override
  String get typeMessage => 'Escribe un mensaje...';

  @override
  String get send => 'Enviar';

  @override
  String get screenshotDetected => '📸 ¡Captura de pantalla detectada!';

  @override
  String get friendRequestSent => 'Solicitud de amistad enviada';

  @override
  String wantsToBeFriends(Object name) {
    return '¡$name quiere ser tu amigo!';
  }

  @override
  String get accept => 'Aceptar';

  @override
  String get youAreFriends => 'Ahora son amigos.';

  @override
  String get limitReached => 'Límite alcanzado';

  @override
  String get addFriend => 'Añadir amigo';

  @override
  String get limitReachedMessage =>
      'Intercambiaste 3 mensajes. ¿Añadir como amigo?';

  @override
  String get settings => 'Ajustes';

  @override
  String get language => 'Idioma';

  @override
  String get english => 'Inglés';

  @override
  String get spanish => 'Español';

  @override
  String get persian => 'Persa (فارسی)';

  @override
  String get chinese => 'Chino (中文)';

  @override
  String get messageLimitReached =>
      '¡Límite de mensajes alcanzado! Envía solicitud de amistad para continuar.';

  @override
  String get sendFriendRequest => 'Enviar solicitud de amistad';

  @override
  String get whatsHappening => '¿Qué está pasando?';

  @override
  String get post => 'Publicar';

  @override
  String get like => 'Me gusta';

  @override
  String get comment => 'Comentar';

  @override
  String get share => 'Compartir';

  @override
  String get messages => 'Mensajes';

  @override
  String get search => 'Buscar';

  @override
  String get account => 'Cuenta';

  @override
  String get accountSettings => 'Configuración de cuenta';

  @override
  String get changePassword => 'Cambiar contraseña';

  @override
  String get editBio => 'Editar biografía';

  @override
  String get searchPrivacy => 'Privacidad de búsqueda';

  @override
  String get newsInterests => 'Intereses de noticias';

  @override
  String get faq => 'Preguntas frecuentes';

  @override
  String get currentPassword => 'Contraseña actual';

  @override
  String get newPassword => 'Nueva contraseña';

  @override
  String get save => 'Guardar';

  @override
  String get cancel => 'Cancelar';

  @override
  String get delete => 'Eliminar';

  @override
  String get edit => 'Editar';

  @override
  String get loading => 'Cargando...';

  @override
  String get error => 'Error';

  @override
  String get success => 'Éxito';

  @override
  String get retry => 'Reintentar';

  @override
  String get close => 'Cerrar';

  @override
  String get technology => 'Tecnología';

  @override
  String get business => 'Negocios';

  @override
  String get science => 'Ciencia';

  @override
  String get health => 'Salud';

  @override
  String get sports => 'Deportes';

  @override
  String get entertainment => 'Entretenimiento';

  @override
  String get general => 'General';

  @override
  String get german => 'Alemán';

  @override
  String get public => 'Público';

  @override
  String get private => 'Privado';

  @override
  String get bio => 'Biografía';

  @override
  String get noBioYet => 'Sin biografía aún';

  @override
  String get user => 'Usuario';

  @override
  String get fontSize => 'Tamaño de fuente';

  @override
  String get fontSizeSmall => 'Pequeño';

  @override
  String get fontSizeMedium => 'Mediano';

  @override
  String get fontSizeLarge => 'Grande';

  @override
  String get fontSizeExtraLarge => 'Extra grande';

  @override
  String get privacyAndSecurity => 'Privacy and Security';

  @override
  String get manageBlockedUsersAndSecurity =>
      'Manage blocked users and security';

  @override
  String get blockedUsers => 'Blocked Users';

  @override
  String get noBlockedUsers => 'No blocked users';

  @override
  String get blocked => 'blocked';

  @override
  String get unblock => 'Unblock';

  @override
  String get unblockUser => 'Unblock User';

  @override
  String unblockUserConfirmation(Object username) {
    return 'Are you sure you want to unblock $username?';
  }

  @override
  String userUnblocked(Object username) {
    return '$username has been unblocked';
  }

  @override
  String get passcodeAndFaceId => 'Passcode & Face ID';

  @override
  String get setupPasscode => 'Set up app lock';

  @override
  String get enterPasscode => 'Enter Passcode';

  @override
  String get confirmPasscode => 'Confirm Passcode';

  @override
  String get enterCurrentPasscode => 'Enter Current Passcode';

  @override
  String get passcodeMismatch => 'Passcodes do not match';

  @override
  String get passcodeSet => 'Passcode set successfully';

  @override
  String get passcodeEnabled => 'Passcode Enabled';

  @override
  String get changePasscode => 'Change Passcode';

  @override
  String get removePasscode => 'Remove Passcode';

  @override
  String get removePasscodeConfirmation =>
      'Are you sure you want to remove your passcode?';

  @override
  String get passcodeRemoved => 'Passcode removed';

  @override
  String get unlockApp => 'Unlock App';

  @override
  String get incorrectPasscode => 'Incorrect passcode';

  @override
  String get setupPasscodeFirst => 'Please set up a passcode first';

  @override
  String get enableBiometric => 'Enable biometric authentication';

  @override
  String useBiometricToUnlock(Object biometricName) {
    return 'Use $biometricName to unlock the app';
  }

  @override
  String get twoStepVerification => 'Two-Step Verification';

  @override
  String get addExtraSecurity => 'Add an extra layer of security';

  @override
  String get enable2FA => 'Enable Two-Factor Authentication';

  @override
  String get disable2FA => 'Disable Two-Factor Authentication';

  @override
  String get enabled => 'Enabled';

  @override
  String get disabled => 'Disabled';

  @override
  String verificationVia(Object method) {
    return 'Verification via $method';
  }

  @override
  String get twoFactorDescription =>
      'Two-step verification adds an extra layer of security by requiring a code from your email or phone when signing in';

  @override
  String get chooseVerificationMethod => 'Choose Verification Method';

  @override
  String get verificationMethod => 'Verification Method';

  @override
  String get emailVerification => 'Email';

  @override
  String get smsVerification => 'SMS';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String get enterVerificationCode => 'Enter Verification Code';

  @override
  String get sixDigitCode => '6-digit code';

  @override
  String get verify => 'Verify';

  @override
  String get twoFactorEnabled => 'Two-factor authentication enabled';

  @override
  String get twoFactorDisabled => 'Two-factor authentication disabled';

  @override
  String get disable2FAConfirmation =>
      'Are you sure you want to disable two-factor authentication?';

  @override
  String get invalidCode => 'Invalid verification code';

  @override
  String get disable => 'Disable';

  @override
  String get remove => 'Remove';

  @override
  String get autoDeleteMessages => 'Auto-Delete Messages';

  @override
  String get automaticallyDeleteOldMessages =>
      'Automatically delete old messages';

  @override
  String get autoDeletePeriod => 'Delete messages after';

  @override
  String get never => 'Never';

  @override
  String get twentyFourHours => '24 hours';

  @override
  String get sevenDays => '7 days';

  @override
  String get thirtyDays => '30 days';

  @override
  String get autoDeleteEnabled => 'Auto-delete enabled';

  @override
  String get autoDeleteDisabled => 'Auto-delete disabled';

  @override
  String get autoDeleteDescription =>
      'Messages older than the selected period will be automatically deleted from your device';

  @override
  String messagesOlderThan(Object period) {
    return 'Messages older than $period will be deleted';
  }

  @override
  String get autoDeleteWarning =>
      'Warning: Deleted messages cannot be recovered';

  @override
  String get editProfile => 'Edit Profile';

  @override
  String get showUsernameTitle => 'Show Username';

  @override
  String get showUsernameSubtitle => 'Display your username to others';

  @override
  String get sosModeTitle => 'SOS Mode (Mesh Relay)';

  @override
  String get enableRelayTitle => 'Enable Relay';

  @override
  String get enableRelaySubtitle =>
      'Allow your device to forward messages for others';

  @override
  String get maxHops => 'Max Hops';

  @override
  String hopsCount(Object count) {
    return '$count hops';
  }

  @override
  String get sosModeDescription =>
      'SOS mode routes messages through nearby devices when direct connection is unavailable.';

  @override
  String get meshNetwork => 'Mesh Network';

  @override
  String nearbyPeers(Object count) {
    return 'Nearby Peers: $count';
  }

  @override
  String get debugLogs => 'Debug Logs';

  @override
  String get clearAllDataTitle => 'Clear All Data';

  @override
  String get clearAllDataSubtitle => 'Delete all messages, contacts, and posts';

  @override
  String get clearAllDataDialogTitle => 'Clear All Data?';

  @override
  String get clearAllDataDialogContent =>
      'This will delete all your messages, contacts, and posts. This cannot be undone.';

  @override
  String get allDataCleared => 'All data cleared!';

  @override
  String get faqTitle => 'Ayuda y Preguntas Frecuentes';

  @override
  String get faqQuickStartTitle => '🚀 Guía de Inicio Rápido';

  @override
  String get faqQuickStartSubtitle =>
      'Aprende a usar todas las funciones de RAVEN';

  @override
  String get faqSendMessageTitle => '📱 Enviar Mensaje';

  @override
  String get faqSendMessageQuestion => '¿Cómo envío un mensaje?';

  @override
  String get faqSendMessageSteps =>
      '1. Toca la pestaña \"Mensajes\"\n2. Toca el ícono ➕ o ✏️\n3. Busca o selecciona un contacto\n4. Escribe tu mensaje y toca enviar ✓\n\n¡Importante: Si no tienes internet, los mensajes van por Bluetooth a teléfonos cercanos!';

  @override
  String get faqAddFriendTitle => '👥 Añadir Amigo';

  @override
  String get faqAddFriendQuestion => '¿Cómo añado amigos?';

  @override
  String get faqAddFriendSteps =>
      'Método 1 - Búsqueda:\n1. Ve a la pestaña \"Buscar\"\n2. Escribe el nombre de usuario de tu amigo\n3. Toca su nombre y \"Enviar Solicitud de Amistad\"\n\nMétodo 2 - Código QR:\n1. Ve a Ajustes → \"Mi Código QR\"\n2. Pide a tu amigo que escanee tu QR o escanea el suyo\n¡Esta es la forma más rápida y segura!';

  @override
  String get faqCreatePostTitle => '📝 Crear Publicación';

  @override
  String get faqCreatePostQuestion => '¿Cómo publico?';

  @override
  String get faqCreatePostSteps =>
      '1. Toca la pestaña \"Inicio\"\n2. Toca el botón ➕ en la parte inferior\n3. Escribe tu texto (máximo 280 caracteres)\n4. También puedes añadir una foto 📷\n5. Toca \"Publicar\"\n\nNota: ¡Las publicaciones son públicas! Usa Mensajes para conversaciones privadas.';

  @override
  String get faqAiTitle => '🤖 Asistente IA';

  @override
  String get faqAiQuestion => '¿Cómo pregunto a la IA?';

  @override
  String get faqAiSteps =>
      'En los comentarios de cualquier publicación:\n1. Abre los comentarios de una publicación\n2. Escribe: @time_ask tu pregunta\n3. Ejemplo: \"@time_ask ¿qué tiempo hace hoy?\"\n4. ¡La IA responderá como comentario!\n\nEsta función es para preguntas generales, traducciones y obtener ayuda.';

  @override
  String get faqVoiceTitle => '🔊 Mensaje de Voz';

  @override
  String get faqVoiceQuestion => '¿Cómo envío mensajes de voz?';

  @override
  String get faqVoiceSteps =>
      '1. Ve a un chat\n2. Mantén presionado el botón 🎤 (micrófono)\n3. Habla mientras mantienes presionado\n4. ¡Suelta para enviar!\n\nConsejo: Desliza hacia la izquierda para cancelar.';

  @override
  String get faqBackupTitle => '💾 Copia de Seguridad';

  @override
  String get faqBackupQuestion => '¿Cómo hago copia de seguridad de mis chats?';

  @override
  String get faqBackupSteps =>
      '1. Ve a \"Ajustes\"\n2. Toca \"Copia de Seguridad y Restauración\"\n3. Toca \"Crear Copia de Seguridad\"\n4. Espera a que se complete la subida ✓\n\nLas copias de seguridad se almacenan en iCloud y están encriptadas.';

  @override
  String get faqSectionTitle => '❓ Preguntas Frecuentes';

  @override
  String get faqSectionSubtitle => 'Respuestas a preguntas comunes';

  @override
  String get faqWhatIsRaivenTitle => '¿Qué es RAVEN? 🐦';

  @override
  String get faqWhatIsRaivenAnswer =>
      '¡RAVEN es una aplicación de mensajería única y especial!\n\n¿Por qué es especial? ¡Porque funciona incluso sin internet!\n\nCon internet → Los mensajes van por el servidor (rápido)\nSin internet → Los mensajes van por Bluetooth (inteligente)\n\n¡Esto significa que en el metro, montañas o cualquier lugar sin señal, puedes seguir enviando mensajes! ✨';

  @override
  String get faqOfflineTitle => '¿Cómo funciona la mensajería sin conexión? 📡';

  @override
  String get faqOfflineAnswer =>
      'Es simple:\n\n1. Envías un mensaje\n2. Sin internet, se almacena en tu teléfono\n3. Tu teléfono usa Bluetooth\n4. El mensaje va a teléfonos cercanos con RAVEN\n5. Ellos lo reenvían a otros\n6. ¡Hasta que llega al destino!\n\n¡Como una cadena! Cada teléfono es un eslabón 🔗';

  @override
  String get faqSecurityTitle => '¿Mis mensajes son seguros? 🔒';

  @override
  String get faqSecurityAnswer =>
      '¡100% seguro!\n\n✅ Encriptación de extremo a extremo\nSolo tú y el destinatario pueden leer\n\n✅ Las claves se almacenan en tu dispositivo\nNadie, ni siquiera nosotros, tiene acceso\n\n✅ Los mensajes por Bluetooth también están encriptados\nIncluso los dispositivos de retransmisión no pueden leerlos\n\n¡Descansa tranquilo! 🛡️';

  @override
  String get faqStatusTitle => '¿Qué significan los símbolos de mensaje? ✓';

  @override
  String get faqStatusAnswer =>
      '⏳ Pendiente - Mensaje en cola de envío\n✓ Enviado - Mensaje salió de tu teléfono\n✓✓ Entregado - Mensaje llegó al teléfono del destinatario\n👁 Leído - El destinatario abrió el mensaje\n\nNota: Si tarda mucho, el destinatario puede estar sin conexión.';

  @override
  String get faqBridgeTitle => '¿Qué es el Modo Puente? 🌉';

  @override
  String get faqBridgeAnswer =>
      '¡Una función increíble!\n\nImagina que no tienes internet pero envías un mensaje.\nEl mensaje va por Bluetooth a teléfonos cercanos.\n¡Uno de esos teléfonos TIENE internet!\nEse teléfono envía tu mensaje por el servidor.\n\n¡Así que cruza un puente! 🎯\nEsto sucede automáticamente.';

  @override
  String get faqInternetTitle => '¿Necesito internet? 📶';

  @override
  String get faqInternetAnswer =>
      '¡No! ¡Esta es la mayor ventaja de RAVEN!\n\nCon internet → Todo es más rápido\nSin internet → Se usa Bluetooth\n\nLa app detecta y cambia automáticamente.\n¡Solo escribe tu mensaje, nosotros nos encargamos del resto! 💪';

  @override
  String get faqDuplicateTitle => '¿Recibiré mensajes duplicados? 🔄';

  @override
  String get faqDuplicateAnswer =>
      '¡No!\n\nCada mensaje tiene un ID único (como una huella digital).\nIncluso si un mensaje llega por múltiples rutas (Bluetooth Y servidor), la app lo sabe y lo muestra solo una vez.\n\n¡No te preocupes por duplicados! ✓';

  @override
  String get faqDtnTitle => '¿Qué es DTN? 🔬';

  @override
  String get faqDtnAnswer =>
      'DTN = Delay-Tolerant Networking\nSignifica \"red que tolera retrasos\"\n\nSimplemente:\nUna tecnología que almacena el mensaje, lo transporta y lo envía cuando las condiciones son adecuadas.\n\n¡Aunque tarde un día! (Pero generalmente es mucho más rápido 😄)\n\n¡Esta tecnología fue originalmente construida para la comunicación de naves espaciales! 🚀';

  @override
  String get faqLanguagesTitle => '¿Qué idiomas se admiten? 🌍';

  @override
  String get faqLanguagesAnswer =>
      'RAVEN está completamente traducido a:\n\n🇺🇸 Inglés\n🇮🇷 Persa (con soporte RTL)\n🇪🇸 Español\n🇩🇪 Alemán\n🇨🇳 Chino\n\n¡Ve a Ajustes → Idioma para cambiar!';

  @override
  String get faqTipsTitle => '💡 Consejos y Trucos';

  @override
  String get faqTipsSubtitle => '¡Úsalo mejor!';

  @override
  String get faqTipBluetooth => 'Mantén el Bluetooth encendido';

  @override
  String get faqTipBluetoothDesc =>
      '¡Incluso con internet! Ayudas a otros a recibir sus mensajes.';

  @override
  String get faqTipBackup => 'Haz copias de seguridad regularmente';

  @override
  String get faqTipBackupDesc =>
      'Haz respaldo semanal para no perder tus chats.';

  @override
  String get faqTipQr => 'Usa códigos QR';

  @override
  String get faqTipQrDesc =>
      'Para añadir amigos, ¡el escaneo QR es más rápido y seguro!';

  @override
  String get faqTipNotifications => 'Activa las notificaciones';

  @override
  String get faqTipNotificationsDesc =>
      'Así no te pierdes mensajes importantes.';

  @override
  String get faqContactTitle => '¿Necesitas más ayuda?';

  @override
  String get faqContactEmail => 'info@raven-messager.com';

  @override
  String get faqWhitepaperTitle => 'Where is the technical whitepaper? 📄';

  @override
  String get faqWhitepaperAnswer =>
      'We have a full technical whitepaper on our website!\\n\\n📍 Visit: raven-messager.com/technology.html\\n\\nIt covers:\\n• Hybrid Architecture (Internet + Mesh)\\n• Offline Delivery (DTN Protocol)\\n• Anti-Duplicate Algorithm\\n• Privacy Model\\n• Security Overview\\n\\nVersion: v0.1 — January 2026';

  @override
  String get technicalOverviewTitle => 'How RAVEN Works';

  @override
  String get technicalOverviewSubtitle =>
      'Technical overview of architecture and security';
}
